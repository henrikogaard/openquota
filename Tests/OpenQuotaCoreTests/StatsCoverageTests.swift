import Foundation
import XCTest
@testable import OpenQuotaCore

final class StatsCoverageTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return c
    }
    private var now: Date { calendar.date(from: .init(year: 2026, month: 10, day: 26, hour: 14))! }

    func testShortRangesUseCalendarDaysAcrossDSTAndYesterdayExcludesToday() {
        let days = (-8...1).map { offset in
            var total = SpendTotal(); total.estimatedUSD = 1; total.pricedEvents = 1
            return SpendDay(date: calendar.date(byAdding: .day, value: offset, to: now)!, provider: .claude,
                            model: "test", total: total)
        }
        let history = SpendHistory(days: days, calendar: calendar)
        XCTAssertEqual(history.total(.today, now: now, calendar: calendar).dollars, 1)
        XCTAssertEqual(history.total(.yesterday, now: now, calendar: calendar).dollars, 1)
        XCTAssertEqual(history.total(.days7, now: now, calendar: calendar).dollars, 7)
        XCTAssertEqual(history.buckets(.yesterday, now: now, calendar: calendar).first?.start,
                       calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        let interval = SpendPeriod.sevenDays.interval(now: now, calendar: calendar)
        XCTAssertEqual(interval.start, calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)))
        XCTAssertEqual(history.sources(.days7, now: now, calendar: calendar).first?.total.dollars, 7)
        XCTAssertEqual(history.topModels(.days7, now: now, calendar: calendar).first?.total.dollars, 7)
    }

    func testPublishedMissingModelsAndHaikuRequestWideThreshold() throws {
        let pricing = try ModelPricing.bundled()
        let fable = try XCTUnwrap(pricing.resolve(model: "claude-fable-5-2"))
        XCTAssertEqual(fable.costDollars(for: .init(input: 1000, cacheWrite5m: 1000, cacheWrite1h: 1000, cacheRead: 1000, output: 1000)), 0.0742, accuracy: 1e-10)
        XCTAssertEqual(fable.costDollars(for: .init(input: 1000, output: 1000, isFast: true)), 0.096, accuracy: 1e-10)
        let haiku = try XCTUnwrap(pricing.resolve(model: "claude-haiku-5-5"))
        XCTAssertEqual(haiku.costDollars(for: .init(input: 100_000, output: 1000)), 0.0105, accuracy: 1e-10)
        XCTAssertEqual(haiku.costDollars(for: .init(input: 100_001, output: 1000)), 0.0525005, accuracy: 1e-10)
        XCTAssertEqual(haiku.costDollars(for: .init(cacheWrite1h: 100_001, cacheRead: 1000)), 0.100051, accuracy: 1e-10)
        let hydrogen = try XCTUnwrap(pricing.resolve(model: "gemini-4-hydrogen"))
        XCTAssertEqual(hydrogen.costDollars(for: .init(input: 1000, cacheRead: 1000, output: 1000)), 0.009075, accuracy: 1e-10)
        XCTAssertNil(pricing.resolve(model: "claude-fable-5-99"))
    }

    func testNewRatesRepriceCachedEventsWithoutRereadingOrDoubling() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let timestamp = ISO8601DateFormatter().string(from: now)
        try Data("{\"type\":\"assistant\",\"timestamp\":\"\(timestamp)\",\"message\":{\"id\":\"fixture\",\"model\":\"new-model\",\"usage\":{\"input_tokens\":1000,\"output_tokens\":1000}}}\n".utf8).write(to: file)
        let database = directory.appendingPathComponent("usage.sqlite")
        let source = SpendLogSource(provider: .claude, directory: directory)
        let first = await LocalSpendScanner(limits: .init(), pricing: .empty, databaseURL: database)
            .scan(sources: [source], now: now, calendar: calendar)
        XCTAssertEqual(first.total(period: .today, now: now, calendar: calendar).unpricedEvents, 1)
        let pricing = ModelPricing(supplement: .init(), primary: .init(entries: ["new-model": .init(inputPerMillion: 2, outputPerMillion: 10, cacheWritePerMillion: 2.5, cacheReadPerMillion: 0.2)]), secondary: .init())
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing, databaseURL: database)
        let second = await scanner.scan(sources: [source], now: now, calendar: calendar)
        XCTAssertEqual(second.filesRead, 0)
        XCTAssertEqual(second.filesReused, 1)
        XCTAssertEqual(second.total(period: .today, now: now, calendar: calendar).dollars, 0.012, accuracy: 1e-10)
        XCTAssertEqual(second.total(period: .today, now: now, calendar: calendar).unpricedEvents, 0)
        let third = await scanner.scan(sources: [source], now: now, calendar: calendar)
        XCTAssertEqual(third.total(period: .today, now: now, calendar: calendar).dollars, 0.012, accuracy: 1e-10)
    }
}
