#if os(macOS)
import Foundation
import Observation
import OpenQuotaCore

@MainActor @Observable
final class AppModel {
    private(set) var snapshots: [UsageSnapshot] = []
    private(set) var refreshing = false
    private(set) var providers: [any UsageProvider] = []
    private(set) var profiles: [LocalAccountProfile] = []
    private(set) var statusMessage: String?
    let isDemo: Bool

    private let store = SnapshotStore()
    private var scheduler: RefreshScheduler?
    // `nonisolated let` survives deinit; @Observable bars it on `var`, so the
    // task lives in a Sendable box deinit can cancel from any context.
    private nonisolated let observeTask = TaskBox()
    private let cache = SnapshotCache(url: AppModel.appSupportDir.appendingPathComponent("snapshots.json"))
    private let settings = AppSettings()
    private let http = URLSessionHTTPClient()
    private let credentials = KeychainCredentialStore()
    private let profileStore = LocalAccountProfileStore(
        url: AppModel.appSupportDir.appendingPathComponent("profiles.json"))

    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        if isDemo {
            snapshots = DemoSnapshots.all
            return
        }
        let cached = cache.load().mapValues { snapshot in
            var stale = snapshot
            stale.isStale = true
            return stale
        }
        snapshots = sorted(cached)
        rebuildProviders()
        let scheduler = RefreshScheduler(providers: providers, store: store)
        self.scheduler = scheduler
        observeTask.task = Task { [weak self, store] in
            await store.restore(cached)
            await scheduler.start()
            while !Task.isCancelled {
                await self?.pullFromStore()
                do { try await Task.sleep(for: .seconds(2)) }
                catch { break }
            }
            await scheduler.stop()
        }
    }

    deinit { observeTask.task?.cancel() }

    nonisolated static var appSupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("openquota", isDirectory: true)
    }

    private func sorted(_ values: [String: UsageSnapshot]) -> [UsageSnapshot] {
        values.values.sorted {
            ($0.providerID, $0.account.label ?? "", $0.account.id)
                < ($1.providerID, $1.account.label ?? "", $1.account.id)
        }
    }

    private func pullFromStore() async {
        await store.markStale(olderThan: 300)
        let state = await store.state()
        let updated = sorted(state.snapshots)
        refreshing = state.isRefreshing
        guard snapshots != updated else { return }
        snapshots = updated
        do { try cache.save(state.snapshots) }
        catch { statusMessage = "Couldn't save usage cache: \(error.localizedDescription)" }
    }

    private func rebuildProviders() {
        do { profiles = try profileStore.profiles() }
        catch { statusMessage = "Couldn't load account profiles: \(error.localizedDescription)" }
        var customSpecs: [ProviderSpec] = []
        do { customSpecs = try settings.userSpecs() }
        catch { statusMessage = "Couldn't load custom providers: \(error.localizedDescription)" }
        let registry = ProviderRegistry(
            http: http, credentials: credentials, extraSpecs: customSpecs)
        providers = registry.providers
        for profile in profiles {
            guard let path = Self.credentialPaths[profile.providerID] else { continue }
            let files = LocalCredentialFiles(
                overridePaths: [path: URL(fileURLWithPath: profile.credentialPath)])
            if let base = Adapters.all(http: http, credentials: credentials, files: files)
                .first(where: { $0.id == profile.providerID }) {
                providers.append(ProfiledProvider(profile: profile, base: base))
            }
        }
    }

    static let credentialPaths: [String: String] = [
        "claude": ".claude/.credentials.json", "codex": ".codex/auth.json",
        "grok": ".grok/auth.json", "opencode": ".local/share/opencode/auth.json",
        "devin": ".local/share/devin/credentials.toml",
    ]

    func refreshNow() {
        guard !isDemo else { return }
        Task {
            await scheduler?.refreshAll(force: true)
            await pullFromStore()
        }
    }

    private func configurationChanged() {
        rebuildProviders()
        let updated = providers
        Task {
            await scheduler?.setProviders(updated)
            await scheduler?.refreshAll(force: true)
            await pullFromStore()
        }
    }

    func addProfile(providerID: String, label: String, path: String) throws {
        guard !isDemo else { return }
        try profileStore.add(providerID: providerID, label: label, credentialPath: path)
        configurationChanged()
    }

    func removeProfile(id: String) throws {
        guard !isDemo else { return }
        try profileStore.remove(id: id)
        configurationChanged()
    }

    func addAPIKey(_ secret: String, provider: GenericProvider, label: String?) throws {
        guard !isDemo else { return }
        _ = try provider.addKey(secret, label: label)
        refreshNow()
    }

    func addSessionToken(_ raw: String, label: String?) throws {
        guard !isDemo, let cursor = providers.compactMap({ $0 as? CursorProvider }).first else { return }
        _ = try cursor.addSessionToken(raw, label: label)
        refreshNow()
    }

    func removeAccount(_ account: AccountDescriptor) throws {
        guard !isDemo else { return }
        if let generic = specProviders().first(where: { $0.id == account.account.providerID }) {
            try generic.removeKey(accountID: account.id)
        } else if let cursor = providers.compactMap({ $0 as? CursorProvider }).first,
                  account.account.providerID == "cursor" {
            try cursor.removeSessionToken(accountID: account.id)
        }
        Task {
            await store.remove(accountID: account.id)
            await pullFromStore()
            await scheduler?.refreshAll(force: true)
        }
    }

    func renameAccount(_ account: AccountDescriptor, label: String) throws {
        guard !isDemo else { return }
        if let generic = specProviders().first(where: { $0.id == account.account.providerID }) {
            try generic.renameKey(accountID: account.id, label: label)
        } else if let cursor = providers.compactMap({ $0 as? CursorProvider }).first,
                  account.account.providerID == "cursor" {
            try cursor.renameSessionToken(accountID: account.id, label: label)
        }
        refreshNow()
    }

    func savedAccounts() async throws -> [AccountDescriptor] {
        var accounts: [AccountDescriptor] = []
        for provider in providers where provider is GenericProvider || provider is CursorProvider {
            accounts += try await provider.accounts()
        }
        return accounts.sorted { ($0.account.providerID, $0.account.label ?? "") < ($1.account.providerID, $1.account.label ?? "") }
    }

    func specProviders() -> [GenericProvider] {
        providers.compactMap { $0 as? GenericProvider }
    }

    func detectedLocalProviders() async -> [(id: String, name: String, accounts: Int)] {
        var out: [(String, String, Int)] = []
        for provider in providers where !(provider is GenericProvider)
            && !(provider is ProfiledProvider) && !(provider is CursorProvider) {
            out.append((provider.id, provider.displayName, (try? await provider.accounts())?.count ?? 0))
        }
        return out
    }

    func providerName(_ id: String) -> String {
        providers.first(where: { $0.id == id })?.displayName
            ?? ["opencode": "OpenCode Go", "openrouter": "OpenRouter",
                "codex": "Codex / ChatGPT", "mistral": "Mistral Vibe"][id] ?? id.capitalized
    }

    func dashboardURL(_ id: String) -> URL? {
        providers.first(where: { $0.id == id })?.dashboardURL
    }
}
/// Sendable box for the store-observer task — lets a nonisolated `deinit`
/// cancel the polling loop (see `observeTask`).
final class TaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}
#endif
