#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// Settings, laid out like System Settings: a Liquid Glass sidebar with
/// General and every tracked account, the selection's form on the right.
struct SettingsView: View {
    var model: AppModel
    @State private var saved: [AccountDescriptor] = []
    @State private var detected: [(id: String, name: String, accounts: Int)] = []
    @State private var selection: String? = "general"
    @State private var adding = false
    @State private var errorText: String?

    private static let sections = ["Subscriptions", "API Keys & Sessions", "Local Profiles", "Detected on This Mac"]

    private var items: [AccountItem] {
        var out: [AccountItem] = []
        out += model.subscriptionConnections.map {
            AccountItem(id: "sub:\($0.id)", providerID: $0.kind == .claudeStatusLine ? "claude" : "codex",
                        title: $0.label, kind: .subscription($0))
        }
        out += saved.map {
            AccountItem(id: "key:\($0.id)", providerID: $0.account.providerID,
                        title: $0.account.label ?? "Unlabelled", kind: .saved($0))
        }
        out += model.profiles.map {
            AccountItem(id: "profile:\($0.id)", providerID: $0.providerID, title: $0.label, kind: .profile($0))
        }
        out += detected.filter { $0.accounts > 0 }.map {
            AccountItem(id: "local:\($0.id)", providerID: $0.id, title: "Signed-in CLI",
                        kind: .detected(accounts: $0.accounts))
        }
        return out
    }

