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
        /// Backoff doubles on each consecutive failure up to this cap.
        public var backoffCap: TimeInterval = 30 * 60

        public init() {}
    }

    private let providers: [any UsageProvider]
    private let store: SnapshotStore
    private let config: Config
    /// Consecutive-failure count per account id — drives exponential backoff.
    private var failures: [String: (count: Int, nextRetry: Date)] = [:]
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

    /// One pass: every provider's every account, in parallel.
    public func refreshAll() async {
        var accounts: [(any UsageProvider, AccountDescriptor)] = []
        for provider in providers {
            if let found = try? await provider.accounts() {
                accounts.append(contentsOf: found.map { (provider, $0) })
            }
        }
        let now = Date()
        await withTaskGroup(of: Void.self) { group in
            for (provider, account) in accounts {
                let id = account.account.id
                // Exponential backoff: skip accounts whose next retry is in the future.
                if let failure = failures[id], failure.nextRetry > now { continue }
                group.addTask {
                    await self.store.beginRefresh(accountID: id)
                    let result = await self.fetch(provider: provider, account: account)
                    await self.store.finishRefresh(accountID: id, result: result)
                    await self.recordResult(accountID: id, result: result)
                }
            }
        }
    }

    /// Manual refresh for one account (e.g. "Refresh" menu item). Ignores backoff.
    public func refresh(provider: any UsageProvider, account: AccountDescriptor) async {
        await store.beginRefresh(accountID: account.account.id)
        let result = await fetch(provider: provider, account: account)
        await store.finishRefresh(accountID: account.account.id, result: result)
        recordResult(accountID: account.account.id, result: result)
    }

    private func fetch(
        provider: any UsageProvider, account: AccountDescriptor
    ) async -> Result<UsageSnapshot, ProviderError> {
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
            return .success(snapshot)
        } catch let error as ProviderError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(.timedOut)
        } catch {
            return .failure(.network(error.localizedDescription))
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
            if case .rateLimited(let retryAfter) = error, let retryAfter {
                delay = retryAfter
            } else {
                delay = min(config.interval * pow(2.0, Double(count - 1)), config.backoffCap)
            }
            failures[accountID] = (count, Date().addingTimeInterval(delay))
        }
    }
}
