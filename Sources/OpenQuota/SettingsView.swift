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
                                    AccountListRow(providerID: item.providerID,
                                                   name: model.providerName(item.providerID), title: item.title)
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

    var body: some View {
        HStack(spacing: 8) {
            ProviderGlyph(providerID: providerID, name: name, size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct AccountDetail: View {
    var model: AppModel
    var item: AccountItem
    var onChange: () -> Void
    @State private var label = ""
    @State private var errorText: String?

    private var snapshot: UsageSnapshot? {
        switch item.kind {
        case .saved(let account): model.snapshots.first { $0.account.id == account.id }
        default: model.snapshots.first { $0.providerID == item.providerID && $0.account.label == item.title }
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("Provider", "Leverandør")) {
                    HStack(spacing: 6) {
                        ProviderGlyph(providerID: item.providerID, name: model.providerName(item.providerID), size: 20)
                        Text(model.providerName(item.providerID))
                    }
                }
                if case .saved(let account) = item.kind {
                    TextField(L("Label", "Navn"), text: $label)
                        .onSubmit { rename(account) }
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
            if let note {
                Section { Text(note).foregroundStyle(.secondary) }
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
    }

    private var source: String {
        switch item.kind {
        case .subscription(let connection):
            connection.kind == .claudeStatusLine ? L("Claude Code status line", "Claude Code-statuslinje") : L("Codex sign-in", "Codex-pålogging")
        case .saved(let account):
            account.account.providerID == "cursor" ? L("Session token in Keychain", "Øktnøkkel i nøkkelringen") : L("API key in Keychain", "API-nøkkel i nøkkelringen")
        case .profile: L("Credential file", "Påloggingsfil")
        case .detected: L("Provider CLI on this Mac", "Leverandørens CLI på denne Macen")
        }
    }

    private var note: String? {
        switch item.kind {
        case .subscription(let connection) where connection.kind == .claudeStatusLine:
            L("Updates while you use Claude Code. \(connection.directory)", "Oppdateres mens du bruker Claude Code. \(connection.directory)")
        case .profile(let profile) where profile.providerID == "claude" || profile.providerID == "codex":
            L("This older profile is no longer used. Remove it and connect the account again.", "Denne eldre profilen brukes ikke lenger. Fjern den og koble til kontoen på nytt.")
        case .profile(let profile): profile.credentialPath
        case .saved(let account) where account.account.providerID == "mistral":
            L("Mistral shows 30-day workspace activity, not a personal allowance.", "Mistral viser aktivitet i arbeidsområdet siste 30 dager, ikke en personlig kvote.")
        case .saved(let account) where account.account.providerID == "requesty":
            L("Balance is shared by every key in the organization.", "Saldoen deles av alle nøklene i organisasjonen.")
        case .saved(let account) where model.specProviders().first { $0.id == account.account.providerID }?.unverified == true:
            L("Experimental integration. Readings have not been verified against a live account.", "Eksperimentell integrasjon. Målingene er ikke bekreftet mot en ekte konto.")
        default: nil
        }
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

struct GeneralPane: View {
    var model: AppModel
    @State private var automaticallyChecks = UpdateController.shared.automaticallyChecks
    @AppStorage("menuBarShowsPercent") private var menuBarShowsPercent = true

    var body: some View {
        Form {
            Section(L("Menu Bar", "Menylinje")) {
                Toggle(L("Show percentage next to the gauge", "Vis prosent ved siden av måleren"), isOn: $menuBarShowsPercent)
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
}
#endif
