import Foundation
import XCTest
@testable import OpenQuotaCore

final class AccountReliabilityTests: XCTestCase {
    func testGenericCredentialReplacementPreservesIdentityAndLabel() async throws {
        let (directory, provider, credentials) = try makeGenericProvider()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let original = try provider.addKey("old-key", label: "Work")

        let replaced = try provider.replaceKey("new-key", accountID: original.id)
        let accounts = try await provider.accounts()

        XCTAssertEqual(replaced.id, original.id)
        XCTAssertEqual(replaced.label, "Work")
        XCTAssertEqual(accounts.map(\.account.label), ["Work"])
        XCTAssertEqual(try credentials.secret(for: provider.credentialKey(original.id)), "new-key")
    }

    func testGenericCredentialReplacementWorksWithoutOldSecret() throws {
        let (directory, provider, credentials) = try makeGenericProvider()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let original = try provider.addKey("old-key", label: "Work")
        try credentials.removeSecret(for: provider.credentialKey(original.id))

        let replaced = try provider.replaceKey("new-key", accountID: original.id)

        XCTAssertEqual(replaced.id, original.id)
        XCTAssertEqual(replaced.label, "Work")
        XCTAssertEqual(try credentials.secret(for: provider.credentialKey(original.id)), "new-key")
    }

    func testGenericCredentialReplacementRejectsEmptyAndDuplicateWithoutMutation() throws {
        let (directory, provider, credentials) = try makeGenericProvider()
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let first = try provider.addKey("first-key", label: "Personal")
        let second = try provider.addKey("second-key", label: "Work")

        XCTAssertThrowsError(try provider.replaceKey(" \n ", accountID: first.id))
        XCTAssertThrowsError(try provider.replaceKey("second-key", accountID: first.id))

        XCTAssertEqual(try credentials.secret(for: provider.credentialKey(first.id)), "first-key")
        XCTAssertEqual(try credentials.secret(for: provider.credentialKey(second.id)), "second-key")
        XCTAssertEqual(try provider.configuredKeys().map(\.label), ["Personal", "Work"])
    }

    func testFreshnessRetainsLastSuccessfulReadingAfterFailure() async throws {
        let account = AccountIdentity(providerID: "p", id: "p@one")
        let store = SnapshotStore()
        await store.register(account: account)

        await store.finishRefresh(accountID: account.id, result: .failure(.unauthorized))
        let firstFailureValue = await store.snapshot(for: account.id)
        let firstFailure = try XCTUnwrap(firstFailureValue)
        XCTAssertNil(firstFailure.lastSuccessfulAt)
        let firstAttempt = try XCTUnwrap(firstFailure.lastAttemptedAt)

        try await Task.sleep(for: .milliseconds(20))
        var reading = UsageSnapshot(
            account: account,
            providerID: "p",
            windows: [UsageWindow(id: "p", label: "Usage", used: 4, limit: 10)],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        reading.credentialSource = .configFile
        await store.finishRefresh(accountID: account.id, result: .success(reading))
        let successValue = await store.snapshot(for: account.id)
        let success = try XCTUnwrap(successValue)
        XCTAssertEqual(success.lastSuccessfulAt, success.fetchedAt)
        let successfulAttempt = try XCTUnwrap(success.lastAttemptedAt)
        XCTAssertGreaterThan(successfulAttempt, firstAttempt)

        try await Task.sleep(for: .milliseconds(20))
        await store.finishRefresh(
            accountID: account.id, result: .failure(.network("temporary failure")))
        let staleValue = await store.snapshot(for: account.id)
        let stale = try XCTUnwrap(staleValue)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.windows, success.windows)
        XCTAssertEqual(stale.fetchedAt, success.fetchedAt)
        XCTAssertEqual(stale.lastSuccessfulAt, success.fetchedAt)
        XCTAssertEqual(stale.credentialSource, .configFile)
        XCTAssertGreaterThan(try XCTUnwrap(stale.lastAttemptedAt), successfulAttempt)
    }

    func testSnapshotCacheRoundTripsSourceAndDecodesOlderSnapshotShape() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let cache = SnapshotCache(url: directory.appendingPathComponent("snapshots.json"))
        let account = AccountIdentity(providerID: "p", id: "p@cached", label: "Cached")
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let attemptedAt = Date(timeIntervalSince1970: 1_700_000_010)
        var snapshot = UsageSnapshot(
            account: account,
            providerID: "p",
            windows: [UsageWindow(id: "p", label: "Usage", used: 3, limit: 10)],
            fetchedAt: fetchedAt,
            lastAttemptedAt: attemptedAt,
            credentialSource: .userSuppliedKey)
        snapshot.errorMessage = "A later refresh failed."
        snapshot.isStale = true

        try cache.save([account.id: snapshot])

        let restored = try XCTUnwrap(cache.load()[account.id])
        XCTAssertEqual(restored.lastAttemptedAt, attemptedAt)
        XCTAssertEqual(restored.credentialSource, .userSuppliedKey)
        XCTAssertEqual(restored.lastSuccessfulAt, fetchedAt)

        let legacyURL = directory.appendingPathComponent("legacy.json")
        let legacyCache = SnapshotCache(url: legacyURL)
        let legacyJSON = """
        {"p@legacy":{"account":{"providerID":"p","id":"p@legacy"},
        "providerID":"p","windows":[],"fetchedAt":"2025-01-01T00:00:00Z","isStale":false}}
        """
        try Data(legacyJSON.utf8).write(to: legacyURL)

        let legacy = try XCTUnwrap(legacyCache.load()["p@legacy"])
        XCTAssertNil(legacy.lastAttemptedAt)
        XCTAssertNil(legacy.credentialSource)
        XCTAssertNil(legacy.lastSuccessfulAt)
    }

    private func makeGenericProvider() throws -> (URL, GenericProvider, FileCredentialStore) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let credentials = FileCredentialStore(directory: directory.appendingPathComponent("secrets"))
        let provider = GenericProvider(
            spec: ProviderSpec(
                id: "reliability", displayName: "Reliability", url: "https://example.test/usage"),
            http: ReliabilityTestHTTP(),
            credentials: credentials,
            manifestURL: directory.appendingPathComponent("keys.json"))
        return (directory, provider, credentials)
    }
}

private struct ReliabilityTestHTTP: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: 200, headers: [:], body: Data("{}".utf8))
    }
}
