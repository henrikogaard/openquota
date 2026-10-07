#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// A searchable grid of providers; choosing one pushes its short form.
struct AddAccountSheet: View {
    enum Target: Hashable {
        case claude, codex, cursor
        case apiKey(String)
        case profile(String)
    }

    struct Tile: Identifiable {
        var target: Target
        var providerID: String
        var name: String
        var id: Target { target }
    }

    var model: AppModel
    var onDone: () -> Void
    @State private var path: [Target] = []
    @State private var search = ""

    private var sections: [(title: String, tiles: [Tile])] {
        let subscriptions = [
            Tile(target: .claude, providerID: "claude", name: "Claude Code"),
            Tile(target: .codex, providerID: "codex", name: "Codex / ChatGPT"),
        ]
        let signIns = [Tile(target: .cursor, providerID: "cursor", name: "Cursor")]
            + AppModel.credentialPaths.keys.sorted().map {
                Tile(target: .profile($0), providerID: $0, name: model.providerName($0))
            }
        let keys = model.specProviders()
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { Tile(target: .apiKey($0.id), providerID: $0.id, name: $0.displayName) }
        return [("Subscriptions", subscriptions), ("Sign-ins", signIns), ("API Keys", keys)]
            .map { ($0.0, $0.1.filter(matches)) }
            .filter { !$0.1.isEmpty }
    }

    private func matches(_ tile: Tile) -> Bool {
        search.isEmpty || tile.name.localizedCaseInsensitiveContains(search)
            || (tile.target == .codex && "chatgpt".localizedCaseInsensitiveContains(search))
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(sections, id: \.title) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(section.title)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                                ForEach(section.tiles) { tile in
                                    Button { path.append(tile.target) } label: {
                                        VStack(spacing: 8) {
                                            ProviderGlyph(providerID: tile.providerID, name: tile.name, size: 32)
                                            Text(tile.name)
                                                .font(.callout)
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.85)
                                        }
                                        .frame(maxWidth: .infinity, minHeight: 76)
                                        .contentShape(.rect(cornerRadius: 12))
                                    }
                                    .buttonStyle(ProviderTileStyle())
                                }
                            }
                        }
                    }
                    if sections.isEmpty {
                        ContentUnavailableView.search(text: search)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Add Account")
            .searchable(text: $search, placement: .toolbar, prompt: "Search Providers")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDone)
                }
            }
            .navigationDestination(for: Target.self) { target in
                form(for: target)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: onDone)
                        }
                    }
            }
        }
        .frame(width: 600, height: 480)
    }

    @ViewBuilder
    private func form(for target: Target) -> some View {
        switch target {
        case .claude:
            SubscriptionConnectForm(model: model, kind: .claudeStatusLine, onConnected: onDone)
        case .codex:
            SubscriptionConnectForm(model: model, kind: .codexAppServer, onConnected: onDone)
        case .cursor:
            CursorSessionForm(model: model, onDone: onDone)
        case .apiKey(let id):
            if let provider = model.specProviders().first(where: { $0.id == id }) {
                APIKeyForm(model: model, provider: provider, onDone: onDone)
            }
        case .profile(let id):
            CredentialProfileForm(model: model, providerID: id, onDone: onDone)
        }
    }
}

/// Quiet tile: a faint fill that brightens on hover and press.
private struct ProviderTileStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                .primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.09 : 0.05),
                in: .rect(cornerRadius: 12))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
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
        case "opencode-go": "Paste the OpenCode Go key from opencode.ai/zen. Add one per subscription."
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
