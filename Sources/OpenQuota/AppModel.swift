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
    private(set) var subscriptionConnections: [SubscriptionConnection] = []
    private(set) var statusMessage: String?
    private(set) var codexLoginStatus: String?
    private(set) var codexLoginBusy = false
    let isDemo: Bool
    /// Set by the popover so Settings opens straight into the Add Account sheet.
    var requestsAddAccount = false
    private(set) var spendEnabled = UserDefaults.standard.bool(forKey: "localSpendEnabled")
    private(set) var spend = SpendSummary()
    private(set) var spendScanning = false
    private let spendScanner = LocalSpendScanner()
    private nonisolated let spendTask = TaskBox()
    private var spendGeneration: UInt64 = 0

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
    private let subscriptionStore = SubscriptionConnectionStore(
        url: AppModel.appSupportDir.appendingPathComponent("connections.json"))
    private var codexLoginTask: Task<Void, Never>?
    private var codexLoginGeneration: UInt64 = 0

    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        if isDemo {
            snapshots = DemoSnapshots.all
            spendEnabled = true
            spend = Self.demoSpend()
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

    deinit {
        observeTask.task?.cancel()
        spendTask.task?.cancel()
    }

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
        refreshSpend()
        await store.markStale(olderThan: 300)
        let state = await store.state()
        let updated = sorted(state.snapshots)
        refreshing = state.isRefreshing
        guard snapshots != updated else { return }
        snapshots = updated
        do { try cache.save(state.snapshots) }
        catch { statusMessage = L("Couldn't save usage cache: \(error.localizedDescription)", "Kunne ikke lagre bruksbufferen: \(error.localizedDescription)") }
    }

    private func rebuildProviders() {
        do { profiles = try profileStore.profiles() }
        catch { statusMessage = L("Couldn't load account profiles: \(error.localizedDescription)", "Kunne ikke laste kontoprofiler: \(error.localizedDescription)") }
        do { subscriptionConnections = try subscriptionStore.connections() }
        catch { statusMessage = L("Couldn't load subscription connections", "Kunne ikke laste abonnementstilkoblinger") }
        var customSpecs: [ProviderSpec] = []
        do { customSpecs = try settings.userSpecs() }
        catch { statusMessage = L("Couldn't load custom providers: \(error.localizedDescription)", "Kunne ikke laste egne leverandører: \(error.localizedDescription)") }
        let registry = ProviderRegistry(
            http: http, credentials: credentials, extraSpecs: customSpecs)
        providers = registry.providers
        if subscriptionConnections.contains(where: { $0.kind == .claudeStatusLine }) {
            providers.append(ClaudeStatusLineProvider(
                connections: subscriptionConnections,
                store: subscriptionStore))
        }
        if subscriptionConnections.contains(where: { $0.kind == .codexAppServer }) {
            providers.append(CodexUsageProvider(
                connections: subscriptionConnections,
                store: subscriptionStore))
        }
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

    static var codexConnectedStatus: String { L("Codex account connected.", "Codex-kontoen er koblet til.") }

    static let credentialPaths: [String: String] = [
        "grok": ".grok/auth.json", "opencode": ".local/share/opencode/auth.json",
        "devin": ".local/share/devin/credentials.toml",
    ]

    func refreshNow() {
        guard !isDemo else { return }
        refreshSpend(force: true)
        Task {
            await scheduler?.refreshAll(force: true)
            await pullFromStore()
        }
    }

    private func configurationChanged() {
        rebuildProviders()
        spendGeneration &+= 1
        spendTask.task?.cancel()
        spendScanning = false
        refreshSpend(force: true)
        let updated = providers
        Task {
            await scheduler?.setProviders(updated)
            await scheduler?.refreshAll(force: true)
            await pullFromStore()
        }
    }

    func setSpendEnabled(_ enabled: Bool) {
        guard !isDemo else { return }
        spendGeneration &+= 1
        spendTask.task?.cancel()
        spendEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "localSpendEnabled")
        spend = SpendSummary()
        spendScanning = false
        let scanner = spendScanner
        // Queue cache erasure before a subsequent scan on the same actor.
        spendTask.task = Task { [weak self] in
            await scanner.clear()
            guard !Task.isCancelled else { return }
            self?.refreshSpend(force: true)
        }
    }

    private func refreshSpend(force: Bool = false) {
        guard spendEnabled, !isDemo, !spendScanning else { return }
        if !force, let updated = spend.scannedAt, Date().timeIntervalSince(updated) < 300 { return }
        spendScanning = true
        let generation = spendGeneration
        let sources = SpendLogSource.localSources(connections: subscriptionConnections)
        let scanner = spendScanner
        spendTask.task = Task { [weak self] in
            let summary = await scanner.scan(sources: sources)
            guard !Task.isCancelled, let self, self.spendEnabled, self.spendGeneration == generation else { return }
            self.spend = summary
            self.spendScanning = false
        }
    }

    private static func demoSpend() -> SpendSummary {
        var summary = SpendSummary()
        summary.scannedAt = Date()
        summary.hasLogs = true
        let today = Calendar.current.startOfDay(for: Date())
        for (offset, claude, codex) in [(0, 3.84, 1.26), (-1, 2.19, 0.78), (-2, 4.38, 2.06)] {
            let date = Calendar.current.date(byAdding: .day, value: offset, to: today)!
            for (provider, dollars) in [(SpendProvider.claude, claude), (.codex, codex)] {
                var total = SpendTotal()
                total.estimatedUSD = dollars
                total.pricedEvents = 12
                summary.days.append(SpendDay(date: date, provider: provider, total: total))
            }
        }
        return summary
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

    func installClaudeStatusLine(label: String, configurationDirectory: String, helper: URL) throws {
        guard !isDemo else { return }
        let directory = (configurationDirectory as NSString).expandingTildeInPath
        let installer = ClaudeStatusLineInstaller(store: subscriptionStore)
        _ = try installer.install(
            label: label,
            configurationDirectory: directory,
            helperExecutable: helper)
        configurationChanged()
    }

    func startCodexLogin(
        label: String,
        executablePath: String?,
        openAuthURL: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        guard !isDemo, !codexLoginBusy else { return }
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            codexLoginStatus = L("Enter an account label.", "Skriv inn et kontonavn.")
            return
        }
        let expandedPath = executablePath.map { ($0 as NSString).expandingTildeInPath }
        if let expandedPath, !expandedPath.hasPrefix("/") {
            codexLoginStatus = L("Choose an absolute Codex executable path.", "Velg en absolutt sti til Codex.")
            return
        }
        guard let executable = CodexExecutableResolver.resolve(
            preferredPath: expandedPath) else {
            codexLoginStatus = L("Codex CLI was not found. Install it or choose its executable.", "Fant ikke Codex CLI. Installer den eller velg filen.")
            return
        }
        let id = UUID()
        let home: URL
        do {
            let candidate = SubscriptionConnection(
                id: id,
                kind: .codexAppServer,
                label: normalizedLabel,
                directory: subscriptionStore.appOwnedConnectionsDirectory
                    .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
                    .appendingPathComponent("codex-home", isDirectory: true).path)
            home = try subscriptionStore.codexHome(for: candidate)
        } catch {
            codexLoginStatus = L("Couldn't prepare a private Codex account home.", "Kunne ikke klargjøre en privat Codex-kontomappe.")
            return
        }

        codexLoginGeneration &+= 1
        let generation = codexLoginGeneration
        codexLoginBusy = true
        codexLoginStatus = L("Starting Codex sign-in…", "Starter Codex-pålogging…")
        codexLoginTask = Task { [weak self] in
            guard let self else { return }
            do {
                _ = try await CodexAppServerClient.login(
                    executable: executable,
                    codexHome: home,
                    openAuthURL: { url in
                        Task { @MainActor [weak self] in
                            guard let self, self.codexLoginGeneration == generation else { return }
                            self.codexLoginStatus = L("Complete sign-in in your browser…", "Fullfør påloggingen i nettleseren…")
                            openAuthURL(url)
                        }
                    })
                try Task.checkCancellation()
                guard self.codexLoginGeneration == generation else { return }
                let pendingConnection = SubscriptionConnection(
                    id: id,
                    kind: .codexAppServer,
                    label: normalizedLabel,
                    directory: home.path)
                if expandedPath != nil {
                    try self.subscriptionStore.setCodexExecutable(
                        executable, for: pendingConnection)
                }
                _ = try self.subscriptionStore.addCodex(id: id, label: normalizedLabel)
                self.codexLoginBusy = false
                self.codexLoginTask = nil
                self.codexLoginStatus = Self.codexConnectedStatus
                self.configurationChanged()
            } catch is CancellationError {
                guard self.codexLoginGeneration == generation else { return }
                self.codexLoginBusy = false
                self.codexLoginTask = nil
                self.codexLoginStatus = L("Codex sign-in cancelled.", "Codex-påloggingen ble avbrutt.")
            } catch {
                guard self.codexLoginGeneration == generation else { return }
                self.codexLoginBusy = false
                self.codexLoginTask = nil
                self.codexLoginStatus = (error as? ProviderError)?.userMessage
                    ?? L("Codex sign-in failed. Try again.", "Codex-påloggingen mislyktes. Prøv igjen.")
            }
        }
    }

    func cancelCodexLogin() {
        guard codexLoginBusy else { return }
        codexLoginGeneration &+= 1
        codexLoginTask?.cancel()
        codexLoginTask = nil
        codexLoginBusy = false
        codexLoginStatus = L("Codex sign-in cancelled.", "Codex-påloggingen ble avbrutt.")
    }

    func removeSubscriptionConnection(_ connection: SubscriptionConnection) throws {
        guard !isDemo else { return }
        if connection.kind == .claudeStatusLine {
            let restored = try ClaudeStatusLineInstaller(store: subscriptionStore)
                .disconnect(connection)
            if !restored {
                statusMessage = L("Claude settings changed; their status-line command was kept.", "Claude-innstillingene er endret; statuslinjekommandoen ble beholdt.")
            }
        }
        try subscriptionStore.remove(id: connection.id)
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
            && !(provider is ProfiledProvider) && !(provider is CursorProvider)
            && provider.id != "claude" && provider.id != "codex" {
            out.append((provider.id, provider.displayName, (try? await provider.accounts())?.count ?? 0))
        }
        return out
    }

    func providerName(_ id: String) -> String {
        providers.first(where: { $0.id == id })?.displayName
            ?? ["opencode": "OpenCode Go", "opencode-go": "OpenCode Go", "openrouter": "OpenRouter",
                "claude": "Claude Code", "codex": "Codex / ChatGPT",
                "mistral": "Mistral Vibe"][id] ?? id.capitalized
    }

    func dashboardURL(_ id: String) -> URL? {
        providers.first(where: { $0.id == id })?.dashboardURL
    }

    func sourceNote(_ id: String) -> String? {
        switch id {
        case "claude": L("Claude Code status line · updates while you use Claude Code", "Claude Code-statuslinje · oppdateres mens du bruker Claude Code")
        case "codex": L("Codex managed ChatGPT sign-in · subscription limits", "ChatGPT-pålogging via Codex · abonnementsgrenser")
        default: nil
        }
    }
}
/// Sendable box for the store-observer task — lets a nonisolated `deinit`
/// cancel the polling loop (see `observeTask`).
final class TaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}
#endif
