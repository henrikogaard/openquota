import Foundation
import XCTest
@testable import OpenQuotaCore

final class RefreshLifecycleTests: XCTestCase {
    func test_refreshAllIsSingleFlightAcrossActorReentrancy() async {
        let account = descriptor("p@one", label: "Primary")
        let probe = RefreshTestProbe(blockDiscovery: true)
        let provider = RefreshTestProvider(id: "p", accounts: [account], probe: probe)
        let scheduler = RefreshScheduler(providers: [provider], store: SnapshotStore())

        let firstPass = Task { await scheduler.refreshAll() }
        await waitForDiscovery(probe, count: 1)
        await scheduler.refreshAll()
        await probe.releaseDiscovery()
        await firstPass.value

        let stats = await probe.stats()
        XCTAssertEqual(stats.discoveries, 1)
        XCTAssertEqual(stats.fetches, 1)
    }

    func test_refreshConcurrencyIsBoundedByConfig() async {
        let accounts = (0..<9).map { descriptor("p@\($0)") }
        let probe = RefreshTestProbe(fetchDelayNanoseconds: 25_000_000)
        let provider = RefreshTestProvider(id: "p", accounts: accounts, probe: probe)
        var config = RefreshScheduler.Config()
        config.maxConcurrentRefreshes = 3
        let scheduler = RefreshScheduler(providers: [provider], store: SnapshotStore(), config: config)

        await scheduler.refreshAll()

        let stats = await probe.stats()
        XCTAssertEqual(stats.fetches, accounts.count)
        XCTAssertEqual(stats.maxActiveFetches, 3)
    }

    func test_forcedAndManualRefreshRespectRetryAfter() async throws {
        let account = descriptor("p@limited")
        let probe = RefreshTestProbe(
            failures: [.rateLimited(retryAfter: 0.2)])
        let provider = RefreshTestProvider(id: "p", accounts: [account], probe: probe)
        let scheduler = RefreshScheduler(providers: [provider], store: SnapshotStore())

        await scheduler.refreshAll()
        await scheduler.refreshAll(force: true)
        await scheduler.refresh(provider: provider, account: account)
        let limitedStats = await probe.stats()
        XCTAssertEqual(limitedStats.fetches, 1)

        try await Task.sleep(for: .milliseconds(250))
        await scheduler.refresh(provider: provider, account: account)
        let retriedStats = await probe.stats()
        XCTAssertEqual(retriedStats.fetches, 2)
    }

    func test_firstFailureUsesRegisteredIdentityAndDiscoveryFailureRetainsCache() async {
        let account = descriptor("p@cached", label: "Cached home")
        let probe = RefreshTestProbe(failures: [.unauthorized])
        let provider = RefreshTestProvider(id: "p", accounts: [account], probe: probe)
        let store = SnapshotStore()
        let scheduler = RefreshScheduler(providers: [provider], store: store)

        await scheduler.refreshAll()
        let failedSnapshot = await store.snapshot(for: account.account.id)
        XCTAssertEqual(failedSnapshot?.account.label, "Cached home")
        XCTAssertEqual(failedSnapshot?.account.providerID, "p")
        XCTAssertTrue(failedSnapshot?.isStale == true)

        await probe.setDiscoveryFails(true)
        await scheduler.refreshAll()
        let retainedSnapshot = await store.snapshot(for: account.account.id)
        XCTAssertNotNil(retainedSnapshot)

        await probe.setDiscoveryFails(false)
        await probe.setAccounts([])
        await scheduler.refreshAll()
        let removedSnapshot = await store.snapshot(for: account.account.id)
        XCTAssertNil(removedSnapshot)
    }

