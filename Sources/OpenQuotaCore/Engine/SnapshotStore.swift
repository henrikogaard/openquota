import Foundation

/// In-memory, latest-value-per-account snapshot store. Value types in a bounded
/// dictionary — nothing accumulates across refreshes (CodexBar #788's failure
/// mode was per-poll allocations retained forever).
public actor SnapshotStore {
    public private(set) var snapshots: [String: UsageSnapshot] = [:]
    /// Accounts whose refresh is currently in flight (for spinners).
    public private(set) var refreshing: Set<String> = []
    private var registeredAccounts: [String: AccountIdentity] = [:]
    private var generations: [String: UInt64] = [:]
    private var nextGeneration: UInt64 = 0

    public init() {}

    private func hasReading(_ accountID: String) -> Bool {
        guard let s = snapshots[accountID] else { return false }
        return !s.windows.isEmpty || s.creditsRemaining != nil
    }

    public func restore(_ restored: [String: UsageSnapshot]) {
        snapshots = restored.mapValues { snapshot in
            var snapshot = snapshot
            snapshot.isStale = true
            return snapshot
        }
        registeredAccounts = snapshots.mapValues(\.account)
    }

    public func register(account: AccountIdentity) {
        registeredAccounts[account.id] = account
        if var snapshot = snapshots[account.id] {
            let cachedPlan = snapshot.account.plan
            snapshot.account = account
            if snapshot.account.plan == nil {
                snapshot.account.plan = cachedPlan
            }
            snapshot.providerID = account.providerID
            snapshots[account.id] = snapshot
        }
    }

    public func beginRefresh(accountID: String) {
        _ = beginRefreshWithGeneration(accountID: accountID)
    }

    @discardableResult
    public func beginRefreshWithGeneration(accountID: String) -> UInt64 {
        refreshing.insert(accountID)
        nextGeneration &+= 1
        generations[accountID] = nextGeneration
        return nextGeneration
    }

    public func finishRefresh(accountID: String, result: Result<UsageSnapshot, ProviderError>) {
        _ = finishRefresh(accountID: accountID, result: result, generation: nil)
    }

    public func finishRefresh(
        accountID: String,
        result: Result<UsageSnapshot, ProviderError>,
        generation: UInt64?
    ) -> Bool {
        if let generation {
            guard generations[accountID] == generation,
                  refreshing.contains(accountID) else { return false }
        }
        refreshing.remove(accountID)
        generations.removeValue(forKey: accountID)
        switch result {
        case .success(let snapshot):
            snapshots[accountID] = snapshot
            registeredAccounts[accountID] = snapshot.account
        case .failure(.awaitingReading) where !hasReading(accountID):
            if let account = registeredAccounts[accountID] ?? snapshots[accountID]?.account {
                snapshots[accountID] = UsageSnapshot(account: account, providerID: account.providerID)
            }
        case .failure(let error):
            if var existing = snapshots[accountID] {
                existing.isStale = true
                existing.errorMessage = error.userMessage
                snapshots[accountID] = existing
            } else if let account = registeredAccounts[accountID] {
                snapshots[accountID] = UsageSnapshot(
                    account: account,
                    providerID: account.providerID,
                    isStale: true,
                    errorMessage: error.userMessage
                )
            } else {
                // Account ids are minted as `provider@hash` — recover the
                // provider name so a first-failure card is still identifiable.
                let providerID = accountID.split(separator: "@").first
                    .map(String.init) ?? accountID
                snapshots[accountID] = UsageSnapshot(
                    account: AccountIdentity(providerID: providerID, id: accountID),
                    providerID: providerID,
                    isStale: true,
                    errorMessage: error.userMessage
                )
            }
        }
        return true
    }

    public func cancelRefresh(accountID: String, generation: UInt64) {
        guard generations[accountID] == generation else { return }
        refreshing.remove(accountID)
        generations.removeValue(forKey: accountID)
    }

    public func remove(accountID: String) {
        generations.removeValue(forKey: accountID)
        snapshots.removeValue(forKey: accountID)
        registeredAccounts.removeValue(forKey: accountID)
        refreshing.remove(accountID)
    }

    public func retain(accountIDs: Set<String>) {
        let removed = Set(snapshots.keys)
            .union(registeredAccounts.keys)
            .subtracting(accountIDs)
        for accountID in removed {
            remove(accountID: accountID)
        }
        refreshing.formIntersection(accountIDs)
    }

    /// A snapshot is "fresh" for one refresh interval; older than that it's stale
    /// even without an error (e.g. Mac asleep).
    public func markStale(olderThan interval: TimeInterval, now: Date = Date()) {
        for (key, var snapshot) in snapshots where now.timeIntervalSince(snapshot.fetchedAt) > interval * 2 {
            snapshot.isStale = true
            snapshots[key] = snapshot
        }
    }

    public func snapshot(for accountID: String) -> UsageSnapshot? {
        snapshots[accountID]
    }

    public var isRefreshing: Bool { !refreshing.isEmpty }

    public func state() -> (snapshots: [String: UsageSnapshot], isRefreshing: Bool) {
        (snapshots, !refreshing.isEmpty)
    }
}
