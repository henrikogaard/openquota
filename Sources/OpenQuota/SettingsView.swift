#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// Settings in the standard macOS shape: toolbar tabs, with a Mail-style
/// Accounts pane (list with +/− and the selection's form beside it).
struct SettingsView: View {
    enum Tab: Hashable { case accounts, general }

    var model: AppModel
    @State private var tab = Tab.accounts
    @State private var adding = false

    var body: some View {
        TabView(selection: $tab) {
            AccountsPane(model: model, adding: $adding)
                .tabItem { Label(L("Accounts", "Kontoer"), systemImage: "person.crop.circle") }
                .tag(Tab.accounts)
            GeneralPane(model: model)
                .tabItem { Label(L("General", "Generelt"), systemImage: "gearshape") }
                .tag(Tab.general)
        }
        .onAppear(perform: consumeAddRequest)
        .onChange(of: model.requestsAddAccount) { _, _ in consumeAddRequest() }
    }

    private func consumeAddRequest() {
        guard model.requestsAddAccount else { return }
        model.requestsAddAccount = false
        tab = .accounts
        if !model.isDemo { adding = true }
    }
}

struct AccountsPane: View {
    var model: AppModel
    @Binding var adding: Bool
    @State private var saved: [AccountDescriptor] = []
    @State private var detected: [(id: String, name: String, accounts: Int)] = []
    @State private var selection: String?
    @State private var errorText: String?
    @State private var confirmingRemoval = false

    private static var sections: [String] { AccountItem.sectionTitles }

    private var items: [AccountItem] {
        var out: [AccountItem] = []
        out += model.subscriptionConnections.map {
            AccountItem(id: "sub:\($0.id)", providerID: $0.kind == .claudeStatusLine ? "claude" : "codex",
                        title: $0.label, kind: .subscription($0))
        }
        out += saved.map {
            AccountItem(id: "key:\($0.id)", providerID: $0.account.providerID,
                        title: $0.account.label ?? model.providerName($0.account.providerID), kind: .saved($0))
        }
        out += model.profiles.map {
            AccountItem(id: "profile:\($0.id)", providerID: $0.providerID, title: $0.label, kind: .profile($0))
        }
        out += detected.filter { $0.accounts > 0 }.map {
            AccountItem(id: "local:\($0.id)", providerID: $0.id, title: L("Signed-in CLI", "Pålogget CLI"),
                        kind: .detected(accounts: $0.accounts))
        }
        return out
    }

