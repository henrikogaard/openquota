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
        let day = LocalSpendScanner.aggregate(LocalSpendScanner.deduplicate(events), pricing: pricing, calendar: calendar)[0]
        XCTAssertEqual(day.total.recordedUSD, 2.5)
        XCTAssertEqual(day.total.estimatedUSD, 0)
        XCTAssertEqual(day.total.unpricedEvents, 1)
        XCTAssertEqual(day.total.pricedEvents, 3)
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
        XCTAssertFalse(deleted.hasLogs)
        XCTAssertEqual(deleted.total(period: .today, now: now, calendar: calendar).pricedEvents, 0)
    }

    func testBoundedScannerReportsPartialInsteadOfCompleteZero() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        try json(claude(id: "one", model: "known")).write(to: root.appendingPathComponent("large.jsonl"))
        var limits = LocalSpendScanner.Limits()
        limits.fileBytes = 1
        let scanner = LocalSpendScanner(limits: limits, pricing: pricing)
        let result = await scanner.scan(sources: [.init(provider: .claude, directory: root)], now: now, calendar: calendar)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.filesRead, 0)
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
        XCTAssertEqual(first.total(period: .today, now: now, calendar: calendar).pricedEvents, 0)
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
