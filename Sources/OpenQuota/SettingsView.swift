#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

struct SettingsView: View {
    var model: AppModel
    @State private var newKey = ""
    @State private var newLabel = ""
    @State private var selectedProvider = "openrouter"
    @State private var sessionToken = ""
    @State private var sessionLabel = ""
    @State private var profileProvider = "claude"
    @State private var profileLabel = ""
    @State private var credentialPath = ""
    @State private var errorText: String?
    @State private var saved: [AccountDescriptor] = []
    @State private var detected: [(id: String, name: String, accounts: Int)] = []
    @State private var removingAccount: AccountDescriptor?
    @State private var removingProfile: LocalAccountProfile?
    @State private var renamingAccount: AccountDescriptor?
    @State private var editedLabel = ""

    private var selectedSpec: GenericProvider? {
        model.specProviders().first { $0.id == selectedProvider }
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.isDemo {
                Text("Demo data · Account changes are disabled").font(.caption).padding(8)
            }
            TabView {
                accountsTab.tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                addTab.tabItem { Label("Add Account", systemImage: "plus.circle") }
            }
            .disabled(model.isDemo)
            if let errorText {
                Text(errorText).font(.caption).foregroundStyle(.red)
                    .textSelection(.enabled).padding()
            }
        }
        .frame(width: 540, height: 580)
        .task { await reload() }
        .sheet(item: $renamingAccount) { account in
            VStack(alignment: .leading, spacing: 16) {
                Text("Account Label").font(.headline)
                TextField("Label", text: $editedLabel)
                HStack {
                    Spacer()
                    Button("Cancel") { renamingAccount = nil }.keyboardShortcut(.cancelAction)
                    Button("Save") {
                        perform { try model.renameAccount(account, label: editedLabel) }
                        renamingAccount = nil
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 320)
        }
        .alert("Remove Saved Account?", isPresented: Binding(
            get: { removingAccount != nil }, set: { if !$0 { removingAccount = nil } }
        )) {
            Button("Cancel", role: .cancel) { removingAccount = nil }
            Button("Remove", role: .destructive) {
                if let account = removingAccount {
                    perform { try model.removeAccount(account) }
                }
                removingAccount = nil
            }
        } message: {
            Text("This deletes this account's saved credential from OpenQuota. It does not delete your provider account.")
        }
        .alert("Remove Local Profile?", isPresented: Binding(
            get: { removingProfile != nil }, set: { if !$0 { removingProfile = nil } }
        )) {
            Button("Cancel", role: .cancel) { removingProfile = nil }
            Button("Remove", role: .destructive) {
                if let profile = removingProfile {
                    perform { try model.removeProfile(id: profile.id) }
                }
                removingProfile = nil
            }
        } message: {
            Text("The original credential file will not be deleted.")
        }
    }

    private var accountsTab: some View {
        Form {
            Section("Saved Keys & Sessions") {
                if saved.isEmpty {
                    Text("No saved keys. Use Add Account to connect a provider.")
                        .foregroundStyle(.secondary)
                }
                ForEach(saved) { account in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(model.providerName(account.account.providerID))
                            Text(account.account.label ?? "Unlabelled account").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Rename") {
                            editedLabel = account.account.label ?? ""
                            renamingAccount = account
                        }
                        Button("Remove", role: .destructive) { removingAccount = account }
                    }
                }
            }
            Section("Local Profiles") {
                if model.profiles.isEmpty {
                    Text("Add a separate credential file for each work or personal account.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.profiles) { profile in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(model.providerName(profile.providerID)) · \(profile.label)")
                            Text(profile.credentialPath).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle).help(profile.credentialPath)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { removingProfile = profile }
                    }
                }
            }
            Section("Detected on This Mac") {
                ForEach(detected, id: \.id) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text(item.accounts > 0 ? "\(item.accounts) account(s)" : "Not signed in")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("Default CLI credentials are detected automatically. Sign in with the provider's CLI; use Local Profiles for additional accounts. OpenQuota never imports browser cookies.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Refresh Detection") { Task { await reload(); model.refreshNow() } }
            }
        }
        .formStyle(.grouped)
    }

    private var addTab: some View {
        Form {
            Section("API Key") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(model.specProviders(), id: \.id) { provider in
                        Text(provider.unverified ? "\(provider.displayName) (experimental)" : provider.displayName)
                            .tag(provider.id)
                    }
                }
                if selectedProvider == "mistral" {
                    Text("Requires an Admin API key. Shows 30-day Vibe activity, not your personal plan's remaining allowance.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if selectedProvider == "requesty" {
                    Text("Requires a management key. Balance is organization-wide; keys in the same organization share it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                SecureField(selectedSpec?.spec.auth == .cookie ? "Session cookie" : "API key", text: $newKey)
                TextField("Label (e.g. Work)", text: $newLabel)
                Button("Add Key") {
                    guard let provider = selectedSpec else { return }
                    perform {
                        try model.addAPIKey(newKey.trimmingCharacters(in: .whitespacesAndNewlines),
                                            provider: provider, label: newLabel.isEmpty ? nil : newLabel)
                        newKey = ""; newLabel = ""
                    }
                }.disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Section("Cursor Session") {
                SecureField("userID::token", text: $sessionToken)
                TextField("Label (e.g. Personal)", text: $sessionLabel)
                Text("Paste manually from your Cursor session. Expired sessions must be replaced. Each session is stored separately in Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Add Session") {
                    perform {
                        try model.addSessionToken(sessionToken.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  label: sessionLabel.isEmpty ? nil : sessionLabel)
                        sessionToken = ""; sessionLabel = ""
                    }
                }.disabled(sessionToken.isEmpty)
            }
            Section("Local Credential Profile") {
                Picker("Provider", selection: $profileProvider) {
                    ForEach(AppModel.credentialPaths.keys.sorted(), id: \.self) { id in
                        Text(model.providerName(id)).tag(id)
                    }
                }
                TextField("Label", text: $profileLabel)
                HStack {
                    TextField("Absolute credential file path", text: $credentialPath)
                    Button("Choose…") { chooseCredential() }
                }
                Text("Select a separate CLI credential file for this account. OAuth refresh updates that file; do not share the same file between profiles.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Add Profile") {
                    perform {
                        try model.addProfile(providerID: profileProvider, label: profileLabel, path: credentialPath)
                        profileLabel = ""; credentialPath = ""
                    }
                }.disabled(profileLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || credentialPath.isEmpty)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseCredential() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { credentialPath = url.path }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorText = nil
            Task { await reload() }
        } catch {
            if error is LocalAccountProfileError {
                errorText = "Choose an existing credential file under 1 MB and enter a label (maximum 100 profiles)."
            } else {
                errorText = (error as? ProviderError)?.userMessage ?? error.localizedDescription
            }
        }
    }

    private func reload() async {
        do { saved = try await model.savedAccounts() }
        catch { errorText = (error as? ProviderError)?.userMessage ?? error.localizedDescription }
        detected = await model.detectedLocalProviders()
    }
}
#endif
