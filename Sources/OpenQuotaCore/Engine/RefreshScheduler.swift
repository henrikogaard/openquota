import Foundation

/// Drives the fixed-cadence refresh loop: one pass over all providers'
/// accounts in parallel, then wait `interval`. One timer, one task group —
/// the only scheduled work in the app.
public actor RefreshScheduler {
    public struct Config: Sendable {
        /// Base cadence between refresh passes.
        public var interval: TimeInterval = 5 * 60
        /// Per-account fetch ceiling; a stuck provider is retried next pass.
        public var fetchTimeout: TimeInterval = 60
        /// Maximum number of account fetches to run concurrently.
        public var maxConcurrentRefreshes: Int = 4
        /// Backoff doubles on each consecutive failure up to this cap.
        public var backoffCap: TimeInterval = 30 * 60

        public init() {}
    }

    private struct FailureState {
        var count: Int
        var nextRetry: Date
        var retryAfterUntil: Date?
    }

    private var providers: [any UsageProvider]
    private let store: SnapshotStore
    private let config: Config
    /// Consecutive-failure count per account id — drives exponential backoff.
    private var failures: [String: FailureState] = [:]
    private var lastKnownAccountIDsByProvider: [String: Set<String>] = [:]
    private var inFlightAccountIDs: Set<String> = []
    private var isRefreshingAll = false
    private var task: Task<Void, Never>?

    public init(providers: [any UsageProvider], store: SnapshotStore, config: Config = Config()) {
        self.providers = providers
        self.store = store
        self.config = config
    }

    /// Start the loop: refresh once, then every `interval`.
    public func start() {
        guard task == nil else { return }
        task = Task { [self] in
            while !Task.isCancelled {
                await self.refreshAll()
                try? await Task.sleep(for: .seconds(self.config.interval))
            }
        }
    }

    public func stop() {
        task?.cancel()
        task = nil
    }

    public func setProviders(_ providers: [any UsageProvider]) async {
        while isRefreshingAll {
            do { try await Task.sleep(for: .milliseconds(50)) }
            catch { return }
        }
        self.providers = providers
    }

    /// One pass over every provider's accounts, with bounded concurrency.
    public func refreshAll(force: Bool = false) async {
        guard !isRefreshingAll else { return }
        isRefreshingAll = true
        defer { isRefreshingAll = false }

        var accounts: [(any UsageProvider, AccountDescriptor)] = []
        var seenAccountIDs: Set<String> = []
        var discoveredByProvider: [String: Set<String>] = [:]
        var failedProviderIDs: Set<String> = []
        let cached = await store.snapshots
        for provider in providers {
            guard !Task.isCancelled else { return }
            do {
                let found = try await provider.accounts()
                if discoveredByProvider[provider.id] == nil { discoveredByProvider[provider.id] = [] }
                for account in found where seenAccountIDs.insert(account.account.id).inserted {
                    accounts.append((provider, account))
                    discoveredByProvider[provider.id, default: []].insert(account.account.id)
                }
            } catch {
                guard !Task.isCancelled else { return }
                failedProviderIDs.insert(provider.id)
            }
        }
        guard !Task.isCancelled else { return }

        let activeProviderIDs = Set(providers.map(\.id))
        lastKnownAccountIDsByProvider = lastKnownAccountIDsByProvider.filter {
            activeProviderIDs.contains($0.key)
        }
        for (providerID, accountIDs) in discoveredByProvider
        where !failedProviderIDs.contains(providerID) {
            lastKnownAccountIDsByProvider[providerID] = accountIDs
        }
        var retainedAccountIDs = seenAccountIDs
        for providerID in failedProviderIDs {
            retainedAccountIDs.formUnion(lastKnownAccountIDsByProvider[providerID, default: []])
            retainedAccountIDs.formUnion(cached.values.filter { $0.providerID == providerID }.map(\.account.id))
        }
        failures = failures.filter { retainedAccountIDs.contains($0.key) }
        await store.retain(accountIDs: retainedAccountIDs)
        guard !Task.isCancelled else { return }

        let now = Date()
        var fetches: [(any UsageProvider, AccountDescriptor)] = []
        for (provider, account) in accounts {
            let id = account.account.id
            guard !inFlightAccountIDs.contains(id),
                  shouldRefresh(accountID: id, force: force, now: now) else { continue }
            inFlightAccountIDs.insert(id)
            fetches.append((provider, account))
        }
        for (_, account) in accounts {
            await store.register(account: account.account)
        }
        guard !Task.isCancelled else {
            for (_, account) in fetches {
                inFlightAccountIDs.remove(account.account.id)
            }
            return
        }

        let limit = max(1, config.maxConcurrentRefreshes)
        await withTaskGroup(of: Void.self) { group in
            var nextIndex = 0
            while nextIndex < min(limit, fetches.count) {
                let (provider, account) = fetches[nextIndex]
                group.addTask {
                    await self.refreshReserved(provider: provider, account: account)
                }
                nextIndex += 1
            }
            while await group.next() != nil, nextIndex < fetches.count {
                let (provider, account) = fetches[nextIndex]
                group.addTask {
                    await self.refreshReserved(provider: provider, account: account)
                }
                nextIndex += 1
            }
        }
    }

    /// Manual refresh for one account (e.g. "Refresh" menu item).
    public func refresh(provider: any UsageProvider, account: AccountDescriptor) async {
        let id = account.account.id
        guard !inFlightAccountIDs.contains(id),
              shouldRefresh(accountID: id, force: true, now: Date()) else { return }
        inFlightAccountIDs.insert(id)
        await store.register(account: account.account)
        await refreshReserved(provider: provider, account: account)
    }

    private func shouldRefresh(accountID: String, force: Bool, now: Date) -> Bool {
        guard let failure = failures[accountID] else { return true }
        if let retryAfterUntil = failure.retryAfterUntil, retryAfterUntil > now {
            return false
        }
        return force || failure.nextRetry <= now
    }

    private func refreshReserved(provider: any UsageProvider, account: AccountDescriptor) async {
        let id = account.account.id
        defer { inFlightAccountIDs.remove(id) }
        let generation = await store.beginRefreshWithGeneration(accountID: id)
        let result = await fetch(provider: provider, account: account)
        guard let result else {
            await store.cancelRefresh(accountID: id, generation: generation)
            return
        }
        let wasCurrent = await store.finishRefresh(
            accountID: id, result: result, generation: generation)
        guard wasCurrent else { return }
        recordResult(accountID: id, result: result)
    }

    private func fetch(
        provider: any UsageProvider, account: AccountDescriptor
    ) async -> Result<UsageSnapshot, ProviderError>? {
        do {
            let snapshot = try await withThrowingTaskGroup(of: UsageSnapshot.self) { group in
                group.addTask { try await provider.refresh(account: account) }
                group.addTask {
                    try await Task.sleep(for: .seconds(self.config.fetchTimeout))
                    throw ProviderError.timedOut
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            return Task.isCancelled ? nil : .success(snapshot)
        } catch let error as ProviderError {
            return Task.isCancelled ? nil : .failure(error)
        } catch is CancellationError {
            return Task.isCancelled ? nil : .failure(.timedOut)
        } catch {
            return Task.isCancelled ? nil : .failure(.network(error.localizedDescription))
        }
    }

    private func recordResult(accountID: String, result: Result<UsageSnapshot, ProviderError>) {
        switch result {
        case .success:
            failures.removeValue(forKey: accountID)
        case .failure(let error):
            let count = (failures[accountID]?.count ?? 0) + 1
            // Rate-limit responses carry a server hint; honor it over backoff.
            let delay: TimeInterval
            let retryAfterUntil: Date?
            if case .rateLimited(let retryAfter) = error, let retryAfter {
                delay = retryAfter
                retryAfterUntil = Date().addingTimeInterval(retryAfter)
            } else {
                delay = min(config.interval * pow(2.0, Double(count - 1)), config.backoffCap)
                retryAfterUntil = nil
            }
            failures[accountID] = FailureState(
                count: count,
                nextRetry: Date().addingTimeInterval(delay),
                retryAfterUntil: retryAfterUntil
            )
        }
    }
}
