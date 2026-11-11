import Foundation
import XCTest
@testable import OpenQuotaCore

/// Answers each URL part from its own queue; the last answer repeats.
private final class ScriptedHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var queues: [(match: String, responses: [HTTPResponse])] = []
    private var sent: [HTTPRequest] = []

    var requests: [HTTPRequest] { lock.withLock { sent } }

    func queue(_ match: String, _ answers: (Int, String)...) {
        let responses = answers.map { HTTPResponse(status: $0.0, headers: [:], body: Data($0.1.utf8)) }
        lock.withLock {
            queues.removeAll { $0.match == match }
            queues.append((match, responses))
        }
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock {
            sent.append(request)
            guard let index = queues.firstIndex(where: { request.url.absoluteString.contains($0.match) }) else {
                return HTTPResponse(status: 404, headers: [:], body: Data("{}".utf8))
            }
            let response = queues[index].responses[0]
            if queues[index].responses.count > 1 { queues[index].responses.removeFirst() }
            return response
        }
    }

    func count(_ match: String) -> Int { requests.filter { $0.url.absoluteString.contains(match) }.count }
    func last(_ match: String) -> HTTPRequest? { requests.last { $0.url.absoluteString.contains(match) } }
}

final class OpenCodeConsoleProviderTests: XCTestCase {
    private let token = #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3600,"org_id":null}"#
    private let goUsage = """
        {"usage":{"rolling":{"status":"ok","percent":25,"resetsAt":"2030-01-01T05:00:00.000Z"},
                  "weekly":{"status":"ok","percent":60,"resetsAt":"2030-01-05T00:00:00.000Z"},
                  "monthly":{"status":"rate-limited","percent":100,"resetsAt":"2030-02-01T00:00:00.000Z"}}}
        """
    private let budgets = """
        [{"ruleID":"rule_a","limitDollars":50,"spentDollars":12.5,"scope":"member","per":"month","coverage":"all",
          "models":[],"vendors":[],"picked":false,"shared":false,"resetsAt":"2030-02-01T00:00:00.000Z"}]
        """

