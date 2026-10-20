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

    private func total(dollars: Double, tokens: Int = 100, priced: Int = 1) -> SpendTotal {
        var total = SpendTotal()
        total.estimatedUSD = dollars
        total.pricedEvents = priced
        total.inputTokens = tokens
        return total
    }

    private let cli = "claude:/Users/me/.claude:cli"
    private let desktop = "claude:/Users/me/.claude:claude-desktop"
    private let codex = "codex:/Users/me/.codex:"

    private var history: SpendHistory {
        SpendHistory(days: [
            SpendDay(date: day(0), provider: .claude, source: cli, model: "opus", total: total(dollars: 3, tokens: 300)),
            SpendDay(date: day(0), provider: .claude, source: desktop, model: "opus", total: total(dollars: 2, tokens: 50)),
            SpendDay(date: day(0), provider: .codex, source: codex, model: "gpt", total: total(dollars: 1, tokens: 900)),
            SpendDay(date: day(-1), provider: .claude, source: cli, model: "sonnet", total: total(dollars: 2)),
            SpendDay(date: day(-100), provider: .claude, source: cli, model: "opus", total: total(dollars: 10)),
            SpendDay(date: day(-400), provider: .claude, source: cli, model: "opus", total: total(dollars: 50)),
            SpendDay(date: day(0), provider: .claude, source: cli, model: "<synthetic>", total: total(dollars: 0, tokens: 0, priced: 0)),
        ], calendar: calendar)
    }

    func test_rangesTotalsAndSources() {
        let history = history
        XCTAssertEqual(history.total(.days30, now: now, calendar: calendar).dollars, 8)
        XCTAssertEqual(history.total(.days30, provider: .codex, now: now, calendar: calendar).tokens, 900)
        XCTAssertEqual(history.total(.days30, source: desktop, now: now, calendar: calendar).dollars, 2)
        XCTAssertEqual(history.total(.year, now: now, calendar: calendar).dollars, 18)
        XCTAssertEqual(history.total(.all, now: now, calendar: calendar).dollars, 68)
        XCTAssertEqual(history.sources(.days30, now: now, calendar: calendar).map(\.source), [cli, desktop, codex])
    }

    func test_bucketsBySourceAndGranularity() {
        let history = history
        let daily = history.buckets(.days30, now: now, calendar: calendar)
        XCTAssertEqual(daily.count, 4, "Today has three sources, yesterday one")
        let monthly = history.buckets(.all, now: now, calendar: calendar)
        XCTAssertTrue(monthly.allSatisfy { calendar.component(.day, from: $0.start) == 1 })
    }

    func test_topModelsSkipEmptyRows() {
        let top = history.topModels(.year, now: now, calendar: calendar)
        XCTAssertEqual(top.map(\.model), ["opus", "sonnet", "gpt"])
        XCTAssertEqual(top.first?.total.dollars, 15)
    }

    func test_sourceKeyKeepsColonsInFolder() {
        let source = SpendSource(provider: .claude, folder: "/Volumes/A:B/.claude", app: "cli")
        XCTAssertEqual(SpendSource(key: source.key), source)
        XCTAssertEqual(SpendSource(key: "codex:/Users/me/.codex:")?.app, "")
        XCTAssertNil(SpendSource(key: "other:/x:y"))
    }

    func test_oldTotalsWithoutTokensStillDecode() throws {
        let old = #"{"estimatedUSD":1.5,"recordedUSD":0,"pricedEvents":2,"unpricedEvents":0}"#
        let decoded = try JSONDecoder().decode(SpendTotal.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.dollars, 1.5)
        XCTAssertEqual(decoded.tokens, 0)
    }
}
