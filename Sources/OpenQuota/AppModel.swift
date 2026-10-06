#if os(macOS)
import Foundation
import Observation
import OpenQuotaCore

/// UI-facing bridge: owns the scheduler + snapshot store, exposes flat state
/// for SwiftUI. Single instance for the app's life.
@MainActor @Observable
final class AppModel {
    private(set) var snapshots: [UsageSnapshot] = []
    private(set) var refreshing = false
    private(set) var nextRefresh: Date?

    /// Providers visible in the UI (enabled in settings).
    private(set) var providers: [any UsageProvider] = []

    private let store = SnapshotStore()
    private var scheduler: RefreshScheduler?
    private var observeTask: Task<Void, Never>?
    private let cache: SnapshotCache
    private let settings = AppSettings()

    init() {
        cache = SnapshotCache(url: Self.cacheURL)
        boot()
    }

    nonisolated static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("openquota", isDirectory: true)
    }

    static var cacheURL: URL {
        appSupportDir.appendingPathComponent("snapshots.json")
    }

    private func boot() {
        // Show last-known values instantly before the first fetch finishes.
        for (_, snapshot) in cache.load() {
            snapshots.append(snapshot)
        }
        rebuildProviders()
        scheduler = RefreshScheduler(providers: providers, store: store)
        Task { [scheduler] in await scheduler?.start() }
        observeTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pullFromStore()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func pullFromStore() async {
        let all = await store.snapshots
        let isRefreshing = await store.isRefreshing
        await MainActor.run {
            self.snapshots = all.values.sorted {
                ($0.providerID, $0.account.id) < ($1.providerID, $1.account.id)
            }
            self.refreshing = isRefreshing
        }
    }

    private func rebuildProviders() {
        let http = URLSessionHTTPClient()
        let credentials: any CredentialStore = KeychainCredentialStore()
        let registry = ProviderRegistry(
            http: http, credentials: credentials,
            extraSpecs: settings.userSpecs())
        providers = registry.providers
    }

    /// Manual refresh (⌘R / Refresh button): one pass over every provider.
    func refreshNow() {
        Task {
            await scheduler?.refreshAll()
            await pullFromStore()
            try? persist()
        }
    }

    /// Persist snapshots (called after refresh passes; app exit also saves).
    func persist() throws {
        try cache.save(Dictionary(uniqueKeysWithValues: snapshots.map { ($0.account.id, $0) }))
    }

    /// Settings: register a new API key for a spec-driven provider.
    func addAPIKey(_ secret: String, provider: any UsageProvider, label: String?) throws -> AccountIdentity {
        guard let generic = provider as? GenericProvider else {
            throw ProviderError.badResponse("provider doesn't take API keys")
        }
        let identity = try generic.addKey(secret, label: label)
        Task { await refreshNow() }
        return identity
    }

    func removeAPIKey(accountID: String, provider: any UsageProvider) throws {
        guard let generic = provider as? GenericProvider else { return }
        try generic.removeKey(accountID: accountID)
        snapshots.removeAll { $0.account.id == accountID }
        Task { await refreshNow() }
    }

    func specProviders() -> [GenericProvider] {
        providers.compactMap { $0 as? GenericProvider }
    }

    /// Providers that read local credentials / CLIs instead of stored keys.
    /// Returns (displayName, accountCount, dashboardURL) for the Settings
    /// "detected" list — cheap local checks, no network.
    func detectedLocalProviders() async -> [(id: String, name: String, accounts: Int)] {
        var out: [(String, String, Int)] = []
        for provider in providers where !(provider is GenericProvider) {
            let count = (try? await provider.accounts())?.count ?? 0
            out.append((provider.id, provider.displayName, count))
        }
        return out
    }

    /// Settings: register a pasted session token (Cursor's userID::jwt cookie).
    func addSessionToken(_ raw: String, provider: any UsageProvider) throws {
        guard let cursor = provider as? CursorProvider else {
            throw ProviderError.badResponse("provider doesn't take session tokens")
        }
        _ = try cursor.addSessionToken(raw)
        Task { await refreshNow() }
    }

    /// Non-spec providers the Settings UI can offer token entry for.
    func tokenProviders() -> [any UsageProvider] {
        providers.filter { $0 is CursorProvider }
    }
}
#endif
