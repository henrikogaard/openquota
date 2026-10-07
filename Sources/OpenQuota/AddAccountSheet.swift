#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// Pick a provider on the left, connect it on the right.
struct AddAccountSheet: View {
    enum Target: Hashable {
        case claude, codex, cursor
        case apiKey(String)
        case profile(String)
    }

    var model: AppModel
    var onDone: () -> Void
    @State private var target: Target? = .claude
    @State private var search = ""

    private var keyProviders: [GenericProvider] {
        model.specProviders()
            .filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func matches(_ name: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $target) {
                    if matches("Claude") || matches("Codex") || matches("ChatGPT") {
                        Section("Subscriptions") {
                            if matches("Claude") { Text("Claude Code").tag(Target.claude) }
                            if matches("Codex") || matches("ChatGPT") { Text("Codex / ChatGPT").tag(Target.codex) }
                        }
                    }
                    if matches("Cursor") || !AppModel.credentialPaths.keys.filter({ matches(model.providerName($0)) }).isEmpty {
                        Section("Sign-ins") {
                            if matches("Cursor") { Text("Cursor").tag(Target.cursor) }
                            ForEach(AppModel.credentialPaths.keys.sorted().filter { matches(model.providerName($0)) },
                                    id: \.self) { id in
                                Text(model.providerName(id)).tag(Target.profile(id))
                            }
                        }
                    }
                    if !keyProviders.isEmpty {
                        Section("API Keys") {
                            ForEach(keyProviders, id: \.id) { provider in
                                Text(provider.displayName).tag(Target.apiKey(provider.id))
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
                .searchable(text: $search, placement: .sidebar, prompt: "Search")
                .frame(width: 210)
                Divider()
                Group {
                    switch target {
                    case .claude:
                        SubscriptionConnectForm(model: model, kind: .claudeStatusLine, onConnected: onDone)
                    case .codex:
                        SubscriptionConnectForm(model: model, kind: .codexAppServer, onConnected: onDone)
                    case .cursor:
                        CursorSessionForm(model: model, onDone: onDone)
                    case .apiKey(let id):
                        if let provider = model.specProviders().first(where: { $0.id == id }) {
                            APIKeyForm(model: model, provider: provider, onDone: onDone).id(id)
                        }
                    case .profile(let id):
                        CredentialProfileForm(model: model, providerID: id, onDone: onDone).id(id)
                    case nil:
                        ContentUnavailableView("Choose a Provider", systemImage: "square.stack.3d.up")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Spacer()
                Button("Done", action: onDone).keyboardShortcut(.cancelAction)
            }
            .padding(12)
        }
        .frame(width: 640, height: 440)
    }
}

private struct APIKeyForm: View {
    var model: AppModel
    var provider: GenericProvider
    var onDone: () -> Void
    @State private var key = ""
    @State private var label = ""
    @State private var errorText: String?

    private var note: String {
        switch provider.id {
        case "mistral": "Needs an Admin API key. Shows 30-day workspace activity, not a personal allowance."
        case "requesty": "Needs a management key. Balance is shared across the organization."
        case "zenmux": "Needs a Management API key."
        case "atlascloud": "Needs a key with account balance permission."
        default: provider.unverified
            ? "Experimental. Readings haven't been verified against a live account."
            : "API billing is separate from any subscription allowance."
        }
    }

    var body: some View {
        Form {
            Section {
                SecureField(provider.spec.auth == .cookie ? "Session Cookie" : "API Key", text: $key)
                TextField("Label", text: $label, prompt: Text("Work"))
                HStack {
                    Spacer()
                    Button("Add") {
                        do {
                            try model.addAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines),
                                                provider: provider, label: label.isEmpty ? nil : label)
                            onDone()
                        } catch {
                            errorText = (error as? ProviderError)?.userMessage ?? error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text(provider.displayName)
            } footer: {
                Text(errorText ?? note).foregroundStyle(errorText == nil ? Color.secondary : .red)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CursorSessionForm: View {
    var model: AppModel
    var onDone: () -> Void
    @State private var token = ""
    @State private var label = ""
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                SecureField("Session Token", text: $token, prompt: Text("userID::token"))
                TextField("Label", text: $label, prompt: Text("Personal"))
                HStack {
                    Spacer()
                    Button("Add") {
                        do {
                            try model.addSessionToken(token.trimmingCharacters(in: .whitespacesAndNewlines),
                                                      label: label.isEmpty ? nil : label)
                            onDone()
                        } catch {
                            errorText = (error as? ProviderError)?.userMessage ?? error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(token.isEmpty)
                }
            } header: {
                Text("Cursor")
            } footer: {
                Text(errorText ?? "Paste a session token from Cursor. Replace it when it expires.")
                    .foregroundStyle(errorText == nil ? Color.secondary : .red)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CredentialProfileForm: View {
    var model: AppModel
    var providerID: String
    var onDone: () -> Void
    @State private var label = ""
    @State private var path = ""
    @State private var errorText: String?

    var body: some View {
        Form {
            Section {
                TextField("Label", text: $label, prompt: Text("Work"))
                LabeledContent("Credential File") {
                    HStack {
                        Text(path.isEmpty ? "None" : (path as NSString).abbreviatingWithTildeInPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: choose)
                    }
                }
                HStack {
                    Spacer()
                    Button("Add") {
                        do {
                            try model.addProfile(providerID: providerID, label: label, path: path)
                            onDone()
                        } catch {
                            errorText = "Choose an existing credential file under 1 MB and enter a label."
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || path.isEmpty)
                }
            } header: {
                Text(model.providerName(providerID))
            } footer: {
                Text(errorText ?? "Your default sign-in is detected automatically. Add a profile for each additional account's credential file.")
                    .foregroundStyle(errorText == nil ? Color.secondary : .red)
            }
        }
        .formStyle(.grouped)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}
#endif
