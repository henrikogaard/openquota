import XCTest
@testable import OpenQuotaCore

final class AccountIdentityTests: XCTestCase {
    func test_makeID_isStableAndNamespaced() {
        let a = AccountIdentity.makeID(providerID: "claude", identityKey: "user@x.com")
        let b = AccountIdentity.makeID(providerID: "claude", identityKey: "user@x.com")
        let c = AccountIdentity.makeID(providerID: "codex", identityKey: "user@x.com")
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.hasPrefix("claude@"))
        XCTAssertNotEqual(a, c)
        XCTAssertEqual(a.count, "claude@".count + 8)
    }
}

final class UsageWindowTests: XCTestCase {
    func test_fractionUsed_fromUsedAndLimit() {
        let w = UsageWindow(id: "a", label: "5h", used: 30, limit: 100)
        XCTAssertEqual(w.fractionUsed, 0.3)
        XCTAssertEqual(w.percentRemaining, 70)
    }

    func test_fractionUsed_fromRemaining() {
        let w = UsageWindow(id: "a", label: "Credits", limit: 100, remaining: 25)
        XCTAssertEqual(w.fractionUsed, 0.75)
    }

    func test_fractionUsed_clamps() {
        let w = UsageWindow(id: "a", label: "5h", used: 150, limit: 100)
        XCTAssertEqual(w.fractionUsed, 1.0)
        XCTAssertEqual(w.percentRemaining, 0)
    }

    func test_spendWithoutLimitDoesNotInventAQuota() {
        let w = UsageWindow(id: "a", label: "5h", used: 0.42)
        XCTAssertNil(w.fractionUsed)
    }
}

final class JSONPathTests: XCTestCase {
    let root: [String: Any] = [
        "data": [
            "total_credits": 50.0,
            "total_usage": 12.5,
            "list": [["id": "a"], ["id": "b"]]
        ]
    ]

    func test_nestedPath() {
        XCTAssertEqual(JSONPath.double(root, at: "$.data.total_credits"), 50.0)
    }

    func test_arrayIndex() {
        XCTAssertEqual(JSONPath.string(root, at: "$.data.list[1].id"), "b")
    }

    func test_missingPathReturnsNil() {
        XCTAssertNil(JSONPath.double(root, at: "$.data.nope"))
        XCTAssertNil(JSONPath.string(root, at: "$.data.list[9].id"))
    }

    func test_epochDate() {
        let root: [String: Any] = ["resets_at": 1_800_000_000.0]
        XCTAssertNotNil(JSONPath.date(root, at: "$.resets_at"))
    }
}

final class GenericProviderTests: XCTestCase {
    struct StubHTTP: HTTPClient {
        var body: String
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            HTTPResponse(status: 200, headers: [:], body: Data(body.utf8))
        }
    }

    func test_refreshMapsSpec() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        let credentials = FileCredentialStore(directory: dir)
        let spec = ProviderSpec(
            id: "test", displayName: "Test", url: "https://example.test/usage",
            windows: [.init(label: "Month", used: "$.u", limit: "$.l")])
        let provider = GenericProvider(
            spec: spec, http: StubHTTP(body: #"{"u": 40, "l": 100}"#),
            credentials: credentials,
            manifestURL: dir.appendingPathComponent("keys.json"))
        let identity = try provider.addKey("sk-test-123", label: "work")
        let accounts = try await provider.accounts()
        XCTAssertEqual(accounts.count, 1)
        let snapshot = try await provider.refresh(account: accounts[0])
        XCTAssertEqual(snapshot.account.id, identity.id)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].percentRemaining, 60)
    }
}

final class SnapshotCacheTests: XCTestCase {
    func test_roundTrip() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("s.json")
        let cache = SnapshotCache(url: url)
        let snapshot = UsageSnapshot(
            account: AccountIdentity(providerID: "x", id: "x@1"),
            providerID: "x",
            windows: [UsageWindow(id: "w", label: "5h", used: 10, limit: 100)])
        try cache.save(["x@1": snapshot])
        let loaded = cache.load()
        XCTAssertEqual(loaded["x@1"]?.windows.first?.percentRemaining, 90)
    }

    func test_oversizedCacheRefused() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("big.json")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: 300 * 1024).write(to: url)
        XCTAssertTrue(SnapshotCache(url: url).load().isEmpty)
    }
}

final class SnapshotStoreTests: XCTestCase {
    func test_failureKeepsLastGoodSnapshotAndMarksStale() async {
        let store = SnapshotStore()
        let account = AccountIdentity(providerID: "p", id: "p@1")
        let good = UsageSnapshot(account: account, providerID: "p",
                                 windows: [UsageWindow(id: "w", label: "5h", used: 10, limit: 100)])
        await store.finishRefresh(accountID: "p@1", result: .success(good))
        await store.finishRefresh(accountID: "p@1", result: .failure(.timedOut))
        let snapshot = await store.snapshot(for: "p@1")
        XCTAssertEqual(snapshot?.windows.first?.percentRemaining, 90)
        XCTAssertEqual(snapshot?.isStale, true)
        XCTAssertEqual(snapshot?.errorMessage, ProviderError.timedOut.userMessage)
    }
}

final class AwaitingReadingTests: XCTestCase {
    func test_awaitingReadingIsNotAnError() async {
        let store = SnapshotStore()
        let account = AccountIdentity(providerID: "claude", id: "claude@1", label: "Claude")
        await store.register(account: account)
        await store.finishRefresh(accountID: "claude@1", result: .failure(.awaitingReading))
        let snapshot = await store.snapshot(for: "claude@1")
        XCTAssertNotNil(snapshot)
        XCTAssertNil(snapshot?.errorMessage)
        XCTAssertEqual(snapshot?.isStale, false)
    }

    func test_awaitingReadingClearsCachedErrorOnlySnapshot() async {
        let store = SnapshotStore()
        let account = AccountIdentity(providerID: "claude", id: "claude@1", label: "Claude")
        await store.register(account: account)
        await store.finishRefresh(accountID: "claude@1", result: .failure(.badResponse("old")))
        await store.finishRefresh(accountID: "claude@1", result: .failure(.awaitingReading))
        let snapshot = await store.snapshot(for: "claude@1")
        XCTAssertNil(snapshot?.errorMessage)
        XCTAssertEqual(snapshot?.isStale, false)
    }

    func test_diagnosticBadResponsesAreWrappedButSentencesShowAsIs() {
        XCTAssertEqual(ProviderError.badResponse("Codex CLI was not found").userMessage, "Codex CLI was not found")
        XCTAssertTrue(ProviderError.badResponse("billing payload").userMessage.contains("billing payload"))
        XCTAssertFalse(ProviderError.badResponse("billing payload").userMessage.hasPrefix("Bad response"))
    }

    func test_windowLabelsPassThroughInEnglish() {
        if !Localized.norwegian { XCTAssertEqual(Localized.windowLabel("Week"), "Week") }
        XCTAssertEqual(Localized.windowLabels["Week"], "Uke")
    }
}
