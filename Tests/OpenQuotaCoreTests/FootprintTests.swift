import Foundation
import XCTest
@testable import OpenQuotaCore

final class FootprintTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Oslo")!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 15))! }

    private func day(_ offset: Int) -> Date {
        calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now))!
    }

    private func total(input: Int = 0, cacheWrite: Int = 0, cacheRead: Int = 0, output: Int = 0, events: Int = 1) -> SpendTotal {
        var total = SpendTotal()
        total.inputTokens = input
        total.cacheWriteTokens = cacheWrite
        total.cacheReadTokens = cacheRead
        total.outputTokens = output
        total.pricedEvents = events
        return total
    }

    func test_outputTokensUseThePublishedRange() {
        let footprint = Footprint(total(output: 1000), model: "claude-sonnet-5")
        XCTAssertEqual(footprint.energyWh.low, 0.3, accuracy: 1e-9)
        XCTAssertEqual(footprint.energyWh.mid, 1.0, accuracy: 1e-9)
        XCTAssertEqual(footprint.energyWh.high, 3.0, accuracy: 1e-9)
        XCTAssertEqual(footprint.cacheSavedWh, 0)
        XCTAssertEqual(footprint.requests, 1)
    }

    func test_inputCacheWriteAndCacheReadWeights() {
        // 1,000 input = 200 output equivalents; cache write 1.25x; cache read 0.1x.
        XCTAssertEqual(Footprint(total(input: 1000), model: "x").energyWh.mid, 0.2, accuracy: 1e-9)
        XCTAssertEqual(Footprint(total(cacheWrite: 1000), model: "x").energyWh.mid, 0.25, accuracy: 1e-9)
        let cached = Footprint(total(cacheRead: 1000), model: "x")
        XCTAssertEqual(cached.energyWh.mid, 0.02, accuracy: 1e-9)
        XCTAssertEqual(cached.cacheSavedWh, 0.18, accuracy: 1e-9)
        XCTAssertEqual(cached.cacheSavedShare, 0.9, accuracy: 1e-9)
        XCTAssertEqual(cached.newInputTokens, 0)
        XCTAssertEqual(Footprint(total(input: 3, cacheWrite: 4), model: "x").newInputTokens, 7)
    }

    func test_modelClassesFromNames() {
        XCTAssertEqual(FootprintModelClass(model: "claude-haiku-4-5-20251001"), .small)
        XCTAssertEqual(FootprintModelClass(model: "gpt-5-codex-mini"), .small)
        XCTAssertEqual(FootprintModelClass(model: "claude-opus-5"), .large)
        XCTAssertEqual(FootprintModelClass(model: "gpt-5-pro"), .large)
        XCTAssertEqual(FootprintModelClass(model: "claude-sonnet-5"), .standard)
        XCTAssertEqual(FootprintModelClass(model: "gpt-5-codex"), .standard)
        XCTAssertEqual(FootprintModelClass(model: "gemini-3"), .standard, "Whole words only: not 'mini'")
        XCTAssertEqual(FootprintModelClass(model: "minimax-m2"), .standard)
        XCTAssertEqual(FootprintModelClass(model: "o4-mini-2025-04-16"), .small)
        XCTAssertEqual(FootprintModelClass(model: ""), .standard, "An unknown model is not guessed large or small")
        XCTAssertEqual(Footprint(total(output: 1000), model: "claude-opus-5").energyWh.mid, 2.0, accuracy: 1e-9)
        XCTAssertEqual(Footprint(total(output: 1000), model: "claude-haiku-4-5").energyWh.high, 0.75, accuracy: 1e-9)
    }

    func test_carbonAndWaterScaleWithEnergy() {
        let footprint = Footprint(total(output: 1_000_000), model: "claude-sonnet-5") // 0.3 / 1 / 3 kWh
        let norway = footprint.co2Grams(.preset("norway"))
        XCTAssertEqual(norway.low, 8.4, accuracy: 1e-9)
        XCTAssertEqual(norway.mid, 28, accuracy: 1e-9)
        XCTAssertEqual(norway.high, 84, accuracy: 1e-9)
        XCTAssertEqual(footprint.co2Grams(.preset("no-such-grid")).mid, 384, accuracy: 1e-9)
        let water = footprint.waterML()
        XCTAssertEqual(water.low, 45, accuracy: 1e-9, "Low energy with the low water factor")
        XCTAssertEqual(water.mid, 650, accuracy: 1e-9)
        XCTAssertEqual(water.high, 3450, accuracy: 1e-9)
    }

    func test_historyTotalsBucketsAndModels() {
        let source = "claude:/Users/me/.claude:cli"
        let history = SpendHistory(days: [
            SpendDay(date: day(0), provider: .claude, source: source, model: "claude-opus-5", total: total(output: 1000, events: 2)),
            SpendDay(date: day(0), provider: .codex, source: "codex:/Users/me/.codex:", model: "gpt-5-codex", total: total(output: 500)),
            SpendDay(date: day(-1), provider: .claude, source: source, model: "claude-opus-5", total: total(output: 1000)),
            SpendDay(date: day(-100), provider: .claude, source: source, model: "claude-haiku-4-5", total: total(output: 4000)),
            SpendDay(date: day(0), provider: .claude, source: source, model: "<synthetic>", total: total(events: 1)),
        ], calendar: calendar)

        let month = history.footprint(.days30, now: now, calendar: calendar)
        XCTAssertEqual(month.energyWh.mid, 4.5, accuracy: 1e-9)
        XCTAssertEqual(month.requests, 5)
        XCTAssertEqual(history.footprint(.year, now: now, calendar: calendar).energyWh.mid, 5.5, accuracy: 1e-9)

        let daily = history.footprintBuckets(.days30, now: now, calendar: calendar)
        XCTAssertEqual(daily.map(\.footprint.energyWh.mid), [2.0, 2.5])
        let monthly = history.footprintBuckets(.all, now: now, calendar: calendar)
        XCTAssertEqual(monthly.count, 2)
        XCTAssertTrue(monthly.allSatisfy { calendar.component(.day, from: $0.start) == 1 })

        let models = history.footprintModels(.year, now: now, calendar: calendar)
        XCTAssertEqual(models.map(\.model), ["claude-opus-5", "claude-haiku-4-5", "gpt-5-codex"])
        XCTAssertEqual(models.map(\.modelClass), [.large, .small, .standard])
        XCTAssertEqual(models[0].footprint.requests, 3)
        XCTAssertEqual(history.footprintModels(.year, limit: 1, now: now, calendar: calendar).count, 1)
    }
}