    private var selected: AccountItem? { items.first { $0.id == selection } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(Self.sections, id: \.self) { section in
                        let rows = items.filter { $0.section == section }
                        if !rows.isEmpty {
                            Section(section) {
                                ForEach(rows) { item in
                                    AccountListRow(
                                        providerID: item.providerID,
                                        name: model.providerName(item.providerID),
                                        title: item.title,
                                        isExperimental: model.isExperimentalProvider(item.providerID))
                                        .tag(item.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                Divider()
                HStack(spacing: 0) {
                    Button { adding = true } label: {
                        Image(systemName: "plus").frame(width: 24, height: 22)
                    }
                    .disabled(model.isDemo)
                    .help(L("Add Account", "Legg til konto"))
                    Divider().frame(height: 16)
                    Button { confirmingRemoval = true } label: {
                        Image(systemName: "minus").frame(width: 24, height: 22)
                    }
                    .disabled(selected?.isRemovable != true)
                    .help(L("Remove Account", "Fjern konto"))
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 4)
            }
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .frame(width: 220)

            Group {
                if let selected {
                    AccountDetail(model: model, item: selected, onChange: reloadSoon)
                        .id(selected.id)
                } else {
                    ContentUnavailableView {
                        Label(model.isDemo ? L("Demo Data", "Demodata") : L("No Accounts", "Ingen kontoer"), systemImage: "person.crop.circle")
                    } description: {
                        Text(model.isDemo ? L("Accounts can't be edited while demo data is shown.", "Kontoer kan ikke endres mens demodata vises.")
                             : L("Add a subscription or API key to track what you have left.", "Legg til et abonnement eller en API-nøkkel for å følge med på hva du har igjen."))
                    } actions: {
                        if !model.isDemo {
                            Button(L("Add Account…", "Legg til konto…")) { adding = true }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(20)
        .frame(width: 680, height: 440)
        .overlay(alignment: .bottomTrailing) {
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .task { await reload() }
        .sheet(isPresented: $adding, onDismiss: reloadSoon) {
            AddAccountSheet(model: model) { adding = false }
        }
        .alert(L("Remove “\(selected?.title ?? "")”?", "Fjerne «\(selected?.title ?? "")»?"), isPresented: $confirmingRemoval) {
            Button(L("Cancel", "Avbryt"), role: .cancel) {}
            Button(L("Remove", "Fjern"), role: .destructive, action: remove)
        } message: {
            Text(selected?.removalMessage ?? "")
        }
    }

    private func remove() {
        guard let item = selected else { return }
        do {
            switch item.kind {
            case .subscription(let connection): try model.removeSubscriptionConnection(connection)
            case .saved(let account): try model.removeAccount(account)
            case .profile(let profile): try model.removeProfile(id: profile.id)
            case .detected: return
            }
            errorText = nil
            selection = nil
            reloadSoon()
        } catch {
            errorText = (error as? ProviderError)?.userMessage ?? L("The account could not be removed.", "Kontoen kunne ikke fjernes.")
        }
    }

    private func reloadSoon() { Task { await reload() } }

    private func reload() async {
        guard !model.isDemo else { return }
        do { saved = try await model.savedAccounts() }
        catch { errorText = (error as? ProviderError)?.userMessage ?? error.localizedDescription }
        detected = await model.detectedLocalProviders()
        if selected == nil { selection = items.first?.id }
    }
}

/// Everything OpenQuota tracks, flattened for the sidebar.
struct AccountItem: Identifiable {
    enum Kind {
        case subscription(SubscriptionConnection)
        case saved(AccountDescriptor)
        case profile(LocalAccountProfile)
        case detected(accounts: Int)
    }

    var id: String
    var providerID: String
    var title: String
    var kind: Kind

    static var sectionTitles: [String] {
        [L("Subscriptions", "Abonnementer"), L("API Keys & Sessions", "API-nøkler og økter"),
         L("Local Profiles", "Lokale profiler"), L("Detected on This Mac", "Funnet på denne Macen")]
    }

    var section: String {
        switch kind {
        case .subscription: Self.sectionTitles[0]
        case .saved: Self.sectionTitles[1]
        case .profile: Self.sectionTitles[2]
        case .detected: Self.sectionTitles[3]
        }
    }

    var isRemovable: Bool {
        if case .detected = kind { return false }
        return true
    }

    var removalMessage: String {
        switch kind {
        case .subscription(let connection) where connection.kind == .codexAppServer:
            L("Codex keeps its sign-in files in the account's private home.", "Codex beholder påloggingsfilene i kontoens private mappe.")
        case .subscription:
            L("Your Claude status line is restored if it hasn't changed since connecting.", "Claude-statuslinjen gjenopprettes hvis den ikke er endret siden tilkoblingen.")
        case .profile:
            L("The credential file stays where it is.", "Påloggingsfilen blir liggende der den er.")
        default:
            L("The key is deleted from OpenQuota. Your provider account is unaffected.", "Nøkkelen slettes fra OpenQuota. Kontoen hos leverandøren påvirkes ikke.")
        }
    }
}

struct AccountListRow: View {
    var providerID: String
    var name: String
    var title: String
    var isExperimental = false

    var body: some View {
        HStack(spacing: 8) {
            ProviderGlyph(providerID: providerID, name: name, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).help(name)
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .truncationMode(.middle).help(title)
                if isExperimental { ExperimentalBadge() }
            }
        }
        .padding(.vertical, 2)
    }
}

struct ExperimentalBadge: View {
    var body: some View {
        Text(L("Experimental", "Eksperimentell"))
            .font(.system(size: 9, weight: .medium))
            .fixedSize()
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.045), in: Capsule())
    }
}

struct AccountDetail: View {
    var model: AppModel
    var item: AccountItem
    var onChange: () -> Void
    @State private var label = ""
    @State private var errorText: String?
    @State private var replacingAccount: AccountDescriptor?

    private var snapshot: UsageSnapshot? {
        switch item.kind {
        case .saved(let account): model.snapshots.first { $0.account.id == account.id }
        default: model.snapshots.first { $0.providerID == item.providerID && $0.account.label == item.title }
        }
    }

    private var isExperimental: Bool {
        model.isExperimentalProvider(item.providerID)
    }

    private var localRecoveryNote: String? {
        let name = model.providerName(item.providerID)
        let rejected = snapshot?.errorMessage == ProviderError.unauthorized.userMessage
        switch item.kind {
        case .profile(let profile):
            let expandedPath = (profile.credentialPath as NSString).expandingTildeInPath
            if !FileManager.default.fileExists(atPath: expandedPath) {
                return L(
                    "Credential file is missing. Sign in again in the \(name) CLI, then Refresh.",
                    "Påloggingsfilen mangler. Logg inn på nytt i \(name)-CLI-en, og oppdater deretter.")
            }
            if rejected {
                return L(
                    "The provider rejected this saved sign-in. Sign in again in the \(name) CLI, then Refresh.",
                    "Leverandøren avviste denne påloggingen. Logg inn på nytt i \(name)-CLI-en, og oppdater deretter.")
            }
            return L(
                "Sign in again in the \(name) CLI if needed, then Refresh. Credential file: \(profile.credentialPath)",
                "Logg inn på nytt i \(name)-CLI-en ved behov, og oppdater deretter. Påloggingsfil: \(profile.credentialPath)")
        case .detected:
            if rejected {
                return L(
                    "The provider rejected this local sign-in. Sign in again in the \(name) CLI, then Refresh.",
                    "Leverandøren avviste denne lokale påloggingen. Logg inn på nytt i \(name)-CLI-en, og oppdater deretter.")
            }
            return L(
                "If this local sign-in is rejected, sign in again in the \(name) CLI, then Refresh.",
                "Hvis denne lokale påloggingen avvises, logg inn på nytt i \(name)-CLI-en, og oppdater deretter.")
        default:
            return nil
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Provider", "Leverandør")) {
                    HStack(spacing: 6) {
                        ProviderGlyph(providerID: item.providerID, name: model.providerName(item.providerID), size: 20)
                        Text(model.providerName(item.providerID))
                        if isExperimental { ExperimentalBadge() }
                    }
                }
                if case .saved(let account) = item.kind {
                    TextField(L("Label", "Navn"), text: $label)
                        .onSubmit { rename(account) }
                        .disabled(model.codexLoginBusy)
                } else {
                    LabeledContent(L("Label", "Navn"), value: item.title)
                }
                LabeledContent(L("Source", "Kilde"), value: source)
                if let plan = snapshot?.account.plan {
                    LabeledContent(L("Plan", "Plan"), value: plan.capitalized)
                }
            }
            if let snapshot, !snapshot.windows.isEmpty || snapshot.errorMessage != nil {
                Section(L("Usage", "Bruk")) {
                    ForEach(snapshot.windows) { window in
                        WindowRow(window: window).font(.callout)
                    }
                    if let error = snapshot.errorMessage {
                        Text(providerError(error, providerID: snapshot.providerID)).foregroundStyle(.orange)
                    }
                }
            }
            if let snapshot {
                Section(L("Freshness", "Oppdatering")) {
                    if let successfulAt = snapshot.lastSuccessfulAt {
                        LabeledContent(L("Last successful reading", "Siste vellykkede måling")) {
                            Text(timestamp(successfulAt))
                        }
                        if snapshot.isStale {
                            Text(L("Saved reading", "Lagret måling"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        LabeledContent(L("Last successful reading", "Siste vellykkede måling")) {
                            Text(L("No successful reading yet", "Ingen vellykket måling ennå"))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if snapshot.errorMessage != nil, let attemptedAt = snapshot.lastAttemptedAt {
                        LabeledContent(L("Last attempt", "Siste forsøk")) {
                            Text(timestamp(attemptedAt))
                        }
                    }
                }
            }
            if let note {
                Section { Text(note).foregroundStyle(.secondary) }
            }
            if let sourceNote = model.sourceNote(item.providerID) {
                Section(L("Data source", "Datakilde")) {
                    Text(sourceNote).foregroundStyle(.secondary)
                }
            }
            if let recovery = localRecoveryNote {
                Section(L("Sign-in", "Pålogging")) {
                    Text(recovery).foregroundStyle(.secondary)
                    Button(L("Refresh", "Oppdater")) { model.refreshNow() }
                        .disabled(model.refreshing || model.isDemo)
                }
            }
            if case .saved(let account) = item.kind {
                Section(L("Credential", "Påloggingsinformasjon")) {
                    Button(L("Replace Credential…", "Bytt påloggingsinformasjon…")) {
                        replacingAccount = account
                    }
                    .disabled(model.isDemo || model.codexLoginBusy)
                }
            }
            if case .subscription(let connection) = item.kind {
                switch connection.kind {
                case .codexAppServer:
                    Section(L("Codex sign-in", "Codex-pålogging")) {
                        if let status = model.codexLoginStatus {
                            Text(status).foregroundStyle(model.codexLoginBusy ? Color.secondary : .orange)
                        }
                        if model.codexLoginBusy {
                            HStack {
                                ProgressView().controlSize(.small)
                                Spacer()
                                Button(L("Cancel", "Avbryt")) { model.cancelCodexLogin() }
                            }
                        } else {
                            Button(L("Reconnect with ChatGPT…", "Koble til ChatGPT på nytt…")) {
                                model.startCodexLogin(
                                    label: connection.label,
                                    executablePath: nil,
                                    existingConnection: connection,
                                    openAuthURL: { url in NSWorkspace.shared.open(url) })
                            }
                            .disabled(model.isDemo)
                        }
                    }
                case .claudeStatusLine:
                    Section(L("Claude Code", "Claude Code")) {
                        Text(L(
                            "OpenQuota reads the installed status line after Claude Code writes a new reading. Use Claude Code, then Refresh; no separate token can be reconnected here.",
                            "OpenQuota leser den installerte statuslinjen etter at Claude Code skriver en ny måling. Bruk Claude Code, og oppdater deretter; ingen separat nøkkel kan kobles til på nytt her."))
                            .foregroundStyle(.secondary)
                        Button(L("Refresh", "Oppdater")) { model.refreshNow() }
                            .disabled(model.refreshing || model.isDemo)
                    }
                }
            }
            if let url = model.dashboardURL(item.providerID) {
                Section {
                    Link(L("Open Usage Page", "Åpne bruksside"), destination: url)
                }
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear { label = item.title }
        .sheet(item: $replacingAccount) { account in
            ReplaceCredentialSheet(model: model, account: account) {
                replacingAccount = nil
                onChange()
            }
        }
    }

    private var source: String {
        if let credentialSource = snapshot?.credentialSource {
            return model.credentialSourceName(credentialSource)
        }
        return switch item.kind {
        case .subscription(let connection):
            connection.kind == .claudeStatusLine ? L("Claude Code status line", "Claude Code-statuslinje") : L("Codex sign-in", "Codex-pålogging")
        case .saved(let account):
            account.account.providerID == "cursor" ? L("Session token in Keychain", "Øktnøkkel i nøkkelringen") : L("API key in Keychain", "API-nøkkel i nøkkelringen")
        case .profile: L("Local provider file", "Lokal leverandørfil")
        case .detected: L("Detected local credential", "Funnet lokal pålogging")
        }
    }

    private var note: String? {
        return switch item.kind {
        case .saved(let account) where account.account.providerID == "cursor":
            L("Experimental: unofficial endpoints and a sensitive session token. Replacement must be for the same Cursor account. No automatic renewal or browser import.",
              "Eksperimentell: uoffisielle endepunkter og en sensitiv øktnøkkel. Erstatningen må tilhøre samme Cursor-konto. Ingen automatisk fornyelse eller nettleserimport.")
        case .subscription(let connection) where connection.kind == .claudeStatusLine:
            L("Updates while you use Claude Code. \(connection.directory)", "Oppdateres mens du bruker Claude Code. \(connection.directory)")
        case .profile(let profile) where profile.providerID == "claude" || profile.providerID == "codex":
            L("This older profile is no longer used. Remove it and connect the account again.", "Denne eldre profilen brukes ikke lenger. Fjern den og koble til kontoen på nytt.")
        case .profile(let profile): profile.credentialPath
        case .saved(let account) where account.account.providerID == "mistral":
            L("Mistral shows 30-day workspace activity, not a personal allowance.", "Mistral viser aktivitet i arbeidsområdet siste 30 dager, ikke en personlig kvote.")
        case .saved(let account) where account.account.providerID == "requesty":
            L("Balance is shared by every key in the organization.", "Saldoen deles av alle nøklene i organisasjonen.")
        case .saved(let account) where model.isExperimentalProvider(account.account.providerID):
            L("Experimental integration. Provider-specific readings have not been independently verified.",
              "Eksperimentell integrasjon. Leverandørspesifikke målinger er ikke bekreftet uavhengig.")
        default: nil
        }
    }

    private func timestamp(_ date: Date) -> String {
        date.formatted(
            .dateTime.year().month(.abbreviated).day().hour().minute()
                .locale(Localized.appLocale))
    }

    private func rename(_ account: AccountDescriptor) {
        do {
            try model.renameAccount(account, label: label)
            errorText = nil
            onChange()
        } catch {
            errorText = (error as? ProviderError)?.userMessage ?? L("The label could not be saved.", "Navnet kunne ikke lagres.")
        }
    }
}

private struct ReplaceCredentialSheet: View {
    @Environment(\.dismiss) private var dismiss
    var model: AppModel
    var account: AccountDescriptor
    var onSaved: () -> Void
    @State private var secret = ""
    @State private var cursorConsent = false
    @State private var saving = false
    @State private var errorText: String?

    private var isCursor: Bool { account.account.providerID == "cursor" }
    private var canSave: Bool {
        !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (!isCursor || cursorConsent)
            && !saving
            && !model.codexLoginBusy
            && !model.isDemo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Replace credential", "Bytt påloggingsinformasjon"))
                .font(.title2.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                GridRow {
                    Text(L("Provider", "Leverandør")).foregroundStyle(.secondary)
                    Text(model.providerName(account.account.providerID))
                }
                GridRow {
                    Text(L("Account", "Konto")).foregroundStyle(.secondary)
                    Text(account.account.label ?? L("Default", "Standard"))
                }
                GridRow {
                    Text(L("New credential", "Ny påloggingsinformasjon")).foregroundStyle(.secondary)
                    SecureField(
                        isCursor ? "userID::token" : L("Paste a new API key", "Lim inn en ny API-nøkkel"),
                        text: $secret)
                        .textFieldStyle(.roundedBorder)
                        .disabled(saving || model.codexLoginBusy)
                }
            }
            Text(isCursor
                 ? L("The new session must resolve to the same Cursor account. The existing session is checked locally; no browser import or automatic renewal is used.",
                     "Den nye økten må tilhøre samme Cursor-konto. Den eksisterende økten kontrolleres lokalt; ingen nettleserimport eller automatisk fornyelse brukes.")
                 : L("Use a key from the same account or workspace. Generic provider keys cannot be matched to an account offline.",
                     "Bruk en nøkkel fra samme konto eller arbeidsområde. Generiske leverandørnøkler kan ikke knyttes til en konto uten nettforbindelse."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if isCursor {
                Toggle(
                    L("I understand this uses an unofficial Cursor session endpoint.", "Jeg forstår at dette bruker et uoffisielt Cursor-øktendepunkt."),
                    isOn: $cursorConsent)
                    .disabled(saving || model.codexLoginBusy)
                Text(L("Experimental integration. Keep this session private; credentials are never shown again.",
                       "Eksperimentell integrasjon. Hold denne økten privat; påloggingsinformasjonen vises ikke igjen."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorText {
                Text(errorText)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(L("Cancel", "Avbryt")) { dismiss() }
                    .disabled(saving)
                Button(L("Save", "Lagre"), action: save)
                    .buttonStyle(.glassProminent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 480)
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        guard canSave else { return }
        saving = true
        errorText = nil
        Task {
            do {
                try await model.replaceCredential(secret, for: account)
                secret = ""
                saving = false
                onSaved()
            } catch {
                errorText = replacementError(error)
                saving = false
            }
        }
    }

    private func replacementError(_ error: Error) -> String {
        guard let error = error as? ProviderError else {
            return L("The credential could not be saved. Check it and try again.",
                     "Påloggingsinformasjonen kunne ikke lagres. Kontroller den og prøv igjen.")
        }
        switch error {
        case .badResponse(_):
            return error.userMessage
        case .notLoggedIn:
            return isCursor
                ? L("The existing session could not be verified. Remove this entry and add the account again.",
                    "Den eksisterende økten kunne ikke bekreftes. Fjern oppføringen og legg til kontoen på nytt.")
                : L("This saved account could not be found. Refresh Settings and try again.",
                    "Fant ikke denne lagrede kontoen. Oppdater Innstillinger og prøv igjen.")
        default:
            return L("The credential could not be saved. Check it and try again.",
                     "Påloggingsinformasjonen kunne ikke lagres. Kontroller den og prøv igjen.")
        }
    }
}

struct GeneralPane: View {
    var model: AppModel
    @State private var automaticallyChecks = UpdateController.shared.automaticallyChecks
    @AppStorage("menuBarShowsPercent") private var menuBarShowsPercent = true
    @AppStorage("menuBarDisplayStyle") private var storedStyle = ""
    @AppStorage("menuBarAccountID") private var accountID = ""
    @AppStorage("menuBarWindowID") private var windowID = ""

    private var selectedSnapshot: UsageSnapshot? {
        model.snapshots.first { $0.account.id == accountID }
    }

    private var displayStyle: Binding<String> {
        Binding(
            get: { MenuBarDisplayStyle.resolve(storedStyle, legacyShowsPercent: menuBarShowsPercent).rawValue },
            set: { storedStyle = $0 })
    }

    var body: some View {
        Form {
            Section {
                Picker(L("Display", "Visning"), selection: displayStyle) {
                    ForEach(MenuBarDisplayStyle.allCases, id: \.rawValue) { style in
                        Text(style.title).tag(style.rawValue)
                    }
                }
                Picker(L("Reading", "Avlesning"), selection: $accountID) {
                    Text(L("Lowest across all accounts", "Lavest blant alle kontoer")).tag("")
                    ForEach(model.snapshots, id: \.account.id) { snapshot in
                        Text(accountTitle(snapshot)).tag(snapshot.account.id)
                    }
                    if !accountID.isEmpty && selectedSnapshot == nil {
                        Text(L("Selected account unavailable", "Valgt konto er utilgjengelig")).tag(accountID)
                    }
                }
                .onChange(of: accountID) { _, _ in windowID = "" }
                if !accountID.isEmpty {
                    Picker(L("Window", "Periode"), selection: $windowID) {
                        Text(L("Lowest for this account", "Lavest for denne kontoen")).tag("")
                        ForEach(selectedSnapshot?.windows ?? []) { window in
                            Text(Localized.windowLabel(window.label)).tag(window.id)
                        }
                        if !windowID.isEmpty && selectedSnapshot?.windows.contains(where: { $0.id == windowID }) != true {
                            Text(L("Selected window unavailable", "Valgt periode er utilgjengelig")).tag(windowID)
                        }
                    }
                }
            } header: {
                Text(L("Menu Bar", "Menylinje"))
            } footer: {
                Text(L("Percentages show remaining allowance, not a combined balance. Hover over the menu-bar item for its source. Cached readings are dimmed; missing percentages show —.",
                       "Prosent viser gjenværende kvote, ikke en samlet saldo. Hold pekeren over menylinjeikonet for å se kilden. Bufrede avlesninger dempes; manglende prosent vises som —."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle(SpendCopy.settingsToggle, isOn: Binding(
                    get: { model.spendEnabled }, set: { model.setSpendEnabled($0) }))
                    .disabled(model.isDemo)
            } header: {
                Text(SpendCopy.title)
            } footer: {
                Text(SpendCopy.settingsFooter)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Updates", "Oppdateringer")) {
                Toggle(L("Check for updates automatically", "Se etter oppdateringer automatisk"), isOn: $automaticallyChecks)
                    .onChange(of: automaticallyChecks) { _, value in
                        UpdateController.shared.automaticallyChecks = value
                    }
                LabeledContent(L("Version", "Versjon") + " " + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("Development", "Utvikling"))) {
                    Button(L("Check Now", "Se etter nå")) { UpdateController.shared.checkForUpdates() }
                        .disabled(!UpdateController.shared.canCheckForUpdates)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func accountTitle(_ snapshot: UsageSnapshot) -> String {
        let provider = model.providerName(snapshot.providerID)
        let label = snapshot.account.label ?? L("Default", "Standard")
        let duplicates = model.snapshots.filter {
            $0.providerID == snapshot.providerID && $0.account.label == snapshot.account.label
        }.count > 1
        return "\(provider) · \(label)" + (duplicates ? " · \(snapshot.account.id.suffix(8))" : "")
    }
}
#endif
