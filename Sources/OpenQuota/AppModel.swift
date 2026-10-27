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
    /// Auto-detected local providers the user chose not to see.
    private(set) var hiddenProviderIDs = Set(UserDefaults.standard.stringArray(forKey: AppModel.hiddenProvidersKey) ?? [])
    /// Display names of hidden providers that are still installed.
    private(set) var hiddenProviderNames: [String: String] = [:]
    private(set) var codexLoginStatus: String?
    private(set) var codexLoginBusy = false
    let isDemo: Bool
    /// Set by the popover so Settings opens straight into the Add Account sheet.
    var requestsAddAccount = false
    private(set) var spendEnabled = UserDefaults.standard.bool(forKey: "localSpendEnabled")
    private(set) var spend = SpendSummary()
    private(set) var spendScanning = false
    /// Daily totals saved on this Mac; outlives the logs it was read from.
    private(set) var spendHistory = SpendHistory()
    /// Reads logs into usage.sqlite: files already read, recent requests, daily totals.
    private let spendScanner = LocalSpendScanner(
        databaseURL: AppModel.appSupportDir.appendingPathComponent("usage.sqlite"))
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
    private let claudeCLIRefreshRequests = ClaudeCLIRefreshRequests()
    private var codexLoginTask: Task<Void, Never>?
    private var codexLoginGeneration: UInt64 = 0

    init() {
        isDemo = ProcessInfo.processInfo.arguments.contains("--demo")
        if isDemo {
            snapshots = DemoSnapshots.all
            spendEnabled = true
            spend = Self.demoSpend()
            spendHistory = SpendHistory(days: spend.days)
            return
        }
        // 0.2.0 kept history in a JSON file; the database replaces it and
        // rebuilds from the logs.
        try? FileManager.default.removeItem(at: Self.appSupportDir.appendingPathComponent("spend-history.json"))
        let scanner = spendScanner
        spendTask.task = Task { [weak self] in
            let days = await scanner.savedDays()
            guard let self, self.spendHistory.isEmpty else { return }
            self.spendHistory = SpendHistory(days: days)
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
                store: subscriptionStore,
                refreshRequests: claudeCLIRefreshRequests))
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
            // Hidden detected providers are dropped before refresh, so they are
        // never queried and their cards disappear on the next pass.
        let hidden = providers.filter { Self.isDetectedLocal($0) && hiddenProviderIDs.contains($0.id) }
        hiddenProviderNames = Dictionary(hidden.map { ($0.id, $0.displayName) }) { first, _ in first }
        providers.removeAll { Self.isDetectedLocal($0) && hiddenProviderIDs.contains($0.id) }
    }

    static var codexConnectedStatus: String { L("Codex account connected.", "Codex-kontoen er koblet til.") }

    static let credentialPaths: [String: String] = [
        "grok": ".grok/auth.json", "opencode": ".local/share/opencode/auth.json",
        "devin": ".local/share/devin/credentials.toml",
    ]

    func refreshNow() {
        guard !isDemo else { return }
        claudeCLIRefreshRequests.request()
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
        // Turning off stops reading logs; saved history stays until deleted.
        refreshSpend(force: true)
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
            self.spendHistory = SpendHistory(days: summary.days)
            self.spendScanning = false
            // Catching up on older logs: keep going in short passes.
            if summary.pendingFiles > 0 {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled, self.spendGeneration == generation else { return }
                self.refreshSpend(force: true)
            }
        }
    }

    /// Deletes the saved daily totals. The next scan rebuilds what the logs
    /// still hold.
    func deleteSpendHistory() {
        guard !isDemo else { return }
        spendHistory = SpendHistory()
        spendGeneration &+= 1
        spendTask.task?.cancel()
        spend = SpendSummary()
        spendScanning = false
        let scanner = spendScanner
        spendTask.task = Task { [weak self] in
            await scanner.deleteAll()
            guard !Task.isCancelled else { return }
            self?.refreshSpend(force: true)
        }
    }

    /// A readable name for a usage source, plus the account email when known.
    func spendSourceName(_ key: String) -> (name: String, email: String?) {
        guard let source = SpendSource(key: key) else { return (key, nil) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let connection = subscriptionConnections.first {
            URL(fileURLWithPath: $0.directory).standardizedFileURL.path == source.folder
        }
        let email = connection.flatMap { connection in
            snapshots.first { $0.account.id == connection.accountID }?.account.email
        }
        switch source.provider {
        case .claude:
            let app: String = switch source.app {
            case "claude-desktop": "Claude Desktop"
            case "cli", "": "Claude CLI"
            case "claude-vscode": "Claude · VS Code"
            case let other where other.hasPrefix("sdk"): "Claude · Agent SDK"
            case let other: "Claude · \(other)"
            }
            if source.folder == home + "/.claude" {
                // Desktop signs in on its own; only the CLI uses this folder's login.
                guard source.app != "claude-desktop" else { return (app, nil) }
                if case .signedIn(let folderEmail) = ClaudeProfileStatus.check(configDirectory: source.folder) {
                    return (app, folderEmail ?? email)
                }
                return (app, email)
            }
            let label = connection?.label ?? (source.folder as NSString).lastPathComponent
            return ("\(app) · \(label)", email)
        case .codex:
            if source.folder == home + "/.codex" { return ("Codex", nil) }
            return ("Codex · \(connection?.label ?? (source.folder as NSString).lastPathComponent)", email)
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

    func setClaudeCLIUsageCheck(_ enabled: Bool, for connection: SubscriptionConnection) throws {
        guard !isDemo else { return }
        try subscriptionStore.setCLIUsageCheck(enabled, for: connection.id)
        if enabled { claudeCLIRefreshRequests.request() }
        configurationChanged()
    }

    func installClaudeStatusLine(
        label: String, configurationDirectory: String, helper: URL, cliUsageCheck: Bool = false
    ) throws {
        guard !isDemo else { return }
        let directory = (configurationDirectory as NSString).expandingTildeInPath
        let installer = ClaudeStatusLineInstaller(store: subscriptionStore)
        let connection = try installer.install(
            label: label,
            configurationDirectory: directory,
            helperExecutable: helper)
        if cliUsageCheck {
            try subscriptionStore.setCLIUsageCheck(true, for: connection.id)
            claudeCLIRefreshRequests.request()
        }
        configurationChanged()
    }

    func startCodexLogin(
        label: String,
        executablePath: String?,
        existingConnection: SubscriptionConnection? = nil,
        openAuthURL: @escaping @MainActor @Sendable (URL) -> Void
    ) {
        guard !isDemo, !codexLoginBusy else { return }
        if let existingConnection, existingConnection.kind != .codexAppServer {
            codexLoginStatus = L("This connection can't sign in with Codex.", "Denne tilkoblingen kan ikke logge inn med Codex.")
            return
        }
        let normalizedLabel = existingConnection?.label
            ?? label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty else {
            codexLoginStatus = L("Enter an account label.", "Skriv inn et kontonavn.")
            return
        }
        let expandedPath = executablePath.map { ($0 as NSString).expandingTildeInPath }
        if let expandedPath, !expandedPath.hasPrefix("/") {
            codexLoginStatus = L("Choose an absolute Codex executable path.", "Velg en absolutt sti til Codex.")
            return
        }
        let connection: SubscriptionConnection
        if let existingConnection {
            connection = existingConnection
        } else {
            let id = UUID()
            connection = SubscriptionConnection(
                id: id,
                kind: .codexAppServer,
                label: normalizedLabel,
                directory: subscriptionStore.appOwnedConnectionsDirectory
                    .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
                    .appendingPathComponent("codex-home", isDirectory: true).path)
        }
        let home: URL
        do {
            home = try subscriptionStore.codexHome(for: connection)
        } catch {
            codexLoginStatus = L("Couldn't prepare a private Codex account home.", "Kunne ikke klargjøre en privat Codex-kontomappe.")
            return
        }
        let savedExecutablePath = existingConnection.flatMap {
            try? subscriptionStore.codexExecutable(for: $0)?.path
        }
        let preferredPath = expandedPath ?? savedExecutablePath
        guard let executable = CodexExecutableResolver.resolve(
            preferredPath: preferredPath) else {
            codexLoginStatus = L("Codex CLI was not found. Install it or choose its executable.", "Fant ikke Codex CLI. Installer den eller velg filen.")
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
                if expandedPath != nil {
                    try self.subscriptionStore.setCodexExecutable(
                        executable, for: connection)
                }
                if existingConnection == nil {
                    _ = try self.subscriptionStore.addCodex(
                        id: connection.id, label: normalizedLabel)
                }
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

    func addMistralSession(_ raw: String, label: String?) throws {
        guard !isDemo, let mistral = providers.compactMap({ $0 as? MistralProvider }).first else { return }
        _ = try mistral.addCookieHeader(raw, label: label)
        refreshNow()
    }

    func replaceCredential(_ secret: String, for account: AccountDescriptor) async throws {
        guard !isDemo else { return }
        if let generic = specProviders().first(where: { $0.id == account.account.providerID }) {
            _ = try generic.replaceKey(secret, accountID: account.id)
        } else if account.account.providerID == "cursor",
                  let cursor = providers.compactMap({ $0 as? CursorProvider }).first {
            try cursor.replaceSessionToken(secret, accountID: account.id)
        } else if account.account.providerID == "mistral",
                  let mistral = providers.compactMap({ $0 as? MistralProvider }).first {
            try mistral.replaceCookieHeader(secret, accountID: account.id)
        } else {
            throw ProviderError.notLoggedIn
        }
        await store.remove(accountID: account.id)
        await pullFromStore()
        configurationChanged()
    }

    func removeAccount(_ account: AccountDescriptor) throws {
        guard !isDemo else { return }
        if let generic = specProviders().first(where: { $0.id == account.account.providerID }) {
            try generic.removeKey(accountID: account.id)
        } else if let cursor = providers.compactMap({ $0 as? CursorProvider }).first,
                  account.account.providerID == "cursor" {
            try cursor.removeSessionToken(accountID: account.id)
        } else if let mistral = providers.compactMap({ $0 as? MistralProvider }).first,
                  account.account.providerID == "mistral" {
            try mistral.removeCookieHeader(accountID: account.id)
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
        } else if let mistral = providers.compactMap({ $0 as? MistralProvider }).first,
                  account.account.providerID == "mistral" {
            try mistral.renameCookieHeader(accountID: account.id, label: label)
        }
        refreshNow()
    }

    func savedAccounts() async throws -> [AccountDescriptor] {
        var accounts: [AccountDescriptor] = []
        for provider in providers where provider is GenericProvider || provider is CursorProvider
            || provider is MistralProvider {
            accounts += try await provider.accounts()
        }
        return accounts.sorted { ($0.account.providerID, $0.account.label ?? "") < ($1.account.providerID, $1.account.label ?? "") }
    }

    func specProviders() -> [GenericProvider] {
        providers.compactMap { $0 as? GenericProvider }
    }

    static let hiddenProvidersKey = "hiddenProviderIDs"

    /// Providers found from a local CLI sign-in, as opposed to ones the user added.
    static func isDetectedLocal(_ provider: any UsageProvider) -> Bool {
        !(provider is GenericProvider) && !(provider is ProfiledProvider) && !(provider is CursorProvider)
            && !(provider is MistralProvider)
            && provider.id != "claude" && provider.id != "codex"
    }

    /// Hide or show an auto-detected provider. Its sign-in is not touched.
    func setProviderHidden(_ hidden: Bool, id: String) {
        guard !isDemo else { return }
        if hidden { hiddenProviderIDs.insert(id) } else { hiddenProviderIDs.remove(id) }
        UserDefaults.standard.set(hiddenProviderIDs.sorted(), forKey: Self.hiddenProvidersKey)
        configurationChanged()
    }

    func detectedLocalProviders() async -> [(id: String, name: String, accounts: Int)] {
        var out: [(String, String, Int)] = []
        for provider in providers where Self.isDetectedLocal(provider) {
            out.append((provider.id, provider.displayName, (try? await provider.accounts())?.count ?? 0))
        }
        return out
    }

    func providerName(_ id: String) -> String {
        providers.first(where: { $0.id == id })?.displayName
            ?? hiddenProviderNames[id]
            ?? ["opencode": "OpenCode Go", "opencode-go": "OpenCode Go", "openrouter": "OpenRouter",
                "claude": "Claude Code", "codex": "Codex / ChatGPT",
                "mistral": "Mistral"][id] ?? id.capitalized
    }

    func dashboardURL(_ id: String) -> URL? {
        providers.first(where: { $0.id == id })?.dashboardURL
    }

    func sourceNote(_ id: String) -> String? {
        switch id {
        case "claude":
            L("Claude Code status line · updates while you use Claude Code",
              "Claude Code-statuslinje · oppdateres mens du bruker Claude Code")
        case "codex":
            L("Codex app-server · subscription data returned by ChatGPT",
              "Codex-appserver · abonnementsdata fra ChatGPT")
        case "cursor":
            L("Cursor's unofficial dashboard endpoint; not an official subscription API",
              "Uoffisielt Cursor-kontrollpanelendepunkt; ikke et offisielt abonnements-API")
        case "mistral":
            L("Mistral's web console session (admin.mistral.ai); unofficial endpoints, not a public API",
              "Nettkonsolløkten til Mistral (admin.mistral.ai); uoffisielle endepunkter, ikke et offentlig API")
        case "opencode", "opencode-go":
            L("OpenCode Go workspace usage endpoint · one key per workspace subscription",
              "Bruksendepunkt for OpenCode Go-arbeidsområde · én nøkkel per arbeidsområdeabonnement")
        default:
            L("Usage as reported by \(providerName(id)); OpenQuota does not independently verify provider figures.",
              "Bruk rapportert av \(providerName(id)); OpenQuota bekrefter ikke leverandørtall uavhengig.")
        }
    }

    func isExperimentalProvider(_ providerID: String) -> Bool {
        if providerID == "cursor" || providerID == "mistral" { return true }
        let canonicalID = providerID == "opencode" ? "opencode-go" : providerID
        return specProviders().contains { $0.id == canonicalID && $0.unverified }
    }

    func credentialSourceName(_ source: CredentialSource) -> String {
        switch source {
        case .userSuppliedKey: L("Keychain · added in OpenQuota", "Nøkkelring · lagt til i OpenQuota")
        case .configFile: L("Local provider file", "Lokal leverandørfil")
        case .keychainItem: L("Provider Keychain item", "Nøkkelringoppføring fra leverandøren")
        case .environment: L("Environment variable", "Miljøvariabel")
        }
    }
}
/// Sendable box for the store-observer task — lets a nonisolated `deinit`
/// cancel the polling loop (see `observeTask`).
final class TaskBox: @unchecked Sendable {
    var task: Task<Void, Never>?
}
#endif
