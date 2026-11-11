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

        XCTAssertEqual(try OpenCodeUsage.read(databaseURL: url, after: 10, limit: 100).events.map(\.identity), ["m4"])
        XCTAssertTrue(try OpenCodeUsage.read(databaseURL: url, after: 40, limit: 100).events.isEmpty)
    }

    func testOpenCodeRowLimitReportsMoreAndRereadsTheLastTimestamp() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("opencode.db")
        try openCodeDatabase(at: url, rows: [
            ("m1", 10, assistant(created: noonMillis)), ("m2", 20, assistant(created: noonMillis)),
            ("m3", 20, assistant(created: noonMillis)),
        ])
        let page = try OpenCodeUsage.read(databaseURL: url, after: 0, limit: 2)
        XCTAssertTrue(page.more)
        XCTAssertEqual(page.cursor, 19)
        // A full page of one timestamp still moves on.
        XCTAssertEqual(try OpenCodeUsage.read(databaseURL: url, after: 19, limit: 2).cursor, 20)
        let rest = try OpenCodeUsage.read(databaseURL: url, after: page.cursor, limit: 10)
        XCTAssertEqual(Set(rest.events.map(\.identity)), ["m2", "m3"])
        XCTAssertFalse(rest.more)
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
        XCTAssertEqual(third.total(provider: .copilot, period: .today, now: now, calendar: calendar).tokens, 1_040)
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
        XCTAssertEqual(sources.first { $0.provider == .vibe }?.folder, "/Users/me/.vibe")
        XCTAssertEqual(sources.first { $0.provider == .copilot }?.folder, "/Users/me/.copilot")
    }
}
