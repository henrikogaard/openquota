import XCTest
@testable import OpenQuotaCore

final class MenuBarReadingTests: XCTestCase {
    private func snapshot(_ id: String, windows: [UsageWindow], stale: Bool = false) -> UsageSnapshot {
        UsageSnapshot(
            account: AccountIdentity(providerID: "test", id: id),
            providerID: "test", windows: windows, isStale: stale)
    }

    private let weekly = UsageWindow(id: "week", label: "Week", used: 87, limit: 100)
    private let session = UsageWindow(id: "session", label: "5h", used: 20, limit: 100)

    func test_automaticSelectsLowestWindowAndPreservesSource() throws {
        let snapshots = [
            snapshot("codex", windows: [session, weekly], stale: true),
            snapshot("devin", windows: [.init(id: "week", label: "Week", used: 62, limit: 100)])
        ]
        let reading = try XCTUnwrap(MenuBarReading.select(from: snapshots))
        XCTAssertEqual(reading.snapshot.account.id, "codex")
        XCTAssertEqual(reading.window.id, "week")
        XCTAssertEqual(reading.percentRemaining, 13, accuracy: 0.001)
        XCTAssertTrue(reading.snapshot.isStale)
    }

    func test_pinsAccountOrSpecificWindowWithoutFallingBack() throws {
        let snapshots = [
            snapshot("one", windows: [session, weekly]),
            snapshot("two", windows: [session])
        ]
        XCTAssertEqual(MenuBarReading.select(from: snapshots, accountID: "two")?.window.id, "session")
        let pinned = try XCTUnwrap(MenuBarReading.select(from: snapshots, accountID: "one", windowID: "session"))
        XCTAssertEqual(pinned.percentRemaining, 80, accuracy: 0.001)
        XCTAssertNil(MenuBarReading.select(from: snapshots, accountID: "deleted"))
        XCTAssertNil(MenuBarReading.select(from: snapshots, accountID: "one", windowID: "missing"))
    }

    func test_unknownBalancesAndInvalidNumbersDoNotBecomePercentages() {
        let snapshots = [snapshot("one", windows: [
            .init(id: "balance", label: "Balance", kind: .credits, remaining: 62, unit: "USD"),
            .init(id: "invalid", label: "Invalid", used: .infinity, limit: 100),
            .init(id: "nan", label: "Invalid", used: .nan, limit: 100),
            .init(id: "zero", label: "Invalid", used: 5, limit: 0)
        ])]
        XCTAssertNil(MenuBarReading.select(from: snapshots))
        XCTAssertNil(MenuBarReading.select(from: []))
    }

    func test_tiesAreStableAndAutomaticIgnoresOldPinnedWindow() {
        let one = snapshot("a", windows: [session])
        let two = snapshot("b", windows: [session])
        XCTAssertEqual(MenuBarReading.select(from: [two, one], windowID: "old")?.snapshot.account.id, "a")
        XCTAssertEqual(MenuBarReading.select(from: [one, two])?.snapshot.account.id, "a")
    }

    func test_legacyIconPreferenceAndNewStyles() {
        XCTAssertEqual(MenuBarDisplayStyle.resolve("", legacyShowsPercent: false), .iconOnly)
        XCTAssertEqual(MenuBarDisplayStyle.resolve("", legacyShowsPercent: true), .iconAndPercentage)
        for style in MenuBarDisplayStyle.allCases {
            XCTAssertEqual(MenuBarDisplayStyle.resolve(style.rawValue, legacyShowsPercent: false), style)
        }
    }
}
