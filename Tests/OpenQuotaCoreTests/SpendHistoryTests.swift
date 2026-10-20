import Foundation
import XCTest
@testable import OpenQuotaCore

final class SpendHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))! }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func total(dollars: Double, events: Int, tokens: Int = 100) -> SpendTotal {
        var total = SpendTotal()
        total.estimatedUSD = dollars
        total.pricedEvents = events
        total.inputTokens = tokens
        return total
    }

    private func summary(_ days: [SpendDay], partial: Bool = false) -> SpendSummary {
        var summary = SpendSummary()
        summary.days = days
        summary.scannedAt = now
        summary.isPartial = partial
        return summary
    }

    func test_firstScanReachesBackAYearThenStartsTheDayBeforeTheLastScan() {
        var history = SpendHistory()
        XCTAssertEqual(history.nextScanStart(now: now, calendar: calendar), day(-364))
        history.record(summary([]), since: day(-364), calendar: calendar)
        XCTAssertEqual(history.nextScanStart(now: now, calendar: calendar), day(-1))
    }

    func test_partialFirstScanRetriesTheRecentMonth() {
        var history = SpendHistory()
        history.record(summary([], partial: true), since: day(-364), calendar: calendar)
        XCTAssertEqual(history.nextScanStart(now: now, calendar: calendar), day(-29))
        XCTAssertTrue(history.hasIncompleteDays(.days30, now: now, calendar: calendar))
        history.record(summary([]), since: day(-29), calendar: calendar)
        XCTAssertFalse(history.hasIncompleteDays(.days30, now: now, calendar: calendar))
        XCTAssertTrue(history.hasIncompleteDays(.year, now: now, calendar: calendar))
    }

    func test_rowIsReplacedOnlyWhenTheScanSawAtLeastAsManyRequests() {
        var history = SpendHistory()
        history.record(summary([
            SpendDay(date: day(-2), provider: .claude, model: "opus", total: total(dollars: 5, events: 10)),
        ]), since: day(-30), calendar: calendar)
        // Logs for that day were partly deleted: fewer requests, keep the saved row.
        history.record(summary([
            SpendDay(date: day(-2), provider: .claude, model: "opus", total: total(dollars: 2, events: 4)),
        ]), since: day(-3), calendar: calendar)
        XCTAssertEqual(history.total(.days30, now: now, calendar: calendar).dollars, 5)
        // More requests seen: replace.
        history.record(summary([
            SpendDay(date: day(-2), provider: .claude, model: "opus", total: total(dollars: 6, events: 12)),
        ]), since: day(-3), calendar: calendar)
        XCTAssertEqual(history.total(.days30, now: now, calendar: calendar).dollars, 6)
    }

    func test_daysBeforeTheScanStartAreNotTouched() {
        var history = SpendHistory()
        history.record(summary([
            SpendDay(date: day(-40), provider: .codex, model: "gpt", total: total(dollars: 9, events: 9)),
        ]), since: day(-364), calendar: calendar)
        history.record(summary([
            SpendDay(date: day(-40), provider: .codex, model: "gpt", total: total(dollars: 99, events: 99)),
        ]), since: day(-1), calendar: calendar)
        XCTAssertEqual(history.total(.days90, now: now, calendar: calendar).dollars, 9)
        XCTAssertEqual(history.total(.days30, now: now, calendar: calendar).dollars, 0)
    }

    func test_rangesBucketsAndTopModels() {
        var history = SpendHistory()
        history.record(summary([
            SpendDay(date: day(0), provider: .claude, model: "opus", total: total(dollars: 3, events: 1, tokens: 300)),
            SpendDay(date: day(0), provider: .codex, model: "gpt", total: total(dollars: 1, events: 1, tokens: 900)),
            SpendDay(date: day(-1), provider: .claude, model: "sonnet", total: total(dollars: 2, events: 1)),
            SpendDay(date: day(-100), provider: .claude, model: "opus", total: total(dollars: 10, events: 1)),
            SpendDay(date: day(-400), provider: .claude, model: "opus", total: total(dollars: 50, events: 1)),
            SpendDay(date: day(0), provider: .claude, model: "<synthetic>", total: total(dollars: 0, events: 3, tokens: 0)),
        ]), since: .distantPast, calendar: calendar)

        XCTAssertEqual(history.total(.days30, now: now, calendar: calendar).dollars, 6)
        XCTAssertEqual(history.total(.days30, provider: .codex, now: now, calendar: calendar).tokens, 900)
        XCTAssertEqual(history.total(.year, now: now, calendar: calendar).dollars, 16)
        XCTAssertEqual(history.total(.all, now: now, calendar: calendar).dollars, 66)

        let daily = history.buckets(.days30, now: now, calendar: calendar)
        XCTAssertEqual(daily.count, 3)
        let monthly = history.buckets(.all, now: now, calendar: calendar)
        XCTAssertTrue(monthly.allSatisfy { calendar.component(.day, from: $0.start) == 1 })

        let top = history.topModels(.year, now: now, calendar: calendar)
        XCTAssertEqual(top.map(\.model), ["opus", "sonnet", "gpt"])
        XCTAssertEqual(top.first?.total.dollars, 13)
    }

    func test_storeRoundTripsPrivatelyAndToleratesOldTotals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("oq-history-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let store = SpendHistoryStore(url: directory.appendingPathComponent("spend-history.json"))
        XCTAssertTrue(store.load().isEmpty)
        var history = SpendHistory()
        history.record(summary([
            SpendDay(date: day(0), provider: .claude, model: "opus", total: total(dollars: 1, events: 1)),
        ]), since: day(-1), calendar: calendar)
        try store.save(history)
        XCTAssertEqual(store.load(), history)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        try store.delete()
        XCTAssertTrue(store.load().isEmpty)

        let old = #"{"estimatedUSD":1.5,"recordedUSD":0,"pricedEvents":2,"unpricedEvents":0}"#
        let decoded = try JSONDecoder().decode(SpendTotal.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.dollars, 1.5)
        XCTAssertEqual(decoded.tokens, 0)
    }
}
