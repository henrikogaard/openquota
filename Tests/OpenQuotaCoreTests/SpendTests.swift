import XCTest
@testable import OpenQuotaCore

final class SpendTests: XCTestCase {
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
                     primary: PricingCatalog(entries: ["known": rates, "gpt-5": rates]), secondary: PricingCatalog())
    }

    func testTokenBucketsAndRequestWideLongContext() {
        let tokens = TokenBreakdown(input: 100, cacheWrite5m: 200, cacheWrite1h: 300,
                                    cacheRead: 400, output: 500)
        // 100*2 + 200*2.5 + 300*4 + 400*.2 + 500*10 = 6980 per million.
        XCTAssertEqual(rates.costDollars(for: tokens), 0.00698, accuracy: 1e-10)
        var long = tokens
        long.input = 200_001
        XCTAssertEqual(rates.costDollars(for: long), 0.813564, accuracy: 1e-10)
        long.isFast = true
        XCTAssertEqual(rates.costDollars(for: long), 1.627128, accuracy: 1e-10)
    }

    func testBundledModelResolutionAndUnknownVersions() throws {
        let pricing = try ModelPricing.bundled()
        XCTAssertNotNil(pricing.resolve(model: "claude-sonnet-4-20250514"))
        XCTAssertNotNil(pricing.resolve(model: "gpt-5"))
        XCTAssertNil(pricing.resolve(model: "totally-unpublished-model"))
        let catalog = PricingCatalog(entries: ["claude-sonnet-4": rates])
        XCTAssertNotNil(catalog.findFuzzy("claude-sonnet-4-20250514"))
        XCTAssertNil(catalog.findFuzzy("claude-sonnet-4-5"))
        XCTAssertNil(catalog.findFuzzy("claude-sonnet-40"))
    }

    func testClaudeCacheNormalizationAndSidechainDeduplication() throws {
        var parser = SpendLogParser(provider: .claude, fileIdentity: "source-a")
        var object = claude(id: "message", model: "known")
        object["message"] = [
            "id": "message", "model": "known",
            "usage": ["input_tokens": 100, "output_tokens": 500, "cache_creation_input_tokens": 500,
                      "cache_creation": ["ephemeral_5m_input_tokens": 200, "ephemeral_1h_input_tokens": 300],
                      "cache_read_input_tokens": 400],
        ]
        let first = try parse(object, with: &parser)
        XCTAssertEqual(first[0].tokens.totalTokens, 1500)
        object["isSidechain"] = true
        object["requestId"] = "different-replay-request"
        let replay = try parse(object, with: &parser)
        let deduped = LocalSpendScanner.deduplicate(replay + first + first)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertFalse(deduped[0].sidechain)
        let day = LocalSpendScanner.aggregate(deduped, pricing: pricing, calendar: calendar)
        XCTAssertEqual(day[0].total.estimatedUSD, 0.00698, accuracy: 1e-10)
        object["message"] = ["id": "hour-only", "model": "known",
                             "usage": ["input_tokens": 1, "output_tokens": 1, "cache_creation_input_tokens": 20,
                                       "cache_creation": ["ephemeral_1h_input_tokens": 20]]]
        let oneHour = try parse(object, with: &parser)
        XCTAssertEqual(oneHour[0].tokens.cacheWrite5m, 0)
        XCTAssertEqual(oneHour[0].tokens.cacheWrite1h, 20)
    }

    func testRecordedCostPrecedenceUnknownModelsAndDistinctRequests() throws {
        var parser = SpendLogParser(provider: .claude, fileIdentity: "source")
        var known = claude(id: "same-message", model: "known")
        known["costUSD"] = 1.25
        var otherRequest = known
        otherRequest["requestId"] = "second-request"
        var zero = claude(id: "zero", model: "unknown")
        zero["costUSD"] = 0
        let events = try [known, otherRequest, zero, claude(id: "unknown", model: "unknown")]
            .flatMap { try parse($0, with: &parser) }
        let rows = LocalSpendScanner.aggregate(LocalSpendScanner.deduplicate(events), pricing: pricing, calendar: calendar)
        XCTAssertEqual(Set(rows.map(\.model)), ["known", "unknown"])
        let total = rows.reduce(into: SpendTotal()) { $0.add($1.total) }
        XCTAssertEqual(total.recordedUSD, 2.5)
        XCTAssertEqual(total.estimatedUSD, 0)
        XCTAssertEqual(total.unpricedEvents, 1)
        XCTAssertEqual(total.pricedEvents, 3)
    }

    func testDuplicateWithRicherSpeedKeepsRecordedCost() throws {
        var parser = SpendLogParser(provider: .claude, fileIdentity: "source")
        var costed = claude(id: "message", model: "known")
        costed["costUSD"] = 1.25
        var fast = claude(id: "message", model: "known")
        fast["message"] = ["id": "message", "model": "known",
                           "usage": ["input_tokens": 100, "output_tokens": 20, "speed": "standard"]]
        let events = try [costed, fast].flatMap { try parse($0, with: &parser) }
        let deduped = LocalSpendScanner.deduplicate(events)
        XCTAssertEqual(deduped.count, 1)
        XCTAssertTrue(deduped[0].hasSpeed)
        let day = LocalSpendScanner.aggregate(deduped, pricing: pricing, calendar: calendar)[0]
        XCTAssertEqual(day.total.recordedUSD, 1.25)
        XCTAssertEqual(day.total.estimatedUSD, 0)
    }

    func testCodexCumulativeDeltasCachingAndRepeatedSnapshots() throws {
        var parser = SpendLogParser(provider: .codex, fileIdentity: "file")
        _ = try parse(["type": "session_meta", "timestamp": stamp,
                       "payload": ["id": "session"]], with: &parser)
        _ = try parse(["type": "turn_context", "payload": ["model": "gpt-5"]], with: &parser)
        let first = try parse(codex(input: 100, cached: 40, output: 20), with: &parser)
        XCTAssertEqual(first[0].tokens.input, 60)
        XCTAssertEqual(first[0].tokens.cacheRead, 40)
        XCTAssertEqual(first[0].tokens.output, 20) // reasoning already included, not added twice.
        XCTAssertTrue(try parse(codex(input: 100, cached: 40, output: 20), with: &parser).isEmpty)
        let second = try parse(codex(input: 160, cached: 50, output: 35), with: &parser)
        XCTAssertEqual(second[0].tokens.input, 50)
        XCTAssertEqual(second[0].tokens.cacheRead, 10)
        XCTAssertEqual(second[0].tokens.output, 15)
        let total = LocalSpendScanner.aggregate(first + second, pricing: pricing, calendar: calendar)[0].total
        XCTAssertEqual(total.estimatedUSD, 0.00058, accuracy: 1e-10) // 110*2 + 50*.2 + 35*10
    }

    func testCodexChildHistorySeedsButDoesNotChargeParent() throws {
        var parser = SpendLogParser(provider: .codex, fileIdentity: "child")
        _ = try parse(["type": "session_meta", "timestamp": stamp,
                       "payload": ["id": "child", "forked_from_id": "parent"]], with: &parser)
        _ = try parse(["type": "turn_context", "payload": ["model": "gpt-5"]], with: &parser)
        XCTAssertTrue(try parse(codex(input: 1000, cached: 200, output: 100), with: &parser).isEmpty)
        _ = try parse(["type": "event_msg", "timestamp": stamp,
                       "payload": ["type": "task_started", "started_at": now.timeIntervalSince1970]], with: &parser)
        let events = try parse(codex(input: 1100, cached: 240, output: 120), with: &parser)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].tokens.totalTokens, 120)
    }

    func testDatabaseRemembersReadFilesAcrossLaunchesAndKeepsDeletedHistory() async throws {
        let root = try directory()
        let databaseURL = root.appendingPathComponent("usage.sqlite")
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("projects")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("log.jsonl")
        try json(claude(id: "one", model: "known")).write(to: file)
        let sources = [SpendLogSource(provider: .claude, directory: logs)]

        let first = await LocalSpendScanner(limits: .init(), pricing: pricing, databaseURL: databaseURL)
            .scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(first.filesRead, 1)
        let total = first.total(period: .today, now: now, calendar: calendar)
        XCTAssertEqual(total.inputTokens, 100)
        XCTAssertEqual(total.outputTokens, 20)
        XCTAssertEqual(first.days.first?.model, "known")

        // A new scanner on the same database (the next launch) reads nothing.
        let relaunched = LocalSpendScanner(limits: .init(), pricing: pricing, databaseURL: databaseURL)
        let saved = await relaunched.savedDays(calendar: calendar)
        XCTAssertEqual(saved.count, 1)
        let second = await relaunched.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(second.filesRead, 0)
        XCTAssertEqual(second.filesReused, 1)
        XCTAssertEqual(second.total(period: .today, now: now, calendar: calendar).pricedEvents, 1)

        // Logs deleted by the CLI keep their saved totals.
        try FileManager.default.removeItem(at: file)
        let deleted = await relaunched.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(deleted.total(period: .today, now: now, calendar: calendar).pricedEvents, 1)

        await relaunched.deleteAll()
        let empty = await LocalSpendScanner(limits: .init(), pricing: pricing, databaseURL: databaseURL)
            .savedDays(calendar: calendar)
        XCTAssertTrue(empty.isEmpty)
    }

    func testBigClaudeFolderDoesNotCrowdOutCodex() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeLogs = root.appendingPathComponent(".claude/projects")
        let codexLogs = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: claudeLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexLogs, withIntermediateDirectories: true)
        for index in 0..<5 {
            try json(claude(id: "c\(index)", model: "known")).write(to: claudeLogs.appendingPathComponent("\(index).jsonl"))
        }
        try json(codex(input: 1000, cached: 0, output: 100)).write(to: codexLogs.appendingPathComponent("rollout.jsonl"))
        var limits = LocalSpendScanner.Limits()
        limits.files = 3
        func size(_ url: URL) throws -> Int { try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! Int }
        // Room for one Claude file and the Codex file only.
        limits.scanBytes = try size(claudeLogs.appendingPathComponent("0.jsonl"))
            + size(codexLogs.appendingPathComponent("rollout.jsonl")) + 10
        let scanner = LocalSpendScanner(limits: limits, pricing: pricing)
        let sources = [SpendLogSource(provider: .claude, directory: claudeLogs),
                       SpendLogSource(provider: .codex, directory: codexLogs)]
        let first = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(first.total(provider: .codex, period: .today, now: now, calendar: calendar).events, 1,
                       "Codex gets a turn even though Claude has more files than the limits")
        XCTAssertGreaterThan(first.pendingFiles, 0)
        // Later passes continue where the last one stopped.
        var pass = first
        while pass.pendingFiles > 0 { pass = await scanner.scan(sources: sources, now: now, calendar: calendar) }
        XCTAssertEqual(pass.total(provider: .claude, period: .today, now: now, calendar: calendar).pricedEvents, 3,
                       "Per-folder file limit")
    }

    func testClaudeUsageIsSplitByAppAndResumedCopiesCountOnce() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent(".claude/projects")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        var desktop = claude(id: "d1", model: "known")
        desktop["entrypoint"] = "claude-desktop"
        var cli = claude(id: "c1", model: "known")
        cli["entrypoint"] = "cli"
        try (json(desktop) + json(cli)).write(to: logs.appendingPathComponent("a.jsonl"))
        // A resumed session copies an earlier message into a new file.
        try json(cli).write(to: logs.appendingPathComponent("b.jsonl"))
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        let result = await scanner.scan(sources: [SpendLogSource(provider: .claude, directory: logs)], now: now, calendar: calendar)
        let folder = logs.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath().path
        let bySource = Dictionary(grouping: result.days, by: \.source).mapValues { $0.reduce(0) { $0 + $1.total.pricedEvents } }
        XCTAssertEqual(bySource["claude:\(folder):claude-desktop"], 1)
        XCTAssertEqual(bySource["claude:\(folder):cli"], 1)
        XCTAssertEqual(SpendSource(key: "claude:\(folder):cli"), SpendSource(provider: .claude, folder: folder, app: "cli"))
    }

    func testScanCacheAppendDeletionAndPrivacyBoundary() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("log.jsonl")
        try json(claude(id: "one", model: "known")).write(to: file)
        try Data("not usage".utf8).write(to: root.appendingPathComponent("auth.json"))
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        let sources = [SpendLogSource(provider: .claude, directory: root)]
        let first = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(first.filesRead, 1)
        XCTAssertEqual(first.total(period: .today, now: now, calendar: calendar).pricedEvents, 1)
        let second = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(second.filesReused, 1)
        try (json(claude(id: "one", model: "known")) + json(claude(id: "two", model: "known"))).write(to: file)
        let third = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(third.filesRead, 1)
        XCTAssertEqual(third.total(period: .today, now: now, calendar: calendar).pricedEvents, 2)
        try FileManager.default.removeItem(at: file)
        let deleted = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(deleted.total(period: .today, now: now, calendar: calendar).pricedEvents, 2,
                       "Saved history outlives deleted logs")
    }

    func testOversizedCodexFileIsSkippedAndReportedPartial() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try json(codex(input: 100, cached: 0, output: 10)).write(to: root.appendingPathComponent("large.jsonl"))
        var limits = LocalSpendScanner.Limits()
        limits.fileBytes = 1
        let scanner = LocalSpendScanner(limits: limits, pricing: pricing)
        let result = await scanner.scan(sources: [.init(provider: .codex, directory: root)], now: now, calendar: calendar)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.skippedFiles, 1)
        XCTAssertEqual(result.filesRead, 0)
    }

    func testLargeClaudeFileIsReadAcrossPassesAndAppendsReadOnlyNewLines() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("long.jsonl")
        let lines = try (0..<6).map { try json(claude(id: "m\($0)", model: "known")) }
        try lines.reduce(Data(), +).write(to: file)
        var limits = LocalSpendScanner.Limits()
        limits.scanBytes = lines[0].count * 2 + 1 // about two lines per pass
        let scanner = LocalSpendScanner(limits: limits, pricing: pricing)
        let sources = [SpendLogSource(provider: .claude, directory: root)]
        var passes = 0
        var result = SpendSummary()
        repeat {
            result = await scanner.scan(sources: sources, now: now, calendar: calendar)
            passes += 1
        } while result.pendingFiles > 0 && passes < 10
        XCTAssertGreaterThan(passes, 1, "Read in pieces")
        XCTAssertEqual(result.total(period: .today, now: now, calendar: calendar).pricedEvents, 6)

        // Two more lines appended, plus a half-written one: only the two are read.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: json(claude(id: "m6", model: "known")) + json(claude(id: "m7", model: "known")))
        try handle.write(contentsOf: Data(#"{"timestamp":"#.utf8))
        try handle.close()
        limits.scanBytes = 256 * 1_024 * 1_024
        let grown = await LocalSpendScanner(limits: limits, pricing: pricing).scan(sources: sources, now: now, calendar: calendar)
        // A fresh scanner without a database file rereads everything; the
        // shared one below appends.
        XCTAssertEqual(grown.total(period: .today, now: now, calendar: calendar).pricedEvents, 8)
        let appended = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(appended.total(period: .today, now: now, calendar: calendar).pricedEvents, 8)
        XCTAssertFalse(appended.isPartial, "A half-written last line waits for the next pass")
    }

    func testCodexFileReadInPiecesMatchesOneRead() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let lines: [[String: Any]] = [
            ["type": "session_meta", "timestamp": stamp, "payload": ["id": "session"]],
            ["type": "turn_context", "payload": ["model": "gpt-5"]],
            codex(input: 1000, cached: 200, output: 100),
            codex(input: 2500, cached: 900, output: 300),
            codex(input: 4000, cached: 1500, output: 650),
        ]
        let data = try lines.map(json).reduce(Data(), +)
        try data.write(to: root.appendingPathComponent("rollout.jsonl"))
        let sources = [SpendLogSource(provider: .codex, directory: root)]
        let whole = await LocalSpendScanner(limits: .init(), pricing: pricing).scan(sources: sources, now: now, calendar: calendar)
        var limits = LocalSpendScanner.Limits()
        limits.scanBytes = 120 // a line or so per pass
        let scanner = LocalSpendScanner(limits: limits, pricing: pricing)
        var passes = 0
        var pieces = SpendSummary()
        repeat {
            pieces = await scanner.scan(sources: sources, now: now, calendar: calendar)
            passes += 1
        } while pieces.pendingFiles > 0 && passes < 20
        XCTAssertGreaterThan(passes, 2)
        let a = whole.total(period: .today, now: now, calendar: calendar)
        let b = pieces.total(period: .today, now: now, calendar: calendar)
        XCTAssertEqual(a.pricedEvents, 3)
        XCTAssertEqual(b, a)
    }

    func testPrunedDaysStayPerSourceSoANewFolderStillCounts() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a/projects")
        let second = root.appendingPathComponent("b/projects")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        var old = claude(id: "old-a", model: "known")
        old["timestamp"] = now.addingTimeInterval(-10 * 86_400).ISO8601Format()
        try json(old).write(to: first.appendingPathComponent("a.jsonl"))
        var limits = LocalSpendScanner.Limits()
        limits.eventDays = 2
        let scanner = LocalSpendScanner(limits: limits, pricing: pricing)
        _ = await scanner.scan(sources: [SpendLogSource(provider: .claude, directory: first)], now: now, calendar: calendar)
        // A folder connected later has usage on that already-pruned day.
        var other = old
        other["message"] = ["id": "old-b", "model": "known", "usage": ["input_tokens": 100, "output_tokens": 20]]
        try json(other).write(to: second.appendingPathComponent("b.jsonl"))
        let both = await scanner.scan(sources: [SpendLogSource(provider: .claude, directory: first),
                                               SpendLogSource(provider: .claude, directory: second)],
                                      now: now, calendar: calendar)
        XCTAssertEqual(both.days.reduce(0) { $0 + $1.total.pricedEvents }, 2)
        XCTAssertEqual(Set(both.days.map(\.source)).count, 2)
    }

    func testUnreadableLinesKeepTheTotalPartialUntilTheFileChanges() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("log.jsonl")
        try (json(claude(id: "ok", model: "known")) + Data("{\"usage\": broken\n".utf8)).write(to: file)
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        let sources = [SpendLogSource(provider: .claude, directory: root)]
        let first = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertTrue(first.isPartial)
        let again = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(again.filesRead, 0)
        XCTAssertTrue(again.isPartial, "Still short of the unusable line")
        XCTAssertEqual(again.unreadableFiles, 1)
        try json(claude(id: "ok", model: "known")).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: file.path)
        let fixed = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertFalse(fixed.isPartial)
    }

    func testFileRewrittenAtTheSameSizeIsReadAgain() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("log.jsonl")
        try json(claude(id: "same", model: "known")).write(to: file)
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        let sources = [SpendLogSource(provider: .claude, directory: root)]
        let first = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(first.total(period: .today, now: now, calendar: calendar).pricedEvents, 1)
        try json(claude(id: "same", model: "other")).write(to: file) // same length, unpriced model
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(60)], ofItemAtPath: file.path)
        let rewritten = await scanner.scan(sources: sources, now: now, calendar: calendar)
        let total = rewritten.total(period: .today, now: now, calendar: calendar)
        XCTAssertEqual(total.pricedEvents, 0)
        XCTAssertEqual(total.unpricedEvents, 1)
    }

    func testUnchangedFileRetainsEventsWrittenAfterScanStart() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var request = claude(id: "in-flight", model: "known")
        request["timestamp"] = now.addingTimeInterval(60).ISO8601Format()
        try json(request).write(to: root.appendingPathComponent("active.jsonl"))
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        let sources = [SpendLogSource(provider: .claude, directory: root)]
        let first = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(first.filesRead, 1)
        let later = now.addingTimeInterval(120)
        let second = await scanner.scan(sources: sources, now: later, calendar: calendar)
        XCTAssertEqual(second.filesReused, 1)
        XCTAssertEqual(second.total(period: .today, now: later, calendar: calendar).pricedEvents, 1)
    }

    func testCalendarPeriodsAreDisjointAndUseLocalDays() {
        var summary = SpendSummary()
        let today = calendar.startOfDay(for: now)
        for offset in [0, -1, -29, -30] {
            var total = SpendTotal()
            total.estimatedUSD = 1
            summary.days.append(SpendDay(date: calendar.date(byAdding: .day, value: offset, to: today)!,
                                         provider: .claude, total: total))
        }
        XCTAssertEqual(summary.total(period: .today, now: now, calendar: calendar).dollars, 1)
        XCTAssertEqual(summary.total(period: .yesterday, now: now, calendar: calendar).dollars, 1)
        XCTAssertEqual(summary.total(period: .thirtyDays, now: now, calendar: calendar).dollars, 3)
        var oslo = calendar
        oslo.timeZone = TimeZone(identifier: "Europe/Oslo")!
        let transition = SpendLogParser.date("2026-03-30T12:00:00Z")!
        XCTAssertEqual(SpendPeriod.yesterday.interval(now: transition, calendar: oslo).duration, 23 * 3600)
    }

    private var stamp: String { now.ISO8601Format() }
    private func claude(id: String, model: String) -> [String: Any] {
        ["timestamp": stamp, "requestId": "request", "message":
            ["id": id, "model": model, "usage": ["input_tokens": 100, "output_tokens": 20]]]
    }
    private func codex(input: Int, cached: Int, output: Int) -> [String: Any] {
        ["type": "event_msg", "timestamp": stamp, "payload":
            ["type": "token_count", "info":
                ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached,
                                      "output_tokens": output, "reasoning_output_tokens": 5]]]]
    }
    private func json(_ object: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([0x0A])
    }
    private func parse(_ object: [String: Any], with parser: inout SpendLogParser) throws -> [SpendEvent] {
        parser.parse(try json(object), lineNumber: 1)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
