import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenQuotaCore

final class CursorProviderTests: XCTestCase {
    private var home: URL!
    private var credentials: FileCredentialStore!
    private var http: RecordingHTTP!
    private var provider: CursorProvider!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        credentials = FileCredentialStore(directory: home.appendingPathComponent("secrets"))
        http = RecordingHTTP()
        provider = CursorProvider(
            http: http, credentials: credentials, manifestURL: home.appendingPathComponent("keys.json"))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: home.path) {
            try FileManager.default.removeItem(at: home)
        }
    }

    private func add(_ token: String = "alice::dummy-token") async throws -> AccountDescriptor {
        let identity = try provider.addSessionToken(token, label: "Personal")
        let accounts = try await provider.accounts()
        return try XCTUnwrap(accounts.first { $0.id == identity.id })
    }

    func testMissingSavedTokenNeverUsesLegacyAccount() async throws {
        let account = try await add()
        try credentials.removeSecret(for: "cursor/\(account.id)")
        try credentials.setSecret("bob::legacy-token", for: "cursor/session")
        do {
            _ = try await provider.refresh(account: account)
            XCTFail("A missing token must not fetch another account")
        } catch {
            XCTAssertEqual(error as? ProviderError, .notLoggedIn)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testRotatingTokenPreservesAccountAndLabelAndDeduplicates() async throws {
        let account = try await add()
        let storage = GenericProvider(
            spec: ProviderSpec(id: "cursor", displayName: "Cursor", url: "https://cursor.com"),
            http: http, credentials: credentials, manifestURL: home.appendingPathComponent("keys.json"))
        let duplicate = try storage.addKey("alice::old-token", label: "Duplicate")
        let other = try provider.addSessionToken("bob::other-token", label: "Work")
        try credentials.setSecret("alice::legacy-token", for: "cursor/session")
        let replaced = try provider.addSessionToken("alice%3A%3Anew-token")
        XCTAssertEqual(replaced.id, account.id)
        XCTAssertEqual(replaced.label, "Personal")
        let accounts = try await provider.accounts()
        XCTAssertEqual(Set(accounts.map(\.id)), [account.id, other.id])
        XCTAssertEqual(try credentials.secret(for: "cursor/\(account.id)"), "alice::new-token")
        XCTAssertNil(try credentials.secret(for: "cursor/\(duplicate.id)"))
        XCTAssertNil(try credentials.secret(for: "cursor/session"))
        let manifest = try String(contentsOf: home.appendingPathComponent("keys.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("new-token"))
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testLegacyAccountIsUsedOnlyForMatchingIdentity() async throws {
        try credentials.setSecret("alice::legacy-token", for: "cursor/session")
        let accounts = try await provider.accounts()
        let account = try XCTUnwrap(accounts.first)
        http.stub("usage-summary", body: #"{"individualUsage":{"plan":{"totalPercentUsed":25}}}"#)
        let snapshot = try await provider.refresh(account: account)
        XCTAssertEqual(snapshot.account.id, account.id)
        XCTAssertEqual(http.requests.first?.headers["Cookie"], "WorkosCursorSessionToken=alice%3A%3Alegacy-token")
        let invented = AccountDescriptor(
            account: AccountIdentity(providerID: "cursor", id: "cursor@unknown"), source: .userSuppliedKey)
        do {
            _ = try await provider.refresh(account: invented)
            XCTFail("Unregistered account must fail")
        } catch { XCTAssertEqual(error as? ProviderError, .notLoggedIn) }
        XCTAssertEqual(http.requests.count, 1)
    }

    func testDashboardPoolsAndSpendAreSeparateAndNotDoubleCounted() async throws {
        let account = try await add()
        http.stub("usage-summary", body: """
            {"membershipType":"pro","billingCycleEnd":"2027-02-01T00:00:00Z",
             "individualUsage":{"plan":{"totalPercentUsed":60,"autoPercentUsed":20,"apiPercentUsed":80},
                                "onDemand":{"enabled":true,"used":325,"limit":5000}},
             "teamUsage":{"onDemand":{"used":999999}}}
            """)
        let snapshot = try await provider.refresh(account: account)
        XCTAssertEqual(snapshot.account.plan, "pro")
        XCTAssertEqual(snapshot.windows.map(\.label), ["Cursor Models", "Other Models", "On-demand spend"])
        XCTAssertEqual(snapshot.windows[0].percentRemaining, 80)
        XCTAssertEqual(snapshot.windows[1].used, 80)
        XCTAssertEqual(snapshot.windows[2].used, 3.25)
        XCTAssertNil(snapshot.windows[2].limit)
        XCTAssertNil(snapshot.windows[2].fractionUsed)
        XCTAssertNotNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertFalse(http.requests[0].allowsRedirects)
    }

    func testDashboardFailureFallsBackUsingSameToken() async throws {
        let account = try await add()
        for (status, body) in [(401, "{}"), (500, "{}"), (200, "<html>Login</html>"), (200, "{}")] {
            http.responses = []
            http.requests = []
            http.stub("usage-summary", status: status, body: body)
            http.stub("GetCurrentPeriodUsage", body: #"{"planUsage":{"totalSpend":500,"limit":2000}}"#)
            let snapshot = try await provider.refresh(account: account)
            XCTAssertEqual(snapshot.windows.first?.used, 5)
            XCTAssertEqual(snapshot.windows.first?.limit, 20)
            XCTAssertEqual(http.requests[1].headers["Authorization"], "Bearer dummy-token")
            XCTAssertTrue(http.requests.allSatisfy { !$0.allowsRedirects })
            XCTAssertTrue(http.requests.allSatisfy { !$0.url.absoluteString.contains("dummy-token") })
        }
    }

    func testRateLimitAndRedirectDoNotTriggerFallback() async throws {
        let account = try await add()
        for status in [429, 302] {
            http.responses = []
            http.requests = []
            http.stub("usage-summary", status: status, body: "{}", headers: ["Retry-After": "120"])
            do {
                _ = try await provider.refresh(account: account)
                XCTFail("Must not bypass rate limits or redirects")
            } catch {
                let expected: ProviderError = status == 429 ? .rateLimited(retryAfter: 120) : .serverError(302)
                XCTAssertEqual(error as? ProviderError, expected)
            }
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testMalformedTokensAndExpiryDoNotOverwriteSavedToken() async throws {
        let account = try await add()
        for token in ["alice::foo; other=bar", "alice::foo\r\nHeader: value",
                      "alice%3A%3Afoo%0A", "alice::", "::token",
                      "alice::" + String(repeating: "x", count: 16_385)] {
            XCTAssertThrowsError(try provider.addSessionToken(token))
        }
        let payload = Data(#"{"exp":1}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        XCTAssertThrowsError(try provider.addSessionToken("alice::header.\(payload).signature")) {
            XCTAssertEqual($0 as? ProviderError, .unauthorized)
        }
        XCTAssertEqual(try credentials.secret(for: "cursor/\(account.id)"), "alice::dummy-token")
        try credentials.setSecret("alice::header.\(payload).signature", for: "cursor/\(account.id)")
        do {
            _ = try await provider.refresh(account: account)
            XCTFail("Expired credentials must fail locally")
        } catch { XCTAssertEqual(error as? ProviderError, .unauthorized) }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testInvalidAndDisabledMetricsDoNotBecomeHealthyQuota() async throws {
        let account = try await add()
        for plan in [
            #"{"autoPercentUsed":true,"apiPercentUsed":-1,"totalPercentUsed":"NaN"}"#,
            #"{"enabled":false,"autoPercentUsed":0,"totalPercentUsed":0}"#
        ] {
            http.responses = []
            http.stub("usage-summary", body: """
                {"individualUsage":{"plan":\(plan),"onDemand":{"enabled":false,"used":100}}}
                """)
            do {
                _ = try await provider.refresh(account: account)
                XCTFail("Invalid data must not be represented as zero usage")
            } catch {
                XCTAssertEqual(error as? ProviderError, .badResponse(Localized.text(
                    "Cursor returned no recognized quota data. Check the Cursor dashboard.",
                    "Cursor returnerte ingen gjenkjente kvotedata. Sjekk Cursor-kontrollpanelet.")))
            }
        }
    }

    func testCancellationDoesNotFetchFallback() async throws {
        let account = try await add()
        let cancelling = CancellingCursorHTTP()
        let provider = CursorProvider(
            http: cancelling, credentials: credentials, manifestURL: home.appendingPathComponent("keys.json"))
        do {
            _ = try await provider.refresh(account: account)
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancelling.calls, 1)
    }

    func testRedirectDelegateRejectsCredentialForwarding() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://cursor.com/api/usage-summary")!
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        let completed = expectation(description: "Redirect refused")
        NoRedirectsDelegate().urlSession(
            session, task: task, willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: URL(string: "https://example.com")!)
        ) { request in
            XCTAssertNil(request)
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)
    }
}

private final class CancellingCursorHTTP: HTTPClient, @unchecked Sendable {
    var calls = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        calls += 1
        throw CancellationError()
    }
}
