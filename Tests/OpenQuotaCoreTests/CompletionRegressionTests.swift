import Foundation
import XCTest
@testable import OpenQuotaCore

final class CompletionRegressionTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func provider(_ spec: ProviderSpec, _ http: RecordingHTTP, directory: URL) -> GenericProvider {
        GenericProvider(spec: spec, http: http, credentials: FileCredentialStore(directory: directory),
                        manifestURL: directory.appendingPathComponent("keys.json"))
    }

    func testOpenRouterSubtractsConsumptionAndKeepsKeyLimitIndependent() async throws {
        let http = RecordingHTTP()
        http.stub("/credits", body: #"{"data":{"total_credits":50,"total_usage":12.5}}"#)
        http.stub("/key", body: #"{"data":{"usage":3,"limit":10}}"#)
        let p = provider(BuiltinProviders.openRouter, http, directory: try directory())
        _ = try p.addKey("fixture-key", label: "Work")
        let accounts = try await p.accounts()
        let snapshot = try await p.refresh(account: accounts[0])
        XCTAssertEqual(snapshot.creditsRemaining, 37.5)
        XCTAssertEqual(snapshot.creditsUnit, "USD")
        XCTAssertEqual(snapshot.windows[0].percentRemaining, 70)
    }

    func testRequestyBalanceAndMistralActivityNeverInventQuota() async throws {
        let http = RecordingHTTP()
        http.defaultBody = #"{"name":"Example","balance":12.34}"#
        let p = provider(BuiltinProviders.requesty, http, directory: try directory())
        _ = try p.addKey("fixture-key", label: nil)
        let accounts = try await p.accounts()
        let snapshot = try await p.refresh(account: accounts[0])
        XCTAssertEqual(snapshot.windows[0].remaining, 12.34)
        XCTAssertNil(snapshot.lowestPercentRemaining)

        http.defaultBody = """
        {"sessions":[{"nb_sessions":"12"},{"nb_sessions":"4"}],
         "consumed_tokens":[{"input_tokens":"100","output_tokens":"20"}]}
        """
        let vibe = provider(SpecLibrary.mistral, http, directory: try directory())
        _ = try vibe.addKey("fixture-admin-key", label: nil)
        let vibeAccounts = try await vibe.accounts()
        let activity = try await vibe.refresh(account: vibeAccounts[0])
        XCTAssertEqual(activity.windows.map(\.used), [16, 100, 20])
        XCTAssertNil(activity.lowestPercentRemaining)
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer fixture-admin-key")
        XCTAssertFalse(http.requests.last!.url.absoluteString.contains("{"))
    }

    func testKeysAreIndependentDuplicateSafeRenameableAndRemovable() async throws {
        let p = provider(BuiltinProviders.requesty, RecordingHTTP(), directory: try directory())
        let first = try p.addKey("fixture-A", label: "Home")
        let second = try p.addKey("fixture-B", label: "Work")
        XCTAssertNotEqual(first.id, second.id)
        let duplicate = try p.addKey("fixture-A", label: "Personal")
        XCTAssertEqual(duplicate.id, first.id)
        try p.renameKey(accountID: second.id, label: "Business")
        var accounts = try await p.accounts()
        XCTAssertEqual(accounts.count, 2)
        XCTAssertEqual(accounts.first(where: { $0.id == second.id })?.account.label, "Business")
        try p.removeKey(accountID: first.id)
        accounts = try await p.accounts()
        XCTAssertEqual(accounts.map(\.id), [second.id])
        XCTAssertThrowsError(try p.addKey("   ", label: nil))
    }

    func testNoRecognizedFieldsProducesErrorNotBlankSuccess() async throws {
        let p = provider(BuiltinProviders.requesty, RecordingHTTP(), directory: try directory())
        _ = try p.addKey("fixture", label: nil)
        let accounts = try await p.accounts()
        do {
            _ = try await p.refresh(account: accounts[0])
            XCTFail("Unrecognized payload must fail")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .badResponse("no recognized usage fields"))
        }
    }

    func testClaudePrefersInjectedKeychainAndPersistsRefreshedToken() async throws {
        let home = try directory()
        let credentials = FileCredentialStore(directory: home)
        try credentials.setSecret(
            #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh-fixture","expiresAt":1}}"#,
            for: NSUserName())
        let http = RecordingHTTP()
        http.stub("/oauth/token", body: #"{"access_token":"new","refresh_token":"rotated","expires_in":3600}"#)
        http.stub("/oauth/usage", body: #"{"five_hour":{"utilization":0.5}}"#)
        let p = ClaudeProvider(http: http, files: .init(home: home), nativeCredentials: credentials)
        let accounts = try await p.accounts()
        XCTAssertEqual(accounts.first?.source, .keychainItem)
        let snapshot = try await p.refresh(account: accounts[0])
        XCTAssertEqual(snapshot.windows.first?.percentRemaining, 99.5)
        XCTAssertEqual(http.requests.last?.headers["Authorization"], "Bearer new")
        let raw = try XCTUnwrap(credentials.secret(for: NSUserName()))
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual((saved["claudeAiOauth"] as? [String: Any])?["refreshToken"] as? String, "rotated")
    }

    func testUserSpecOverridesBuiltInWithoutDuplicateID() throws {
        let custom = ProviderSpec(id: "openrouter", displayName: "Custom", url: "https://example.test")
        let registry = ProviderRegistry(http: RecordingHTTP(), credentials: FileCredentialStore(directory: try directory()),
                                        extraSpecs: [custom, custom])
        XCTAssertEqual(registry.providers.filter { $0.id == "openrouter" }.count, 1)
        XCTAssertEqual(registry.providers.first { $0.id == "openrouter" }?.displayName, "Custom")
    }

    func testRetryAfterSecondsAndHTTPDate() {
        XCTAssertEqual(HTTPResponse(status: 429, headers: ["Retry-After": "120"], body: Data()).retryAfter, 120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        let date = formatter.string(from: Date().addingTimeInterval(120))
        let delay = HTTPResponse(status: 429, headers: ["retry-after": date], body: Data()).retryAfter
        XCTAssertNotNil(delay)
        XCTAssertTrue((118...121).contains(delay ?? 0))
    }

    func testMinimalCustomSpecDefaultsAndUnsafeIDs() throws {
        let spec = try JSONDecoder().decode(ProviderSpec.self, from: Data(
            #"{"id":"acme","displayName":"Acme","url":"https://example.test","windows":[{"label":"Month","used":"$.used","limit":"$.limit"}]}"#.utf8))
        XCTAssertEqual(spec.auth, .bearer)
        XCTAssertTrue(spec.unverified)
        XCTAssertEqual(spec.windows.count, 1)
        XCTAssertThrowsError(try JSONDecoder().decode(ProviderSpec.self, from: Data(
            #"{"id":"../../escape","displayName":"Bad","url":"https://example.test"}"#.utf8)))
        XCTAssertNil(JSONPath.double(["value": "nan"], at: "$.value"))
        XCTAssertNil(JSONPath.sum(["value": ["inf"]], at: "$.value"))
    }
}
