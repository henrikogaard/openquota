import Foundation

/// In-memory, latest-value-per-account snapshot store. Value types in a bounded
/// dictionary — nothing accumulates across refreshes (CodexBar #788's failure
/// mode was per-poll allocations retained forever).
public actor SnapshotStore {
    public private(set) var snapshots: [String: UsageSnapshot] = [:]
    /// Accounts whose refresh is currently in flight (for spinners).
    public private(set) var refreshing: Set<String> = []

    public init() {}

    public func beginRefresh(accountID: String) {
        refreshing.insert(accountID)
    }

    public func finishRefresh(accountID: String, result: Result<UsageSnapshot, ProviderError>) {
        refreshing.remove(accountID)
        switch result {
        case .success(let snapshot):
            snapshots[accountID] = snapshot
        case .failure(let error):
            if var existing = snapshots[accountID] {
                existing.isStale = true
                existing.errorMessage = error.userMessage
                snapshots[accountID] = existing
            } else {
                snapshots[accountID] = UsageSnapshot(
                    account: AccountIdentity(providerID: "", id: accountID),
                    providerID: "",
                    isStale: true,
                    errorMessage: error.userMessage
                )
            }
        }
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
}
