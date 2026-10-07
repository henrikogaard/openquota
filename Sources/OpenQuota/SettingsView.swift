#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// Settings, laid out like Mail's Accounts pane: a list of accounts on the
/// left, the selected account on the right, and +/− beneath the list.
struct SettingsView: View {
    var model: AppModel

    var body: some View {
        TabView {
            AccountsPane(model: model)
                .tabItem { Label("Accounts", systemImage: "at") }
            GeneralPane()
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 640, height: 440)
    }
}

/// Everything OpenQuota tracks, flattened for the list.
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
}

struct AccountsPane: View {
    var model: AppModel
    @State private var saved: [AccountDescriptor] = []
    @State private var detected: [(id: String, name: String, accounts: Int)] = []
    @State private var selection: String?
    @State private var adding = false
    @State private var confirmingRemoval = false
    @State private var errorText: String?

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
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(["Subscriptions", "API Keys & Sessions", "Local Profiles", "Detected on This Mac"],
                            id: \.self) { section in
                        let rows = items.filter { $0.section == section }
                        if !rows.isEmpty {
                            Section(section) {
                                ForEach(rows) { item in
                                    AccountListRow(name: model.providerName(item.providerID), title: item.title)
                                        .tag(item.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .overlay {
                    if items.isEmpty {
                        Text("No Accounts").foregroundStyle(.secondary)
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button { adding = true } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Add Account")
                    Divider().frame(height: 14)
                    Button { confirmingRemoval = true } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(!canRemove)
                    .help("Remove Account")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 220)
            Divider()
            Group {
                if let selected {
                    AccountDetail(model: model, item: selected, onChange: reloadSoon)
                        .id(selected.id)
                } else {
                    ContentUnavailableView {
                        Label("No Account Selected", systemImage: "person.crop.circle")
                    } actions: {
                        Button("Add Account…") { adding = true }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .disabled(model.isDemo)
        .overlay(alignment: .bottom) {
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red).padding(8)
            }
        }
        .task { await reload() }
        .sheet(isPresented: $adding, onDismiss: reloadSoon) {
            AddAccountSheet(model: model) { adding = false }
        }
        .alert("Remove “\(selected?.title ?? "")”?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive, action: removeSelected)
        } message: {
            Text(removalMessage)
        }
    }

    private var canRemove: Bool {
        guard let selected else { return false }
        if case .detected = selected.kind { return false }
        return true
    }

    private var removalMessage: String {
        switch selected?.kind {
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

    private func removeSelected() {
        guard let selected else { return }
        do {
            switch selected.kind {
            case .subscription(let connection): try model.removeSubscriptionConnection(connection)
            case .saved(let account): try model.removeAccount(account)
            case .profile(let profile): try model.removeProfile(id: profile.id)
            case .detected: return
            }
            selection = nil
            errorText = nil
            reloadSoon()
        } catch {
            errorText = (error as? ProviderError)?.userMessage ?? "The account could not be removed."
        }
    }

    private func reloadSoon() { Task { await reload() } }

    private func reload() async {
        do { saved = try await model.savedAccounts() }
        catch { errorText = (error as? ProviderError)?.userMessage ?? error.localizedDescription }
        detected = await model.detectedLocalProviders()
    }
}

struct AccountListRow: View {
    var name: String
    var title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
                LabeledContent("Provider", value: model.providerName(item.providerID))
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
    @State private var automaticallyChecks = UpdateController.shared.automaticallyChecks

    var body: some View {
        Form {
            Section("Updates") {
                Toggle("Check for updates automatically", isOn: $automaticallyChecks)
                    .onChange(of: automaticallyChecks) { _, value in
                        UpdateController.shared.automaticallyChecks = value
                    }
                LabeledContent("Version", value: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                HStack {
                    Spacer()
                    Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
                        .disabled(!UpdateController.shared.canCheckForUpdates)
                }
            }
            Section {
                Link("OpenQuota on GitHub", destination: URL(string: "https://github.com/henrikogaard/openquota")!)
            }
        }
        .formStyle(.grouped)
    }
}
#endif
