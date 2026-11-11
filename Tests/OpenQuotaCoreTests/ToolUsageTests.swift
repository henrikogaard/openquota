import XCTest
@testable import OpenQuotaCore

/// Usage read from OpenCode's database, Mistral Vibe session files and
/// Copilot CLI event logs. All data here is synthetic.
final class ToolUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_374_400) // 2026-10-07 12:00 UTC
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var rates: ModelRates {
        ModelRates(inputPerMillion: 2, outputPerMillion: 10, cacheWritePerMillion: 2.5,
                   cacheReadPerMillion: 0.2, inputAbove200kPerMillion: 4, outputAbove200kPerMillion: 20,
                   cacheWriteAbove200kPerMillion: 5, cacheReadAbove200kPerMillion: 0.4,
                   fastMultiplier: 2)
    }
    private var pricing: ModelPricing {
        ModelPricing(supplement: PricingSupplement(),
                     primary: PricingCatalog(entries: ["known": rates, "known-4-6": rates]), secondary: PricingCatalog())
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oq-tools-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func json(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }

    // MARK: Vibe

    private func vibeSession(
        id: String = "s1", prompt: Int = 1_000, cached: Int = 400, completion: Int = 50, cost: Double = 0,
        end: String? = "2026-10-08T01:00:00.123456+00:00"
    ) -> [String: Any] {
        var object: [String: Any] = [
            "session_id": id, "start_time": "2026-10-07T08:00:00.000001+00:00",
            "config": ["active_model": "known"],
            "stats": ["session_prompt_tokens": prompt, "session_cached_tokens": cached,
                      "session_completion_tokens": completion, "session_cost": cost],
        ]
        if let end { object["end_time"] = end }
        return object
    }

    func testVibeSessionSplitsCachedFromPromptTokens() throws {
        let event = try XCTUnwrap(VibeUsage.event(from: json(vibeSession())))
        XCTAssertEqual(event.provider, .vibe)
        XCTAssertEqual(event.model, "known")
        XCTAssertEqual(event.identity, "s1")
        XCTAssertEqual(event.tokens.input, 600)
        XCTAssertEqual(event.tokens.cacheRead, 400)
        XCTAssertEqual(event.tokens.output, 50)
        XCTAssertNil(event.recordedUSD)
        // Stamped on the day it started, though it ended the day after.
        XCTAssertEqual(calendar.component(.day, from: event.timestamp), 7)
    }

    func testVibeSessionUsesRecordedCostAndKeepsItsDayWhileOpen() throws {
        let event = try XCTUnwrap(VibeUsage.event(from: json(vibeSession(cost: 0.25, end: nil))))
        XCTAssertEqual(event.recordedUSD, 0.25)
        XCTAssertEqual(calendar.component(.day, from: event.timestamp), 7)
    }

    func testVibeSessionWithoutUsageOrStatsIsIgnored() throws {
        XCTAssertNil(VibeUsage.event(from: try json(vibeSession(prompt: 0, cached: 0, completion: 0))))
        XCTAssertNil(VibeUsage.event(from: try json(["session_id": "s1", "start_time": "2026-10-06T23:00:00Z"])))
        XCTAssertNil(VibeUsage.event(from: Data("not json".utf8)))
    }

    // MARK: Copilot

    private func shutdown(_ metrics: [String: [String: Int]], at time: String = "2026-10-07T09:00:00.000Z") -> [String: Any] {
        ["type": "session.shutdown", "timestamp": time,
         "data": ["modelMetrics": metrics.mapValues { ["usage": $0] }]]
    }

    func testCopilotShutdownGivesOneEventPerModelAndSkipsRepeatedTotals() throws {
        var parser = SpendLogParser(provider: .copilot, fileIdentity: "file")
        let usage = ["inputTokens": 1_000, "outputTokens": 40, "cacheReadTokens": 700, "cacheWriteTokens": 10]
        let first = parser.parse(try json(shutdown(["known-4.6": usage, "other": ["inputTokens": 5, "outputTokens": 1]])), lineNumber: 1)
        XCTAssertEqual(first.map(\.model), ["known-4.6", "other"])
        XCTAssertEqual(first[0].tokens.input, 300)
        XCTAssertEqual(first[0].tokens.cacheRead, 700)
        XCTAssertEqual(first[0].tokens.cacheWrite5m, 10)
        XCTAssertEqual(first[0].tokens.output, 40)
        XCTAssertEqual(first[0].provider, .copilot)
        // A resumed session that did nothing repeats the same totals.
        XCTAssertTrue(parser.parse(try json(shutdown(["known-4.6": usage])), lineNumber: 2).isEmpty)
        // New work in a later run counts.
        let later = parser.parse(try json(shutdown(["known-4.6": ["inputTokens": 20, "outputTokens": 2]])), lineNumber: 3)
        XCTAssertEqual(later.count, 1)
        XCTAssertNotEqual(later[0].identity, first[0].identity)
    }

    func testCopilotIgnoresOtherEventsAndEmptyShutdowns() throws {
        var parser = SpendLogParser(provider: .copilot, fileIdentity: "file")
        XCTAssertTrue(parser.parse(try json(["type": "session.usage_checkpoint", "timestamp": "2026-10-07T09:00:00Z",
                                             "data": ["totalNanoAiu": 5]]), lineNumber: 1).isEmpty)
        XCTAssertTrue(parser.parse(try json(shutdown([:])), lineNumber: 2).isEmpty)
        XCTAssertTrue(parser.parse(try json(shutdown(["m": ["inputTokens": 0, "outputTokens": 0]])), lineNumber: 3).isEmpty)
        XCTAssertFalse(parser.incomplete)
    }

    // MARK: OpenCode

    /// A database shaped like OpenCode's `message` table.
    private func openCodeDatabase(at url: URL, rows: [(id: String, updated: Int, data: [String: Any])]) throws {
        let database = try SQLiteDatabase(url: url)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS message(
                id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL,
                time_updated INTEGER NOT NULL, data TEXT NOT NULL)
            """)
        let insert = try database.prepare("INSERT OR REPLACE INTO message VALUES (?1, 's', ?2, ?2, ?3)")
        for row in rows {
            try insert.run([row.id, row.updated, String(decoding: try json(row.data), as: UTF8.self)])
        }
    }

    private func assistant(
        created: Int, input: Int = 100, output: Int = 20, reasoning: Int = 5, read: Int = 30, write: Int = 7,
        cost: Double = 0, model: String = "known"
    ) -> [String: Any] {
        ["role": "assistant", "modelID": model, "providerID": "p", "cost": cost,
         "time": ["created": created],
         "tokens": ["input": input, "output": output, "reasoning": reasoning,
                    "cache": ["read": read, "write": write]]]
    }

    private var noonMillis: Int { Int(now.timeIntervalSince1970 * 1_000) }

    func testOpenCodeReadsAssistantMessagesAfterCursor() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("opencode.db")
        try openCodeDatabase(at: url, rows: [
            ("m1", 10, assistant(created: noonMillis, cost: 0.5)),
            ("m2", 20, ["role": "user", "time": ["created": noonMillis]]),
            ("m3", 30, assistant(created: noonMillis, input: 0, output: 0, reasoning: 0, read: 0, write: 0)),
            ("m4", 40, assistant(created: noonMillis)),
        ])
        // One broken row doesn't stop the rest from being read.
        try SQLiteDatabase(url: url).execute("INSERT INTO message VALUES ('bad', 's', 35, 35, 'not json')")
        let all = try OpenCodeUsage.read(databaseURL: url, after: 0, limit: 100)
        XCTAssertEqual(all.events.map(\.identity), ["m1", "m4"])
        XCTAssertEqual(all.cursor, 40)
        XCTAssertEqual(all.cursorID, "m4")
        XCTAssertFalse(all.more)
        let first = all.events[0]
        XCTAssertEqual(first.provider, .opencode)
        XCTAssertEqual(first.model, "known")
        XCTAssertEqual(first.tokens.input, 100)
        XCTAssertEqual(first.tokens.output, 25)
        XCTAssertEqual(first.tokens.cacheRead, 30)
        XCTAssertEqual(first.tokens.cacheWrite5m, 7)
        XCTAssertEqual(first.recordedUSD, 0.5)
        XCTAssertNil(all.events[1].recordedUSD)
        XCTAssertEqual(first.timestamp.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1)

        XCTAssertEqual(try OpenCodeUsage.read(databaseURL: url, after: 10, afterID: "m1", limit: 100).events.map(\.identity), ["m4"])
        XCTAssertTrue(try OpenCodeUsage.read(databaseURL: url, after: 40, afterID: "m4", limit: 100).events.isEmpty)
        // Without the id, messages at the cursor's timestamp are read again rather than skipped.
        XCTAssertEqual(try OpenCodeUsage.read(databaseURL: url, after: 40, limit: 100).events.map(\.identity), ["m4"])
    }

    func testOpenCodePagesThroughMessagesSharingOneTimestamp() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("opencode.db")
        try openCodeDatabase(at: url, rows: [
            ("m1", 10, assistant(created: noonMillis)), ("m2", 20, assistant(created: noonMillis)),
            ("m3", 20, assistant(created: noonMillis)), ("m4", 20, assistant(created: noonMillis)),
            ("m5", 20, ["role": "user", "time": ["created": noonMillis]]),
            ("m6", 20, assistant(created: noonMillis)),
        ])
        var seen: [String] = []
        var cursor = 0
        var cursorID = ""
        var pages = 0
        while true {
            let page = try OpenCodeUsage.read(databaseURL: url, after: cursor, afterID: cursorID, limit: 2)
            seen += page.events.map(\.identity)
            (cursor, cursorID) = (page.cursor, page.cursorID)
            pages += 1
            if !page.more || pages > 10 { break }
        }
        // Every message once, though four of them share a timestamp and a page holds two.
        XCTAssertEqual(seen, ["m1", "m2", "m3", "m4", "m6"])
        XCTAssertEqual(cursor, 20)
        XCTAssertEqual(cursorID, "m6")
        XCTAssertTrue(try OpenCodeUsage.read(databaseURL: url, after: cursor, afterID: cursorID, limit: 2).events.isEmpty)
    }

    func testCopilotStateCarriesCountedTotalsAcrossAResumedRead() throws {
        var parser = SpendLogParser(provider: .copilot, fileIdentity: "file")
        let usage = ["inputTokens": 1_000, "outputTokens": 40]
        XCTAssertEqual(parser.parse(try json(shutdown(["m": usage])), lineNumber: 1).count, 1)
        // The saved state survives being written to and read from the database.
        let saved = try JSONDecoder().decode(SpendLogParser.State.self, from: JSONEncoder().encode(parser.state))
        var resumed = SpendLogParser(provider: .copilot, fileIdentity: "file")
        resumed.state = saved
        XCTAssertTrue(resumed.parse(try json(shutdown(["m": usage])), lineNumber: 2).isEmpty)
        XCTAssertEqual(resumed.parse(try json(shutdown(["m": ["inputTokens": 7, "outputTokens": 1]])), lineNumber: 3).count, 1)
        // States saved before this field existed still load.
        let old = try JSONDecoder().decode(SpendLogParser.State.self, from: Data(#"{"model":"","sessionID":"","sawMeta":false,"fast":false,"ultrafast":false}"#.utf8))
        XCTAssertNil(old.copilotSeen)
    }

    func testOpenCodeMissingDatabaseOrTableThrowsWithoutCreatingAFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("opencode.db")
        XCTAssertThrowsError(try OpenCodeUsage.read(databaseURL: missing, after: 0, limit: 10))
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let empty = root.appendingPathComponent("other.db")
        try SQLiteDatabase(url: empty).execute("CREATE TABLE unrelated(x)")
        XCTAssertThrowsError(try OpenCodeUsage.read(databaseURL: empty, after: 0, limit: 10))
    }

    // MARK: Antigravity

    /// A tiny protobuf writer for test data.
    private enum Proto {
        static func varint(_ value: UInt64) -> Data {
            var value = value
            var data = Data()
            repeat {
                let byte = UInt8(value & 0x7F)
                value >>= 7
                data.append(value == 0 ? byte : byte | 0x80)
            } while value != 0
            return data
        }
        static func number(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
        static func bytes(_ field: Int, _ value: Data) -> Data {
            varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value
        }
        static func text(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    }

    /// The usage record as it sits in both a generation and its step.
    private func antigravityCounts(id: String, input: UInt64 = 1_000, output: UInt64 = 60, cached: UInt64 = 5_000) -> Data {
        Proto.number(1, 1_417) + Proto.number(2, input) + Proto.number(3, output) + Proto.number(5, cached)
            + Proto.text(7, id) + Proto.number(9, 20) + Proto.number(10, output - 20)
    }

    private func antigravityGeneration(_ counts: Data, model: String? = "known") -> Data {
        // Text before, a fixed-width number and a repeat of the counts after: all passed over.
        var generation = Proto.text(2, "a prompt that is never kept") + Proto.bytes(4, counts)
            + Proto.varint(UInt64(11 << 3 | 1)) + Data(repeating: 7, count: 8)
            + Proto.bytes(17, Proto.bytes(2, counts))
        if let model { generation += Proto.text(19, model) }
        return Proto.bytes(1, generation) + Proto.text(4, "conversation")
    }

    private func antigravityStep(_ counts: Data?, seconds: UInt64) -> Data {
        var step = Proto.bytes(1, Proto.number(1, seconds) + Proto.number(2, 500_000_000))
        if let counts { step += Proto.bytes(9, counts) }
        return step
    }

    @discardableResult
    private func antigravityDatabase(at url: URL, generations: [Data], steps: [Data]) throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(url: url)
        try database.execute("""
            CREATE TABLE IF NOT EXISTS gen_metadata(idx INTEGER PRIMARY KEY, data BLOB, size INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS steps(
                idx INTEGER PRIMARY KEY, step_type INTEGER NOT NULL DEFAULT 0, metadata BLOB, step_payload BLOB);
            DELETE FROM gen_metadata; DELETE FROM steps;
            """)
        func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
        for (index, data) in generations.enumerated() {
            try database.execute("INSERT INTO gen_metadata VALUES (\(index), x'\(hex(data))', \(data.count))")
        }
        for (index, data) in steps.enumerated() {
            try database.execute("INSERT INTO steps VALUES (\(index), 15, x'\(hex(data))', x'\(hex(Data("secret".utf8)))')")
        }
        return database
    }

    func testAntigravityReadsAClosedConversationWithoutSideFilesAndALiveOneThroughItsLog() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("c.db")
        let counts = antigravityCounts(id: "r1")
        let noon = UInt64(noonMillis / 1_000)
        // Closed the way the tool closes it: the write-ahead log is folded in and gone.
        try antigravityDatabase(at: url, generations: [antigravityGeneration(counts)],
                                steps: [antigravityStep(counts, seconds: noon)])
            .execute("PRAGMA journal_mode=DELETE")
        // Apple's SQLite can leave the shared-memory file behind; the tool's doesn't.
        try? FileManager.default.removeItem(atPath: url.path + "-shm")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["c.db"])
        XCTAssertEqual(try AntigravityUsage.read(databaseURL: url, limit: 10).events.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["c.db"])

        // Still open in the tool: the newest rows are in the write-ahead log.
        let more = antigravityCounts(id: "r2")
        let writer = try antigravityDatabase(
            at: url, generations: [antigravityGeneration(counts), antigravityGeneration(more)],
            steps: [antigravityStep(counts, seconds: noon), antigravityStep(more, seconds: noon + 1)])
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path + "-wal"))
        XCTAssertEqual(try AntigravityUsage.read(databaseURL: url, limit: 10).events.count, 2)
        _ = writer
    }

    func testProtobufReaderFindsFieldsAndSurvivesGarbage() {
        let message = ProtobufMessage(
            Proto.number(1, 300) + Proto.varint(UInt64(2 << 3 | 5)) + Data(repeating: 1, count: 4)
                + Proto.bytes(3, Proto.number(7, 9)) + Proto.number(1, 4))
        XCTAssertEqual(message.varint(1), 300)
        XCTAssertEqual(message.message(3)?.varint(7), 9)
        XCTAssertEqual(message.bytes(3), Proto.number(7, 9))
        XCTAssertNil(message.varint(3))
        XCTAssertNil(message.bytes(1))
        XCTAssertNil(message.varint(8))

        // A length past the end, an endless varint, a cut-off fixed number, a group, field zero.
        let broken: [Data] = [
            Data([0x0A, 0x7F, 0x01]), Data(repeating: 0xFF, count: 40), Data([0x09, 0x01, 0x02]),
            Data([0x0B, 0x00]), Data([0x00, 0x01]), Data([0x0A]), Data(),
        ]
        for data in broken {
            XCTAssertNil(ProtobufMessage(data).varint(1))
            XCTAssertNil(ProtobufMessage(data).bytes(1))
            XCTAssertNil(ProtobufMessage(data).message(1)?.message(4))
        }
        // A slice of a larger buffer reads the same as a copy.
        let padded = Data([0xFF, 0xFF]) + Proto.bytes(1, Proto.number(2, 77))
        XCTAssertEqual(ProtobufMessage(padded.dropFirst(2)).message(1)?.varint(2), 77)
    }

    func testAntigravityReadsCountsOncePerGenerationWithTheStepTime() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("c.db")
        let noon = UInt64(noonMillis / 1_000)
        let first = antigravityCounts(id: "r1")
        let second = antigravityCounts(id: "r2", input: 10, output: 30, cached: 0)
        let late = antigravityCounts(id: "r3", input: 7, output: 21, cached: 0)
        try antigravityDatabase(at: url, generations: [
            antigravityGeneration(first),
            // No counts, no usable counts, garbage: all passed over.
            Proto.bytes(1, Proto.bytes(4, Proto.number(1, 1_417))),
            antigravityGeneration(Proto.number(2, UInt64.max) + Proto.text(7, "big")),
            Data([0x0A, 0x7F, 0x01]),
            antigravityGeneration(second, model: "a model name with spaces"),
            // Its step isn't written yet: it takes the time of the one before.
            antigravityGeneration(late, model: nil),
        ], steps: [
            antigravityStep(nil, seconds: noon - 50),
            antigravityStep(first, seconds: noon),
            // A second step repeating the same response: the first time is kept.
            antigravityStep(first, seconds: noon + 5),
            antigravityStep(second, seconds: noon + 90_000),
            Data([0xFF]),
        ])

        let usage = try AntigravityUsage.read(databaseURL: url, limit: 100)
        XCTAssertFalse(usage.truncated)
        XCTAssertEqual(usage.events.count, 3)
        let event = usage.events[0]
        XCTAssertEqual(event.provider, .antigravity)
        XCTAssertEqual(event.model, "known")
        XCTAssertEqual(event.tokens.input, 1_000)
        XCTAssertEqual(event.tokens.cacheRead, 5_000)
        // Thinking (9) and response (10) are parts of the output (3), not extra.
        XCTAssertEqual(event.tokens.output, 60)
        XCTAssertEqual(event.tokens.cacheWrite5m, 0)
        XCTAssertNil(event.recordedUSD)
        XCTAssertEqual(event.timestamp.timeIntervalSince1970, Double(noon) + 0.5, accuracy: 0.001)
        // Anything not shaped like a model id is dropped, never stored.
        XCTAssertEqual(usage.events[1].model, "")
        XCTAssertEqual(usage.events[1].timestamp.timeIntervalSince1970, Double(noon) + 90_000.5, accuracy: 0.001)
        XCTAssertEqual(usage.events[2].model, "")
        XCTAssertEqual(usage.events[2].timestamp, usage.events[1].timestamp)
        XCTAssertEqual(Set(usage.events.map(\.identity)).count, 3)

        XCTAssertTrue(try AntigravityUsage.read(databaseURL: url, limit: 2).truncated)
        XCTAssertFalse(try AntigravityUsage.read(databaseURL: url, limit: 6).truncated)

        // Out of budget among the generations: what was read so far, marked as cut short.
        let stepBytes = try AntigravityUsage.read(databaseURL: url, limit: 0).bytes
        let short = try AntigravityUsage.read(databaseURL: url, limit: 100, byteBudget: stepBytes + 1)
        XCTAssertTrue(short.exhausted)
        XCTAssertEqual(short.events.count, 1)
        var calls = 0
        let stopped = try AntigravityUsage.read(databaseURL: url, limit: 100, shouldStop: { calls += 1; return calls > 6 })
        XCTAssertTrue(stopped.exhausted)
        XCTAssertEqual(stopped.events.count, 1)
        // Out of budget among the steps: nothing can be dated, so nothing is returned.
        XCTAssertThrowsError(try AntigravityUsage.read(databaseURL: url, limit: 100, byteBudget: 1))
        XCTAssertThrowsError(try AntigravityUsage.read(databaseURL: url, limit: 100, shouldStop: { true }))
    }

    func testAntigravityIgnoresOtherDatabasesAndThrowsOnUnreadableOnes() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let other = root.appendingPathComponent("other.db")
        try SQLiteDatabase(url: other).execute("CREATE TABLE notes(id INTEGER)")
        XCTAssertTrue(try AntigravityUsage.read(databaseURL: other, limit: 10).events.isEmpty)
        let junk = root.appendingPathComponent("junk.db")
        try Data(repeating: 0x41, count: 4_096).write(to: junk)
        XCTAssertThrowsError(try AntigravityUsage.read(databaseURL: junk, limit: 10))
    }

    func testScannerRereadsAnAntigravityConversationWithoutCountingTwice() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let conversations = root.appendingPathComponent("antigravity/conversations")
        try FileManager.default.createDirectory(at: conversations, withIntermediateDirectories: true)
        let url = conversations.appendingPathComponent("c1.db")
        let noon = UInt64(noonMillis / 1_000)
        let first = antigravityCounts(id: "r1")
        try antigravityDatabase(at: url, generations: [antigravityGeneration(first)],
                                steps: [antigravityStep(first, seconds: noon)])
        // The same conversation copied to a second file counts once.
        try antigravityDatabase(at: conversations.appendingPathComponent("copy.db"),
                                generations: [antigravityGeneration(first)],
                                steps: [antigravityStep(first, seconds: noon)])
        try Data("{}".utf8).write(to: conversations.appendingPathComponent("notes.json"))

        let source = SpendLogSource(provider: .antigravity, directory: conversations)
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        let one = await scanner.scan(sources: [source], now: now, calendar: calendar)
        XCTAssertFalse(one.isPartial)
        let total = one.total(provider: .antigravity, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(total.events, 1)
        XCTAssertEqual(total.tokens, 6_060)
        XCTAssertEqual(total.pricedEvents, 1)
        XCTAssertEqual(one.days.first?.source, "antigravity:\(source.folder):")

        // The conversation goes on: the whole database is read again, replacing what it had.
        let second = antigravityCounts(id: "r2", input: 10, output: 30, cached: 0)
        try antigravityDatabase(at: url, generations: [antigravityGeneration(first), antigravityGeneration(second)],
                                steps: [antigravityStep(first, seconds: noon), antigravityStep(second, seconds: noon + 60)])
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: url.path)
        let two = await scanner.scan(sources: [source], now: now, calendar: calendar)
        let grown = two.total(provider: .antigravity, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(grown.events, 2)
        XCTAssertEqual(grown.tokens, 6_100)
    }

    // MARK: Scanner

    func testScannerReadsAllThreeToolsAndCountsEachOnce() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default

        let opencode = root.appendingPathComponent("opencode")
        try fm.createDirectory(at: opencode, withIntermediateDirectories: true)
        let database = opencode.appendingPathComponent("opencode.db")
        try openCodeDatabase(at: database, rows: [("m1", noonMillis, assistant(created: noonMillis, cost: 0.5))])
        // Other files in OpenCode's folder are never walked or read.
        try Data("{}".utf8).write(to: opencode.appendingPathComponent("decoy.jsonl"))

        let vibe = root.appendingPathComponent("vibe/logs/session")
        try fm.createDirectory(at: vibe.appendingPathComponent("session_1"), withIntermediateDirectories: true)
        let meta = vibe.appendingPathComponent("session_1/meta.json")
        try json(vibeSession()).write(to: meta)
        try Data("{}".utf8).write(to: vibe.appendingPathComponent("session_1/messages.jsonl"))

        let copilot = root.appendingPathComponent("copilot/session-state")
        try fm.createDirectory(at: copilot.appendingPathComponent("abc"), withIntermediateDirectories: true)
        let line = try json(shutdown(["known-4.6": ["inputTokens": 1_000, "outputTokens": 40, "cacheReadTokens": 700]]))
        try (line + Data("\n".utf8)).write(to: copilot.appendingPathComponent("abc/events.jsonl"))
        try (line + Data("\n".utf8)).write(to: copilot.appendingPathComponent("abc/other.jsonl"))

        let sources = [
            SpendLogSource(provider: .opencode, directory: opencode),
            SpendLogSource(provider: .vibe, directory: vibe),
            SpendLogSource(provider: .copilot, directory: copilot),
        ]
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        let first = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(first.filesRead, 3)
        XCTAssertFalse(first.isPartial)
        XCTAssertEqual(first.pendingFiles, 0)

        let openCodeTotal = first.total(provider: .opencode, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(openCodeTotal.recordedUSD, 0.5)
        XCTAssertEqual(openCodeTotal.tokens, 100 + 25 + 30 + 7)
        let vibeTotal = first.total(provider: .vibe, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(vibeTotal.tokens, 1_050)
        XCTAssertEqual(vibeTotal.pricedEvents, 1)
        // "known-4.6" is priced through the "known-4-6" entry.
        let copilotTotal = first.total(provider: .copilot, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(copilotTotal.tokens, 1_040)
        XCTAssertEqual(copilotTotal.pricedEvents, 1)
        XCTAssertEqual(copilotTotal.unpricedEvents, 0)
        XCTAssertEqual(Set(first.days.map(\.source)), [
            "opencode:\(SpendLogSource(provider: .opencode, directory: opencode).directory.path):",
            "vibe:\(SpendLogSource(provider: .vibe, directory: root.appendingPathComponent("vibe")).directory.path):",
            "copilot:\(SpendLogSource(provider: .copilot, directory: root.appendingPathComponent("copilot")).directory.path):",
        ])

        // Nothing changed: nothing is read again.
        let second = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(second.filesRead, 0)
        XCTAssertEqual(second.filesReused, 3)

        // A Copilot log that grows is read on from where it stopped: the
        // repeated totals of a resumed session are skipped, new ones count.
        let events = copilot.appendingPathComponent("abc/events.jsonl")
        let more = try json(shutdown(["known-4.6": ["inputTokens": 10, "outputTokens": 5]]))
        try (line + Data("\n".utf8) + line + Data("\n".utf8) + more + Data("\n".utf8)).write(to: events)
        let appended = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(appended.total(provider: .copilot, period: .today, now: now, calendar: calendar).tokens, 1_055)

        // The Vibe session grows, and OpenCode gets a new message and finishes an old one.
        try json(vibeSession(prompt: 2_000, cached: 400, completion: 100)).write(to: meta)
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: meta.path)
        try openCodeDatabase(at: database, rows: [
            ("m1", noonMillis + 5, assistant(created: noonMillis, output: 120, cost: 0.75)),
            ("m2", noonMillis + 9, assistant(created: noonMillis)),
        ])
        try fm.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: database.path)
        let third = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(third.total(provider: .vibe, period: .today, now: now, calendar: calendar).tokens, 2_100)
        let grown = third.total(provider: .opencode, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(grown.events, 2)
        XCTAssertEqual(grown.recordedUSD, 0.75)
        XCTAssertEqual(grown.outputTokens, 125 + 25)
        XCTAssertEqual(third.total(provider: .copilot, period: .today, now: now, calendar: calendar).tokens, 1_055)
    }

    func testDefaultSourcesIncludeTheThreeToolHomes() {
        let home = URL(fileURLWithPath: "/Users/me")
        let sources = SpendLogSource.localSources(connections: [], home: home, environment: [:])
        func directory(_ provider: SpendProvider) -> [String] {
            sources.filter { $0.provider == provider }.map(\.directory.path)
        }
        XCTAssertEqual(directory(.opencode), ["/Users/me/.local/share/opencode"])
        XCTAssertEqual(directory(.vibe), ["/Users/me/.vibe/logs/session"])
        XCTAssertEqual(directory(.copilot), ["/Users/me/.copilot/session-state"])
        XCTAssertEqual(directory(.antigravity), ["/Users/me/.gemini/antigravity/conversations"])
        XCTAssertEqual(sources.first { $0.provider == .antigravity }?.folder, "/Users/me/.gemini/antigravity")
        XCTAssertEqual(sources.first { $0.provider == .vibe }?.folder, "/Users/me/.vibe")
        XCTAssertEqual(sources.first { $0.provider == .copilot }?.folder, "/Users/me/.copilot")
    }
}