    func test_restoreMarksSnapshotsStaleAndRemovalRejectsLateCompletion() async {
        let account = AccountIdentity(providerID: "p", id: "p@restore", label: "Restored")
        let store = SnapshotStore()
        await store.restore(["p@restore": UsageSnapshot(account: account, providerID: "p")])

        let restored = await store.snapshot(for: account.id)
        XCTAssertTrue(restored?.isStale == true)
        let generation = await store.beginRefreshWithGeneration(accountID: account.id)
        await store.remove(accountID: account.id)
        let accepted = await store.finishRefresh(
            accountID: account.id,
            result: .success(UsageSnapshot(account: account, providerID: "p")),
            generation: generation)
        let state = await store.state()

        XCTAssertFalse(accepted)
        XCTAssertNil(state.snapshots[account.id])
        XCTAssertFalse(state.isRefreshing)
    }

    private func descriptor(_ id: String, label: String? = nil) -> AccountDescriptor {
        AccountDescriptor(
            account: AccountIdentity(providerID: "p", id: id, label: label),
            source: .configFile)
    }

    private func waitForDiscovery(_ probe: RefreshTestProbe, count: Int) async {
        for _ in 0..<100 {
            let stats = await probe.stats()
            if stats.discoveries >= count { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("provider discovery did not start")
    }
}

private struct RefreshTestStats: Sendable {
    var discoveries = 0
    var fetches = 0
    var maxActiveFetches = 0
}

private actor RefreshTestProbe {
    private var accountDescriptors: [AccountDescriptor]
    private var discoveryFails = false
    private var discoveryContinuation: CheckedContinuation<Void, Never>?
    private var blockDiscovery: Bool
    private var hasAccountOverride = false
    private var failures: [ProviderError]
    private let fetchDelayNanoseconds: UInt64
    private var currentStats = RefreshTestStats()

    init(
        blockDiscovery: Bool = false,
        failures: [ProviderError] = [],
        fetchDelayNanoseconds: UInt64 = 0
    ) {
        self.accountDescriptors = []
        self.blockDiscovery = blockDiscovery
        self.failures = failures
        self.fetchDelayNanoseconds = fetchDelayNanoseconds
    }

    func discover(accounts: [AccountDescriptor]) async throws -> [AccountDescriptor] {
        currentStats.discoveries += 1
        if blockDiscovery {
            blockDiscovery = false
            await withCheckedContinuation { discoveryContinuation = $0 }
        }
        guard !discoveryFails else {
            throw ProviderError.network("discovery unavailable")
        }
        return hasAccountOverride ? accountDescriptors : accounts
    }

    func fetch(account: AccountDescriptor, providerID: String) async throws -> UsageSnapshot {
        currentStats.fetches += 1
        let active = currentStats.fetches - completedFetches
        currentStats.maxActiveFetches = max(currentStats.maxActiveFetches, active)
        defer { completedFetches += 1 }
        if fetchDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: fetchDelayNanoseconds)
        }
        if !failures.isEmpty {
            throw failures.removeFirst()
        }
        var identity = account.account
        identity.plan = "Plus"
        return UsageSnapshot(account: identity, providerID: providerID)
    }

    private var completedFetches = 0

    func releaseDiscovery() {
        discoveryContinuation?.resume()
        discoveryContinuation = nil
    }

    func setDiscoveryFails(_ value: Bool) {
        discoveryFails = value
    }

    func setAccounts(_ accounts: [AccountDescriptor]) {
        accountDescriptors = accounts
        hasAccountOverride = true
    }

    func stats() -> RefreshTestStats {
        currentStats
    }
}

private struct RefreshTestProvider: UsageProvider {
    let id: String
    let initialAccounts: [AccountDescriptor]
    let probe: RefreshTestProbe

    init(id: String, accounts: [AccountDescriptor], probe: RefreshTestProbe) {
        self.id = id
        self.initialAccounts = accounts
        self.probe = probe
    }

    var displayName: String { id }
    var dashboardURL: URL? { nil }

    func accounts() async throws -> [AccountDescriptor] {
        try await probe.discover(accounts: initialAccounts)
    }

    func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        try await probe.fetch(account: account, providerID: id)
    }
}
