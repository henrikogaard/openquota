import XCTest
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import OpenQuotaCore

final class MistralProviderTests: XCTestCase {
    private var home: URL!
    private var credentials: FileCredentialStore!
    private var http: RecordingHTTP!
    private var provider: MistralProvider!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        credentials = FileCredentialStore(directory: home.appendingPathComponent("secrets"))
        http = RecordingHTTP()
        provider = MistralProvider(
            http: http, credentials: credentials,
            manifestURL: home.appendingPathComponent("mistral-keys.json"))
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: home.path) {
            try FileManager.default.removeItem(at: home)
        }
    }

    private func add(_ cookie: String = "ory_session_x=fixture; csrftoken=fix") async throws -> AccountDescriptor {
        let identity = try provider.addCookieHeader(cookie, label: "Pro")
        let accounts = try await provider.accounts()
        return try XCTUnwrap(accounts.first { $0.id == identity.id })
    }

    // MARK: - Cookie header validation

    func testCookieHeaderValidation() throws {
        for invalid in [
            "",
            "csrftoken=abc",
            "ory_other=1; csrftoken=abc",
            "ory_session_a=1\r\nEvil: header",
            "ory_session_a=1\nSet-Cookie: x",
            "ory_session_a=1; noequals",
            "ory session_a=1",
            "ory_session_a=" + String(repeating: "x", count: 16_385),
        ] {
            XCTAssertNil(MistralCookieHeader(invalid), "accepted: \(invalid.prefix(20))")
        }
        // A copied request header keeps its field name; only the value is stored.
        let pasted = MistralCookieHeader("Cookie:  ory_session_x=1; csrftoken=abc")
        XCTAssertEqual(pasted?.headerValue, "ory_session_x=1; csrftoken=abc")
        XCTAssertEqual(pasted?.csrfToken, "abc")
        XCTAssertEqual(pasted?.sessionCookie?.name, "ory_session_x")
        XCTAssertEqual(pasted?.pairs.count, 2)
    }

    func testAddDeduplicatesSameSessionAndKeepsAccountsIndependent() async throws {
        let first = try provider.addCookieHeader("ory_session_a=token-one", label: "Pro")
        // Formatting drift does not create a second account for the same session.
        let readded = try provider.addCookieHeader("ory_session_a=token-one;", label: "Renamed")
        XCTAssertEqual(readded.id, first.id)
        XCTAssertEqual(readded.label, "Renamed")
        let other = try provider.addCookieHeader("ory_session_b=token-two", label: "Team")
        XCTAssertNotEqual(other.id, first.id)
        let accounts = try await provider.accounts()
        XCTAssertEqual(Set(accounts.map(\.id)), [first.id, other.id])
        XCTAssertTrue(http.requests.isEmpty, "adding a session must not hit the network")
    }

    func testReplaceRejectsBrokenCookieWithoutMutation() async throws {
        let account = try await add()
        XCTAssertThrowsError(try provider.replaceCookieHeader("csrftoken=only", accountID: account.id))
        XCTAssertThrowsError(try provider.replaceCookieHeader("ory_session_x=2", accountID: "mistral@missing"))
        XCTAssertEqual(
            try credentials.secret(for: "mistral/\(account.id)"),
            "ory_session_x=fixture; csrftoken=fix")
        try provider.removeCookieHeader(accountID: account.id)
        let accounts = try await provider.accounts()
        XCTAssertTrue(accounts.isEmpty)
    }

    // MARK: - Refresh

    func testRefreshMapsBudgetsCreditsAndResetTimes() async throws {
        let account = try await add()
        http.stub("subscription", body: Self.subscriptionHTML(api: [
            "usage_percentage": 36.5, "initial_budget": 25.5,
            "currency": "EUR", "reset_at": "2026-11-01T00:00:00Z",
        ], vibe: [
            "usage_percentage": 58, "initial_budget": 100,
            "currency": "EUR", "reset_at": "$D1790000000000",
        ]))
        http.stub("credits", body: #"{"wallet_amount":10,"credit_notes_amount":2.5,"ongoing_usage_balance":3.3,"currency":"EUR"}"#)
        let snapshot = try await provider.refresh(account: account)

        XCTAssertEqual(snapshot.windows.map(\.label), ["Included", "Vibe"])
        XCTAssertEqual(snapshot.windows[0].used, 36.5)
        XCTAssertEqual(snapshot.windows[0].percentRemaining, 63.5)
        XCTAssertEqual(snapshot.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
        XCTAssertEqual(snapshot.windows[1].used, 58)
        XCTAssertEqual(
            snapshot.windows[1].resetsAt, Date(timeIntervalSince1970: 1_790_000_000),
            "React Flight $D date tags are epoch milliseconds")
        XCTAssertEqual(snapshot.creditsRemaining, 9.2)
        XCTAssertEqual(snapshot.creditsUnit, "EUR")

        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(http.requests[0].headers["Cookie"], "ory_session_x=fixture; csrftoken=fix")
        XCTAssertTrue(http.requests.allSatisfy { !$0.allowsRedirects })
        XCTAssertTrue(http.requests.allSatisfy { $0.method == "GET" })
        // The session never travels in a URL or to another host.
        XCTAssertTrue(http.requests.allSatisfy { !$0.url.absoluteString.contains("fixture") })
        XCTAssertTrue(http.requests.allSatisfy {
            ["admin.mistral.ai", "console.mistral.ai"].contains($0.url.host ?? "")
        })
    }

    func testVibeFallbackUsesCsrfTokenAndMinimalCookies() async throws {
        let account = try await add("ory_session_x=1; csrftoken=fix; other=dropme")
        http.stub("subscription", body: Self.subscriptionHTML(api: [
            "usage_percentage": 30, "initial_budget": 20, "currency": "USD",
        ]))
        http.stub("credits", body: #"{"wallet_amount":0,"currency":"USD"}"#)
        http.stub("vibeUsage", body: #"[{"result":{"data":{"json":{"usage_percentage":42,"reset_at":"2026-11-01T00:00:00Z"}}}}]"#)
        let snapshot = try await provider.refresh(account: account)

        XCTAssertEqual(snapshot.windows.map(\.label), ["Included", "Vibe"])
        XCTAssertEqual(snapshot.windows[1].used, 42)
        let vibeRequest = try XCTUnwrap(
            http.requests.first { $0.url.absoluteString.contains("vibeUsage") })
        XCTAssertEqual(vibeRequest.headers["X-CSRFToken"], "fix")
        XCTAssertEqual(vibeRequest.headers["Cookie"], "ory_session_x=1; csrftoken=fix",
                       "admin cookies beyond the session and csrftoken stay origin-bound")
        XCTAssertEqual(snapshot.creditsRemaining, 0)
    }

    func testNoVibeFallbackWithoutCsrfToken() async throws {
        let account = try await add("ory_session_x=1")
        http.stub("subscription", body: Self.subscriptionHTML(api: [
            "usage_percentage": 30, "initial_budget": 20, "currency": "USD",
        ]))
        http.stub("credits", body: #"{"wallet_amount":0,"currency":"USD"}"#)
        let snapshot = try await provider.refresh(account: account)
        XCTAssertEqual(snapshot.windows.map(\.label), ["Included"])
        XCTAssertFalse(http.requests.contains { $0.url.absoluteString.contains("vibeUsage") })
    }

    func testDeadSessionIsUnauthorizedAndStopsEarly() async throws {
        let account = try await add()
        // Mistral answers a dead web session with a redirect to the Ory login flow.
        for status in [302, 401, 403] {
            http.responses = []
            http.requests = []
            http.stub("subscription", status: status, body: "",
                      headers: ["Location": "https://auth.mistral.ai/login"])
            do {
                _ = try await provider.refresh(account: account)
                XCTFail("A dead session must surface as unauthorized (status \(status))")
            } catch {
                XCTAssertEqual(error as? ProviderError, .unauthorized)
            }
            XCTAssertEqual(http.requests.count, 1, "no further sources after a dead session")
        }
    }

    func testRateLimitPropagatesWithRetryAfter() async throws {
        let account = try await add()
        http.stub("subscription", status: 429, body: "", headers: ["Retry-After": "120"])
        do {
            _ = try await provider.refresh(account: account)
            XCTFail("Rate limits must not be bypassed")
        } catch {
            XCTAssertEqual(error as? ProviderError, .rateLimited(retryAfter: 120))
        }
    }

    func testCreditsOnlySnapshotNeverInventsPercentageWindows() async throws {
        let account = try await add()
        http.stub("subscription", body: "<!DOCTYPE html><title>Mistral</title>")
        http.stub("credits", body: #"{"wallet_amount":12,"credit_notes_amount":0,"ongoing_usage_balance":0,"currency":"USD"}"#)
        let snapshot = try await provider.refresh(account: account)
        XCTAssertTrue(snapshot.windows.isEmpty, "a balance is not an allowance")
        XCTAssertNil(snapshot.lowestPercentRemaining)
        XCTAssertEqual(snapshot.creditsRemaining, 12)
        XCTAssertEqual(snapshot.creditsUnit, "USD")
    }

    func testNoDataAtAllSurfacesFirstSourceError() async throws {
        let account = try await add()
        http.stub("subscription", status: 500, body: "")
        http.stub("credits", status: 503, body: "")
        do {
            _ = try await provider.refresh(account: account)
            XCTFail("All sources failing must surface the first error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .serverError(500))
        }
    }

    func testEmptyButSuccessfulResponsesAreReportedHonestly() async throws {
        let account = try await add()
        http.stub("subscription", body: "<!DOCTYPE html><title>Mistral</title>")
        http.stub("credits", body: "{}")
        do {
            _ = try await provider.refresh(account: account)
            XCTFail("No allowance and no balance must fail, not show zero")
        } catch {
            XCTAssertEqual(error as? ProviderError, .badResponse(Localized.text(
                "Mistral reported no subscription allowance or credit balance for this session.",
                "Mistral rapporterte ingen abonnementskvote eller kredittsaldo for denne økten.")))
        }
    }

    func testAmbiguousBudgetsFallBackToCredits() async throws {
        let account = try await add()
        // Two different budget objects under one name are not a reading.
        http.stub("subscription", body: Self.subscriptionHTML(
            api: ["usage_percentage": 36.5, "initial_budget": 25.5, "currency": "EUR"],
            vibe: nil,
            second: ["api_budget": ["usage_percentage": 80, "initial_budget": 25.5, "currency": "EUR"]]))
        http.stub("credits", body: #"{"wallet_amount":12,"currency":"USD"}"#)
        let snapshot = try await provider.refresh(account: account)
        XCTAssertTrue(snapshot.windows.isEmpty, "ambiguous budgets must not become quota")
        XCTAssertEqual(snapshot.creditsRemaining, 12)
    }

    func testMissingStoredSessionFailsWithoutNetwork() async throws {
        let identity = try provider.addCookieHeader("ory_session_x=fixture; csrftoken=fix", label: "Pro")
        try credentials.removeSecret(for: "mistral/\(identity.id)")
        let account = AccountDescriptor(account: identity, source: .userSuppliedKey)
        do {
            _ = try await provider.refresh(account: account)
            XCTFail("A missing secret must fail locally")
        } catch {
            XCTAssertEqual(error as? ProviderError, .notLoggedIn)
        }
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testCancellationPropagates() async throws {
        let cancelling = CancellingMistralHTTP()
        let provider = MistralProvider(
            http: cancelling, credentials: credentials,
            manifestURL: home.appendingPathComponent("mistral-keys.json"))
        let account = try await add()
        do {
            _ = try await provider.refresh(account: account)
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(cancelling.calls, 1)
    }

    // MARK: - RSC parser

    func testParserSkipsLengthDelimitedRows() throws {
        // The T row's payload is `{"x":12}` (8 bytes) plus its newline (1 byte),
        // so the byte count must land the cursor exactly on the next record.
        let chunk = "a1:I[\"react\"]\n"
            + "f1:T9,{\"x\":12}\n"
            + "b2:" + Self.rowJSON(["budget": ["api_budget": [
                "usage_percentage": 10, "initial_budget": 5, "currency": "usd",
            ]]])
        let budgets = try MistralSubscriptionParser.parse(html: Self.flightHTML(chunk))
        XCTAssertEqual(budgets.api?.usedPercentage, 10)
        XCTAssertEqual(budgets.api?.currencyCode, "USD")
        XCTAssertNil(budgets.api?.resetsAt)
        XCTAssertNil(budgets.vibe)
    }

    func testParserOmitsInvalidBudgetsAndKeepsValidSibling() throws {
        let chunk = "a1:" + Self.rowJSON(["budget": [
            "api_budget": ["usage_percentage": -5, "initial_budget": 0, "currency": ""],
            "vibe_budget": ["usage_percentage": 90, "initial_budget": 40,
                            "currency": "EUR", "reset_at": 1_790_000_000],
        ]])
        let budgets = try MistralSubscriptionParser.parse(html: Self.flightHTML(chunk))
        XCTAssertNil(budgets.api, "malformed allowance must be omitted")
        XCTAssertEqual(budgets.vibe?.usedPercentage, 90)
        XCTAssertEqual(budgets.vibe?.resetsAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testParserRejectsPlainAndEmptyHTML() {
        for html in ["", "<!DOCTYPE html><title>hi</title>", #"self.__next_f.push([1,"a1:[\"$\"]"])"#] {
            XCTAssertThrowsError(try MistralSubscriptionParser.parse(html: html))
        }
    }

    // MARK: - Fixtures

    /// A subscription page: one `self.__next_f.push([1, "<chunk>"])` carrying
    /// budget model rows. JSONSerialization builds the push payload so the
    /// chunk's escaping is exactly what a browser would receive.
    private static func flightHTML(_ chunk: String) -> String {
        let payload = (try? JSONSerialization.data(withJSONObject: [1, chunk]))
            ?? Data("[]".utf8)
        return "<script>self.__next_f.push(" + String(decoding: payload, as: UTF8.self) + ")</script>"
    }

    private static func rowJSON(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static func subscriptionHTML(
        api: [String: Any]?, vibe: [String: Any]? = nil, second: [String: Any]? = nil
    ) -> String {
        var rows: [String] = []
        var budget: [String: Any] = [:]
        if let api { budget["api_budget"] = api }
        if let vibe { budget["vibe_budget"] = vibe }
        if !budget.isEmpty { rows.append("a1:" + rowJSON(["budget": budget])) }
        if let second { rows.append("a2:" + rowJSON(["budget": second])) }
        return flightHTML(rows.joined(separator: "\n"))
    }
}

private final class CancellingMistralHTTP: HTTPClient, @unchecked Sendable {
    var calls = 0
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        calls += 1
        throw CancellationError()
    }
}