    private func make() -> (OpenCodeConsoleProvider, ScriptedHTTP, FileCredentialStore) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let http = ScriptedHTTP()
        let store = FileCredentialStore(directory: dir)
        let provider = OpenCodeConsoleProvider(
            http: http, credentials: store, manifestURL: dir.appendingPathComponent("keys.json"))
        http.queue("/auth/device/code", (200, """
            {"device_code":"device-1","user_code":"ABCD-1234","verification_uri_complete":"/console/device?code=ABCD-1234",
             "expires_in":600,"interval":5}
            """))
        http.queue("/api/user", (200, #"{"id":"usr_1","email":"person@example.com"}"#))
        http.queue("/api/orgs", (200, #"[{"id":"wrk_b","name":"Work"},{"id":"wrk_a","name":"Personal"}]"#))
        http.queue("/zen/go/v1/usage", (200, goUsage))
        http.queue("/api/policies/current-budgets", (200, budgets))
        return (provider, http, store)
    }

    private func signIn(_ provider: OpenCodeConsoleProvider, _ http: ScriptedHTTP, token: String? = nil) async throws -> [AccountIdentity] {
        http.queue("/auth/device/token", (200, token ?? self.token))
        return try await provider.completeSignIn(try await provider.beginSignIn(), sleep: { _ in })
    }

    private func body(_ request: HTTPRequest?) -> [String: Any] {
        (request?.body).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    func test_beginSignInAsksForACodeAndResolvesThePage() async throws {
        let (provider, http, _) = make()
        let login = try await provider.beginSignIn()
        XCTAssertEqual(login.userCode, "ABCD-1234")
        XCTAssertEqual(login.verificationURL.absoluteString, "https://opencode.ai/console/device?code=ABCD-1234")
        let request = try XCTUnwrap(http.last("/auth/device/code"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://opencode.ai/console/auth/device/code")
        XCTAssertEqual(body(request)["client_id"] as? String, "opencode-cli")
        XCTAssertEqual(body(request)["supports_org_scope"] as? Bool, true)
        XCTAssertEqual(request.headers["User-Agent"], "OpenQuota")
        XCTAssertFalse(request.allowsRedirects)
    }

    func test_beginSignInRefusesAPageOnAnotherHost() async throws {
        for page in ["https://example.com/device", "http://opencode.ai/console/device", "javascript:alert(1)",
                     "https://opencode.ai:8443/device", "https://user@opencode.ai/device"] {
            let (provider, http, _) = make()
            http.queue("/auth/device/code", (200, """
                {"device_code":"d","user_code":"u","verification_uri_complete":"\(page)","expires_in":600,"interval":5}
                """))
            do {
                _ = try await provider.beginSignIn()
                XCTFail("Accepted \(page)")
            } catch {}
        }
    }

    func test_signInWaitsThroughPendingAndSlowDownThenSavesEveryWorkspace() async throws {
        let (provider, http, _) = make()
        http.queue("/auth/device/token",
                   (400, #"{"error":"authorization_pending"}"#), (400, #"{"error":"slow_down"}"#), (200, token))
        let waits = WaitLog()
        let accounts = try await provider.completeSignIn(
            try await provider.beginSignIn(), sleep: { await waits.add($0) })
        let recorded = await waits.values
        XCTAssertEqual(recorded, [5, 5, 10], "slow_down adds five seconds")
        XCTAssertEqual(accounts.map(\.label), ["Personal", "Work"], "Sorted by name")
        XCTAssertEqual(Set(accounts.map(\.email)), ["person@example.com"])
        XCTAssertEqual(body(http.last("/auth/device/token"))["device_code"] as? String, "device-1")
        XCTAssertEqual(http.last("/api/orgs")?.headers["Authorization"], "Bearer access-1")

        let saved = try await provider.accounts()
        XCTAssertEqual(saved.map(\.account.id), accounts.map(\.id))
        XCTAssertTrue(saved.allSatisfy { $0.account.id.hasSuffix("#wrk_a") || $0.account.id.hasSuffix("#wrk_b") })
    }

    func test_signInFailuresSaveNothing() async throws {
        for (answer, expected) in [
            ((400, #"{"error":"access_denied"}"#), "declined"), ((400, #"{"error":"expired_token"}"#), "timed out"),
            ((400, #"{"error":"invalid_request"}"#), "refused"),
        ] {
            let (provider, http, _) = make()
            http.queue("/auth/device/token", answer)
            do {
                _ = try await provider.completeSignIn(try await provider.beginSignIn(), sleep: { _ in })
                XCTFail("Expected a failure: \(expected)")
            } catch {}
            let saved = try await provider.accounts()
            XCTAssertTrue(saved.isEmpty, expected)
        }
    }

    func test_signInGivesUpWhenTheCodeExpires() async throws {
        let (provider, http, _) = make()
        http.queue("/auth/device/token", (400, #"{"error":"authorization_pending"}"#))
        let start = Date()
        let login = try await provider.beginSignIn(now: start)
        let clock = Clock(start)
        do {
            _ = try await provider.completeSignIn(login, now: { clock.now }, sleep: { clock.advance($0) })
            XCTFail("Expected a timeout")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .timedOut)
        }
        XCTAssertEqual(http.count("/auth/device/token"), 120, "600 seconds at 5-second steps")
    }

    func test_signInKeepsWaitingThroughABusyServer() async throws {
        let (provider, http, _) = make()
        http.queue("/auth/device/token", (503, "busy"), (429, "{}"), (200, token))
        let waits = WaitLog()
        let accounts = try await provider.completeSignIn(
            try await provider.beginSignIn(), sleep: { await waits.add($0) })
        XCTAssertEqual(accounts.count, 2)
        let recorded = await waits.values
        XCTAssertEqual(recorded, [5, 10, 15])
    }

    func test_emptyNameGoesBackToTheWorkspaceNameAndRenameSurvivesARenewal() async throws {
        let (provider, http, _) = make()
        let accounts = try await signIn(
            provider, http, token: #"{"access_token":"a","refresh_token":"refresh-1","expires_in":30}"#)
        try provider.rename(accountID: accounts[0].id, label: "Mine")
        http.queue("/auth/device/token",
                   (200, #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600}"#))
        let snapshot = try await provider.refresh(account: try await provider.accounts()[0])
        XCTAssertEqual(snapshot.account.label, "Mine", "The renewal keeps the name")
        try provider.rename(accountID: accounts[0].id, label: "   ")
        let renamed = try await provider.accounts()
        XCTAssertEqual(renamed[0].account.label, "Personal")
        _ = try await provider.refresh(account: renamed[0])
        XCTAssertEqual(http.last("/zen/go/v1/usage")?.headers["Authorization"], "Bearer access-2",
                       "The rename kept the renewed token")
    }

    func test_unreadableSavedSessionStillHasACardThatCanBeRemoved() async throws {
        let (provider, http, store) = make()
        let accounts = try await signIn(provider, http)
        let entryID = try XCTUnwrap(OpenCodeConsoleProvider.split(accounts[0].id)).entryID
        try store.setSecret("not json", for: "opencode-console/\(entryID)")
        let broken = try await provider.accounts()
        XCTAssertEqual(broken.count, 1)
        do {
            _ = try await provider.refresh(account: broken[0])
            XCTFail("Expected a sign-in error")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .unauthorized)
        }
        try provider.remove(accountID: broken[0].account.id)
        let none = try await provider.accounts()
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(try store.secret(for: "opencode-console/\(entryID)"))
    }

    func test_scopedSignInKeepsOnlyItsWorkspace() async throws {
        let (provider, http, _) = make()
        let scoped = #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":3600,"org_id":"wrk_b"}"#
        let accounts = try await signIn(provider, http, token: scoped)
        XCTAssertEqual(accounts.map(\.label), ["Work"])
    }

    func test_refreshMapsGoLimitsAndBudget() async throws {
        let (provider, http, _) = make()
        _ = try await signIn(provider, http)
        let account = try await provider.accounts()[1]
        let snapshot = try await provider.refresh(account: account)

        XCTAssertEqual(snapshot.account.label, "Work")
        XCTAssertEqual(snapshot.account.plan, "Go")
        let byLabel = Dictionary(uniqueKeysWithValues: snapshot.windows.map { ($0.label, $0) })
        XCTAssertEqual(byLabel["5h"]?.percentRemaining, 75)
        XCTAssertEqual(byLabel["Week"]?.percentRemaining, 40)
        XCTAssertEqual(byLabel["Month"]?.percentRemaining, 0)
        XCTAssertNotNil(byLabel["5h"]?.resetsAt)
        let budget = try XCTUnwrap(byLabel["Budget $50"], "The limit is in the label: the row itself shows a percentage")
        XCTAssertEqual(budget.kind, .credits)
        XCTAssertEqual(budget.used, 12.5)
        XCTAssertEqual(budget.limit, 50)
        XCTAssertEqual(budget.unit, "$")
        XCTAssertNil(snapshot.creditsRemaining, "The prepaid balance is not read")

        let go = try XCTUnwrap(http.last("/zen/go/v1/usage"))
        XCTAssertEqual(go.url.absoluteString, "https://opencode.ai/zen/go/v1/usage")
        XCTAssertEqual(go.headers["Authorization"], "Bearer access-1")
        XCTAssertEqual(go.headers["x-opencode-org-id"], "wrk_b")
        XCTAssertEqual(http.last("/api/policies/current-budgets")?.headers["x-org-id"], "wrk_b")
        XCTAssertTrue(http.requests.allSatisfy { $0.url.host == "opencode.ai" && $0.url.scheme == "https" })
    }

    func test_workspaceWithoutGoShowsBudgetsOnlyAndNothingAtAllIsAnError() async throws {
        let (provider, http, _) = make()
        _ = try await signIn(provider, http)
        let account = try await provider.accounts()[0]
        http.queue("/zen/go/v1/usage", (403, "{}"))
        http.queue("/api/policies/current-budgets", (200, """
            [{"ruleID":"r1","limitDollars":0,"spentDollars":3,"resetsAt":"2030-02-01T00:00:00Z"},
             {"ruleID":"r2","limitDollars":20,"spentDollars":5,"resetsAt":"2030-02-01T00:00:00Z"}]
            """))
        let snapshot = try await provider.refresh(account: account)
        XCTAssertNil(snapshot.account.plan)
        XCTAssertEqual(snapshot.windows.map(\.label), ["Budget", "Budget $20"])
        XCTAssertNil(snapshot.windows[0].limit, "A zero limit is no limit, so no percentage")
        XCTAssertNil(snapshot.windows[0].percentRemaining)
        XCTAssertEqual(snapshot.windows[1].percentRemaining, 75)

        http.queue("/api/policies/current-budgets", (403, "{}"))
        do {
            _ = try await provider.refresh(account: account)
            XCTFail("Nothing to show is an error, not an empty card")
        } catch {}
    }

    func test_expiredSessionRefreshesOnceForConcurrentCardsAndSavesTheRotatedToken() async throws {
        let (provider, http, _) = make()
        let shortLived = #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":30}"#
        _ = try await signIn(provider, http, token: shortLived)
        http.queue("/auth/device/token",
                   (200, #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":3600}"#),
                   (400, #"{"error":"invalid_grant"}"#))
        let accounts = try await provider.accounts()
        async let first = provider.refresh(account: accounts[0])
        async let second = provider.refresh(account: accounts[1])
        _ = try await (first, second)

        let refreshes = http.requests.filter { body($0)["grant_type"] as? String == "refresh_token" }
        XCTAssertEqual(refreshes.count, 1, "The refresh token rotates, so two cards must share one refresh")
        XCTAssertEqual(body(refreshes.first)["refresh_token"] as? String, "refresh-1")
        XCTAssertEqual(http.last("/zen/go/v1/usage")?.headers["Authorization"], "Bearer access-2")

        // The rotated token was saved: the next refresh needs no token call.
        _ = try await provider.refresh(account: accounts[0])
        XCTAssertEqual(http.requests.filter { body($0)["grant_type"] as? String == "refresh_token" }.count, 1)
    }

    func test_rejectedRefreshTokenAsksForANewSignIn() async throws {
        let (provider, http, _) = make()
        _ = try await signIn(provider, http, token: #"{"access_token":"a","refresh_token":"r","expires_in":30}"#)
        http.queue("/auth/device/token", (400, #"{"error":"invalid_grant"}"#))
        let account = try await provider.accounts()[0]
        do {
            _ = try await provider.refresh(account: account)
            XCTFail("Expected unauthorized")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .unauthorized)
        }
        XCTAssertEqual(http.count("/zen/go/v1/usage"), 0, "No usage call with a dead session")
    }

    func test_signingInAgainReplacesTheSessionAndKeepsCardNames() async throws {
        let (provider, http, _) = make()
        let first = try await signIn(provider, http)
        try provider.rename(accountID: first[1].id, label: "Client X")
        let again = try await signIn(
            provider, http, token: #"{"access_token":"access-9","refresh_token":"refresh-9","expires_in":3600}"#)
        XCTAssertEqual(again.map(\.id), first.map(\.id), "Same account: same cards, not duplicates")
        XCTAssertEqual(again.map(\.label), ["Personal", "Client X"])
        _ = try await provider.refresh(account: try await provider.accounts()[0])
        XCTAssertEqual(http.last("/zen/go/v1/usage")?.headers["Authorization"], "Bearer access-9")
    }

    func test_removingWorkspacesRemovesTheSignInWithTheLastOne() async throws {
        let (provider, http, store) = make()
        let accounts = try await signIn(provider, http)
        let entryID = try XCTUnwrap(OpenCodeConsoleProvider.split(accounts[0].id)).entryID
        try provider.remove(accountID: accounts[0].id)
        let left = try await provider.accounts()
        XCTAssertEqual(left.map(\.account.label), ["Work"])
        XCTAssertNotNil(try store.secret(for: "opencode-console/\(entryID)"))
        try provider.remove(accountID: accounts[1].id)
        let none = try await provider.accounts()
        XCTAssertTrue(none.isEmpty)
        XCTAssertNil(try store.secret(for: "opencode-console/\(entryID)"), "The saved session is deleted")
    }
}

private actor WaitLog {
    private(set) var values: [TimeInterval] = []
    func add(_ value: TimeInterval) { values.append(value) }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}
