import Foundation
import XCTest
@testable import OpenQuotaCore

final class OpenRouterReadingsTests: XCTestCase {
    private func refresh(_ credits: String = "{}", status: Int = 200,
                         key: String = "{}", keyStatus: Int = 200) async throws -> UsageSnapshot {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = RecordingHTTP()
        http.stub("/credits", status: status, body: credits)
        http.stub("/key", status: keyStatus, body: key)
        let provider = GenericProvider(spec: BuiltinProviders.openRouter, http: http,
                                      credentials: FileCredentialStore(directory: directory),
                                      manifestURL: directory.appendingPathComponent("keys.json"))
        _ = try provider.addKey("fixture-key", label: nil)
        let accounts = try await provider.accounts()
        return try await provider.refresh(account: accounts[0])
    }

    func testBalancePermissionFailureStillShowsRegularKeyUsage() async throws {
        let reading = try await refresh(status: 403, key: #"{"data":{"usage":3,"limit":10}}"#)
        XCTAssertNil(reading.creditsRemaining)
        XCTAssertEqual(reading.windows.first?.used, 3)
    }

    func testKeyFailureStillShowsAccountBalance() async throws {
        let reading = try await refresh(#"{"data":{"total_credits":50,"total_usage":12.5}}"#,
                                        keyStatus: 401)
        XCTAssertEqual(reading.creditsRemaining, 37.5)
        XCTAssertTrue(reading.windows.isEmpty)
    }
    func testPeriodsAndResetAllowanceAreIndependentOfLifetimeSpend() async throws {
        let reading = try await refresh(status: 403, key: #"{"data":{"usage":103,"limit":10,"limit_remaining":7,"limit_reset":"monthly","usage_daily":0,"usage_monthly":3}}"#)
        XCTAssertEqual(reading.openRouter?.balanceIssue, .managementKeyRequired)
        XCTAssertEqual(reading.openRouter?.totalSpend, 103)
        XCTAssertEqual(reading.openRouter?.dailySpend, 0)
        XCTAssertEqual(reading.openRouter?.monthlySpend, 3)
        XCTAssertEqual(reading.windows[0].used, 3)
        XCTAssertEqual(reading.windows[0].remaining, 7)
        XCTAssertEqual(reading.windows[0].percentRemaining, 70)
    }

    func testResetWithoutReportedRemainingDoesNotInventAllowance() async throws {
        let reading = try await refresh(status: 403, key: #"{"data":{"usage":103,"limit":10,"limit_reset":"monthly"}}"#)
        XCTAssertNil(reading.windows[0].remaining)
        XCTAssertNil(reading.windows[0].percentRemaining)
        XCTAssertNil(reading.openRouter?.dailySpend)
        XCTAssertNil(reading.openRouter?.monthlySpend)
    }

    func testUnlimitedAndZeroLimitKeys() async throws {
        let unlimited = try await refresh(status: 403, key: #"{"data":{"usage":0,"limit":null,"limit_remaining":null}}"#)
        XCTAssertEqual(unlimited.openRouter?.totalSpend, 0)
        XCTAssertNil(unlimited.windows[0].remaining)
        XCTAssertNil(unlimited.windows[0].percentRemaining)
        let zero = try await refresh(status: 403, key: #"{"data":{"usage":0,"limit":0,"limit_remaining":0}}"#)
        XCTAssertEqual(zero.windows[0].remaining, 0)
        XCTAssertEqual(zero.windows[0].limit, 0)
    }

    func testBothRejectedThrowsAndMalformedBalanceDoesNotInventZero() async throws {
        do {
            _ = try await refresh(status: 401, keyStatus: 401)
            XCTFail("Both failures must use stale/error handling")
        } catch let error as ProviderError { XCTAssertEqual(error, .unauthorized) }
        let malformed = try await refresh(#"{"data":{"total_credits":50}}"#,
                                          key: #"{"data":{"usage":1}}"#)
        XCTAssertNil(malformed.creditsRemaining)
        XCTAssertEqual(malformed.openRouter?.balanceIssue, .unavailable)
        let badKey = try await refresh(#"{"data":{"total_credits":0,"total_usage":0}}"#,
                                      key: #"{"data":{"usage":"NaN"}}"#)
        XCTAssertEqual(badKey.creditsRemaining, 0)
        XCTAssertTrue(badKey.windows.isEmpty)
        XCTAssertEqual(badKey.openRouter?.keyIssue, .unavailable)
    }

    func testPartialReadReplacesOldBalanceAndRoundTripsWithIssues() async throws {
        let store = SnapshotStore()
        let full = try await refresh(#"{"data":{"total_credits":50,"total_usage":10}}"#,
                                     key: #"{"data":{"usage":1}}"#)
        await store.finishRefresh(accountID: full.account.id, result: .success(full))
        var partial = try await refresh(status: 403, key: #"{"data":{"usage":2,"usage_daily":0}}"#)
        partial.account = full.account
        await store.finishRefresh(accountID: full.account.id, result: .success(partial))
        let saved = await store.snapshot(for: full.account.id)
        XCTAssertNil(saved?.creditsRemaining)
        XCTAssertEqual(saved?.windows.first?.used, 2)
        XCTAssertFalse(saved?.isStale ?? true)
        let data = try JSONEncoder().encode(partial)
        XCTAssertEqual(try JSONDecoder().decode(UsageSnapshot.self, from: data), partial)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "openRouter")
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.openRouter)
        await store.finishRefresh(accountID: full.account.id, result: .failure(.unauthorized))
        let stale = await store.snapshot(for: full.account.id)
        XCTAssertTrue(stale?.isStale ?? false)
        XCTAssertEqual(stale?.windows.first?.used, 2)
    }

    func testPartialRateLimitPreservesReadingAndSchedulerHonorsRetryAfter() async throws {
        let http = RecordingHTTP()
        http.stub("/credits", status: 429, body: "private response", headers: ["Retry-After": "60"])
        http.stub("/key", body: #"{"data":{"usage":3}}"#)
        let account = AccountDescriptor(account: .init(providerID: "openrouter", id: "fixture"), source: .userSuppliedKey)
        let reading = try await OpenRouterReadings.refresh(http: http, headers: ["Authorization": "Bearer fixture"], account: account)
        XCTAssertEqual(reading.openRouter?.retryAfter, 60)
        XCTAssertEqual(reading.openRouter?.balanceIssue, .rateLimited)
        XCTAssertTrue(http.requests.allSatisfy { !$0.allowsRedirects && $0.method == "GET" && $0.headers["Authorization"] == "Bearer fixture" })
        let provider = PartialOpenRouterProvider(reading: reading)
        let scheduler = RefreshScheduler(providers: [provider], store: SnapshotStore())
        await scheduler.refresh(provider: provider, account: account)
        await scheduler.refresh(provider: provider, account: account)
        let calls = await provider.count()
        XCTAssertEqual(calls, 1)
    }

    func testTimeoutAndCancellationDoNotEraseSuccessfulIndependentReadings() async throws {
        let account = AccountDescriptor(account: .init(providerID: "openrouter", id: "fixture"), source: .userSuppliedKey)
        let reading = try await OpenRouterReadings.refresh(http: InterruptedOpenRouterHTTP(cancel: false), headers: [:], account: account)
        XCTAssertEqual(reading.windows.first?.used, 2)
        XCTAssertEqual(reading.openRouter?.balanceIssue, .unavailable)
        do {
            _ = try await OpenRouterReadings.refresh(http: InterruptedOpenRouterHTTP(cancel: true), headers: [:], account: account)
            XCTFail("Cancellation must propagate")
        } catch is CancellationError { }
    }

    func testLowBalanceBoundariesAndAccountPreferenceIsolation() throws {
        XCTAssertFalse(OpenRouterDetails.isLowBalance(nil, threshold: 5))
        XCTAssertFalse(OpenRouterDetails.isLowBalance(5, threshold: 5))
        XCTAssertTrue(OpenRouterDetails.isLowBalance(4.99, threshold: 5))
        XCTAssertTrue(OpenRouterDetails.isLowBalance(-1, threshold: 5))
        XCTAssertFalse(OpenRouterDetails.isLowBalance(-1, threshold: 0))
        XCTAssertFalse(OpenRouterDetails.isLowBalance(.nan, threshold: 5))
        XCTAssertEqual(OpenRouterDetails.warningThreshold(.nan), 5)
        XCTAssertEqual(OpenRouterDetails.warningThreshold(-1), 5)
        XCTAssertEqual(OpenRouterDetails.warningThreshold(1001), 5)
        let suiteName = "OpenRouterTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let first = OpenRouterDetails.warningPreferenceKey(accountID: "one")
        let second = OpenRouterDetails.warningPreferenceKey(accountID: "two")
        defaults.register(defaults: [first: 5.0, second: 5.0])
        defaults.set(12.0, forKey: first)
        XCTAssertEqual(defaults.double(forKey: second), 5)
        XCTAssertEqual(UserDefaults(suiteName: suiteName)?.double(forKey: first), 12)
    }

    func testCustomOpenRouterSpecKeepsGenericMapping() async throws {
        let custom = ProviderSpec(id: "openrouter", displayName: "Custom",
                                  url: BuiltinProviders.openRouter.url,
                                  windows: [.init(label: "Custom", used: "$.custom")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let http = RecordingHTTP()
        http.defaultBody = #"{"custom":9}"#
        let provider = GenericProvider(spec: custom, http: http,
                                      credentials: FileCredentialStore(directory: directory),
                                      manifestURL: directory.appendingPathComponent("keys.json"))
        _ = try provider.addKey("fixture-key", label: nil)
        let accounts = try await provider.accounts()
        let reading = try await provider.refresh(account: accounts[0])
        XCTAssertEqual(reading.windows.first?.label, "Custom")
        XCTAssertEqual(reading.windows.first?.used, 9)
        XCTAssertNil(reading.openRouter)
        XCTAssertEqual(http.requests.count, 1)
    }

}


private actor PartialOpenRouterProvider: UsageProvider {
    nonisolated let id = "openrouter"
    nonisolated let displayName = "OpenRouter"
    nonisolated let dashboardURL: URL? = nil
    private let reading: UsageSnapshot
    private var calls = 0
    init(reading: UsageSnapshot) { self.reading = reading }
    func accounts() async throws -> [AccountDescriptor] { [] }
    func refresh(account: AccountDescriptor) async throws -> UsageSnapshot { calls += 1; return reading }
    func count() -> Int { calls }
}

private struct InterruptedOpenRouterHTTP: HTTPClient {
    var cancel: Bool
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url.path.hasSuffix("credits") {
            if cancel { throw CancellationError() }
            throw ProviderError.timedOut
        }
        return HTTPResponse(status: 200, headers: [:], body: Data(#"{"data":{"usage":2}}"#.utf8))
    }
}