    private var selected: AccountItem? { items.first { $0.id == selection } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Label("General", systemImage: "gearshape").tag("general")
                if model.isDemo {
                    Section("Accounts") {
                        Text("Unavailable with demo data").foregroundStyle(.secondary)
                    }
                }
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
            .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            Group {
                if selection == "general" {
                    GeneralPane(model: model)
                } else if let selected {
                    AccountDetail(model: model, item: selected, onChange: reloadSoon,
                                  onRemoved: { selection = "general" })
                        .id(selected.id)
                } else {
                    ContentUnavailableView {
                        Label("No Account Selected", systemImage: "person.crop.circle")
                    } actions: {
                        Button("Add Account…") { adding = true }
                            .buttonStyle(.glassProminent)
                            .disabled(model.isDemo)
                    }
                }
            }
            .navigationTitle(selection == "general" ? "General" : model.providerName(selected?.providerID ?? ""))
        }
        .toolbar(removing: .sidebarToggle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { adding = true } label: {
                    Label("Add Account", systemImage: "plus")
                }
                .disabled(model.isDemo)
                .help("Add Account")
            }
        }
        .frame(minWidth: 680, idealWidth: 720, minHeight: 460, idealHeight: 500)
        .overlay(alignment: .bottom) {
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .task { await reload() }
        .onAppear(perform: consumeAddRequest)
        .onChange(of: model.requestsAddAccount) { _, _ in consumeAddRequest() }
        .sheet(isPresented: $adding, onDismiss: reloadSoon) {
            AddAccountSheet(model: model) { adding = false }
        }
    }

    private func consumeAddRequest() {
        guard model.requestsAddAccount else { return }
        model.requestsAddAccount = false
        if !model.isDemo { adding = true }
    }

    private func reloadSoon() { Task { await reload() } }

    private func reload() async {
        guard !model.isDemo else { return }
        do { saved = try await model.savedAccounts() }
        catch { errorText = (error as? ProviderError)?.userMessage ?? error.localizedDescription }
        detected = await model.detectedLocalProviders()
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

    var section: String {
        switch kind {
        case .subscription: "Subscriptions"
        case .saved: "API Keys & Sessions"
        case .profile: "Local Profiles"
        case .detected: "Detected on This Mac"
        }
    }

    var isRemovable: Bool {
        if case .detected = kind { return false }
        return true
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
    var onRemoved: () -> Void
    @State private var label = ""
    @State private var errorText: String?
    @State private var confirmingRemoval = false

    private var snapshot: UsageSnapshot? {
        switch item.kind {
        case .saved(let account): model.snapshots.first { $0.account.id == account.id }
        default: model.snapshots.first { $0.providerID == item.providerID && $0.account.label == item.title }
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Provider") {
                    HStack(spacing: 6) {
                        ProviderGlyph(providerID: item.providerID, name: model.providerName(item.providerID), size: 20)
                        Text(model.providerName(item.providerID))
                    }
                }
                if case .saved(let account) = item.kind {
                    TextField("Label", text: $label)
                        .onSubmit { rename(account) }
                } else {
                    LabeledContent("Label", value: item.title)
                }
                LabeledContent("Source", value: source)
                if let plan = snapshot?.account.plan {
                    LabeledContent("Plan", value: plan.capitalized)
                }
            }
            if let snapshot, !snapshot.windows.isEmpty || snapshot.errorMessage != nil {
                Section("Usage") {
                    ForEach(snapshot.windows) { window in
                        WindowRow(window: window).font(.callout)
                    }
                    if let error = snapshot.errorMessage {
                        Text(error).foregroundStyle(.orange)
                    }
                }
            }
            if let note {
                Section { Text(note).foregroundStyle(.secondary) }
            }
            if let url = model.dashboardURL(item.providerID) {
                Section {
                    Link("Open Usage Page", destination: url)
                }
            }
            if item.isRemovable {
                Section {
                    Button("Remove Account…", role: .destructive) { confirmingRemoval = true }
                }
            }
            if let errorText {
                Text(errorText).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onAppear { label = item.title }
        .alert("Remove “\(item.title)”?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text(removalMessage)
        }
    }

    private var removalMessage: String {
        switch item.kind {
        case .subscription(let connection) where connection.kind == .codexAppServer:
            "Codex keeps its sign-in files in the account's private home."
        case .subscription:
            "Your Claude status line is restored if it hasn't changed since connecting."
        case .profile:
            "The credential file stays where it is."
        default:
            "The key is deleted from OpenQuota. Your provider account is unaffected."
        }
    }

    private func remove() {
        do {
            switch item.kind {
            case .subscription(let connection): try model.removeSubscriptionConnection(connection)
            case .saved(let account): try model.removeAccount(account)
            case .profile(let profile): try model.removeProfile(id: profile.id)
            case .detected: return
            }
            onChange()
            onRemoved()
        } catch {
            errorText = (error as? ProviderError)?.userMessage ?? "The account could not be removed."
        }
    }

    private var source: String {
        switch item.kind {
        case .subscription(let connection):
            connection.kind == .claudeStatusLine ? "Claude Code status line" : "Codex sign-in"
        case .saved(let account):
            account.account.providerID == "cursor" ? "Session token in Keychain" : "API key in Keychain"
        case .profile: "Credential file"
        case .detected: "Provider CLI on this Mac"
        }
    }

    private var note: String? {
        switch item.kind {
        case .subscription(let connection) where connection.kind == .claudeStatusLine:
            "Updates while you use Claude Code. \(connection.directory)"
        case .profile(let profile) where profile.providerID == "claude" || profile.providerID == "codex":
            "This older profile is no longer used. Remove it and connect the account again."
        case .profile(let profile): profile.credentialPath
        case .saved(let account) where account.account.providerID == "mistral":
            "Mistral shows 30-day workspace activity, not a personal allowance."
        case .saved(let account) where account.account.providerID == "requesty":
            "Balance is shared by every key in the organization."
        case .saved(let account) where model.specProviders().first { $0.id == account.account.providerID }?.unverified == true:
            "Experimental integration. Readings have not been verified against a live account."
        default: nil
        }
    }

    private func rename(_ account: AccountDescriptor) {
        do {
            try model.renameAccount(account, label: label)
            errorText = nil
            onChange()
        } catch {
            errorText = (error as? ProviderError)?.userMessage ?? "The label could not be saved."
        }
    }
}

struct GeneralPane: View {
    var model: AppModel
    @State private var automaticallyChecks = UpdateController.shared.automaticallyChecks
    @AppStorage("menuBarShowsPercent") private var menuBarShowsPercent = true

    var body: some View {
        Form {
            Section("Menu Bar") {
                Toggle("Show percentage next to the gauge", isOn: $menuBarShowsPercent)
            }
            Section(SpendCopy.title) {
                Toggle(SpendCopy.enable, isOn: Binding(
                    get: { model.spendEnabled }, set: { model.setSpendEnabled($0) }))
                    .disabled(model.isDemo)
                Text(SpendCopy.privacy)
                    .font(.callout).foregroundStyle(.secondary)
                Text(SpendCopy.scope)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Check for updates automatically", isOn: $automaticallyChecks)
                    .onChange(of: automaticallyChecks) { _, value in
                        UpdateController.shared.automaticallyChecks = value
                    }
                LabeledContent("Version") {
                    HStack(spacing: 12) {
                        Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                            .foregroundStyle(.secondary)
                        Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
                            .disabled(!UpdateController.shared.canCheckForUpdates)
                    }
                }
            } header: {
                Text("Updates")
            } footer: {
                Link("OpenQuota on GitHub", destination: URL(string: "https://github.com/henrikogaard/openquota")!)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
