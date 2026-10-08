#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// A searchable grid of providers; choosing one shows its short form.
struct AddAccountSheet: View {
    enum Target: Hashable {
        case claude, codex, cursor, openCodeMethods
        case apiKey(String)
        case profile(String)

        /// Forms with a primary button draw their own Cancel/Add bar.
        var ownsActions: Bool {
            switch self {
            case .openCodeMethods: false
            case .claude, .codex, .cursor, .apiKey, .profile: true
            }
        }
    }

    struct Tile: Identifiable {
        var target: Target
        var providerID: String
        var name: String
        var id: Target { target }
    }

    var model: AppModel
    var onDone: () -> Void
    @State private var target: Target?
    @State private var backTarget: Target?
    @State private var search = ""
    @FocusState private var searchFocused: Bool

    private var tiles: [Tile] {
        var byCanonicalID: [String: Tile] = [
            "claude": Tile(target: .claude, providerID: "claude", name: "Claude Code"),
            "codex": Tile(target: .codex, providerID: "codex", name: "Codex / ChatGPT"),
            "cursor": Tile(
                target: .cursor, providerID: "cursor",
                name: L("Cursor · Experimental", "Cursor · Eksperimentell")),
        ]
        for provider in model.specProviders() {
            let id = canonicalProviderID(provider.id)
            guard byCanonicalID[id] == nil else { continue }
            let target: Target = id == "opencode-go" ? .openCodeMethods : .apiKey(provider.id)
            byCanonicalID[id] = Tile(target: target, providerID: id, name: provider.displayName)
        }
        for id in AppModel.credentialPaths.keys {
            let canonicalID = canonicalProviderID(id)
            if canonicalID == "opencode-go" {
                byCanonicalID[canonicalID] = byCanonicalID[canonicalID]
                    ?? Tile(
                        target: .openCodeMethods, providerID: canonicalID,
                        name: model.providerName(canonicalID))
                continue
            }
            guard byCanonicalID[canonicalID] == nil else { continue }
            byCanonicalID[canonicalID] = Tile(
                target: .profile(id), providerID: id, name: model.providerName(id))
        }
        return byCanonicalID.values
            .filter(matches)
            .sorted {
                let order = $0.name.localizedCaseInsensitiveCompare($1.name)
                return order == .orderedSame ? $0.providerID < $1.providerID : order == .orderedAscending
            }
    }

    private func canonicalProviderID(_ id: String) -> String {
        id == "opencode" ? "opencode-go" : id
    }

    private func matches(_ tile: Tile) -> Bool {
        search.isEmpty || tile.name.localizedCaseInsensitiveContains(search)
            || (tile.target == .codex && "chatgpt".localizedCaseInsensitiveContains(search))
    }

    private func title(for target: Target) -> String {
        switch target {
        case .claude: "Claude Code"
        case .codex: "Codex / ChatGPT"
        case .cursor: "Cursor"
        case .openCodeMethods: model.providerName("opencode-go")
        case .apiKey(let id), .profile(let id): model.providerName(id)
        }
    }

    private var sheetHeight: CGFloat {
        switch target {
        case nil: 470
        case .some(.cursor): 480
        case .some(.openCodeMethods): 300
        case .some(.profile(_)): 420
        case .some(.claude): 460
        default: 340
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let target {
                    form(for: target)
                } else {
                    grid
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if target?.ownsActions != true {
                Divider()
                HStack {
                    Spacer()
                    Button(L("Cancel", "Avbryt"), action: onDone).keyboardShortcut(.cancelAction)
                }
                .padding(12)
            }
        }
        .frame(width: 560, height: sheetHeight)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let target {
                Button {
                    if let backTarget {
                        self.target = backTarget
                        self.backTarget = nil
                    } else {
                        self.target = nil
                    }
                } label: {
                    Label(L("Back", "Tilbake"), systemImage: "chevron.left").labelStyle(.iconOnly)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .keyboardShortcut("[", modifiers: .command)
                Text(title(for: target)).font(.headline)
                Spacer()
            } else {
                Text(L("Add Account", "Legg til konto")).font(.headline)
                Spacer()
                TextField(L("Search Providers", "Søk etter leverandører"), text: $search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .focused($searchFocused)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                    ForEach(tiles) { tile in
                        Button {
                            target = tile.target
                            backTarget = nil
                        } label: {
                            VStack(spacing: 8) {
                                ProviderGlyph(providerID: tile.providerID, name: tile.name, size: 32)
                                Text(tile.name)
                                    .font(.callout)
                                    .lineLimit(2, reservesSpace: true)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity, minHeight: 96)
                            .contentShape(.rect(cornerRadius: 12))
                        }
                        .buttonStyle(ProviderTileStyle())
                    }
                }
                if tiles.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private func form(for target: Target) -> some View {
        switch target {
        case .claude:
            SubscriptionConnectForm(model: model, kind: .claudeStatusLine, onConnected: onDone, onCancel: onDone)
        case .codex:
            SubscriptionConnectForm(model: model, kind: .codexAppServer, onConnected: onDone, onCancel: onDone)
        case .cursor:
            CursorSessionForm(model: model, onDone: onDone)
        case .openCodeMethods:
            VStack(alignment: .leading, spacing: 12) {
                Text(L(
                    "One OpenCode login can have several workspace subscriptions, each with its own key. Your main sign-in is detected automatically.",
                    "Én OpenCode-pålogging kan ha flere arbeidsområdeabonnementer, hvert med sin egen nøkkel. Hovedpåloggingen oppdages automatisk."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Add workspace subscription", "Legg til arbeidsområdeabonnement")) {
                    backTarget = .openCodeMethods
                    self.target = .apiKey("opencode-go")
                }
                .buttonStyle(.glass)
                Button(L("Use another sign-in file", "Bruk en annen påloggingsfil")) {
                    backTarget = .openCodeMethods
                    self.target = .profile("opencode")
                }
                .buttonStyle(.glass)
                Spacer()
            }
            .padding(20)
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
        case "mistral": L("Needs an Admin API key. Shows 30-day workspace activity, not a personal allowance.",
                           "Krever en admin-API-nøkkel. Viser aktivitet i arbeidsområdet siste 30 dager, ikke en personlig kvote.")
        case "requesty": L("Needs a management key. Balance is shared across the organization.",
                            "Krever en administrasjonsnøkkel. Saldoen deles i hele organisasjonen.")
        case "zenmux": L("Needs a Management API key.", "Krever en administrasjons-API-nøkkel.")
        case "atlascloud": L("Needs a key with account balance permission.", "Krever en nøkkel med tilgang til kontosaldo.")
        case "opencode-go": L("Paste the OpenCode Go key from opencode.ai/zen. Add one per subscription.",
                               "Lim inn OpenCode Go-nøkkelen fra opencode.ai/zen. Legg til én per abonnement.")
        default: provider.unverified
            ? L("Experimental. Readings haven't been verified against a live account.",
                "Eksperimentell. Målingene er ikke bekreftet mot en ekte konto.")
            : L("API billing is separate from any subscription allowance.",
                "API-fakturering er atskilt fra abonnementskvoter.")
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SecureField(provider.spec.auth == .cookie ? L("Session Cookie", "Øktcookie") : L("API Key", "API-nøkkel"), text: $key)
                    TextField(L("Label", "Navn"), text: $label, prompt: Text(L("Work", "Jobb")))
                } header: {
                    Text(provider.displayName)
                } footer: {
                    Text(errorText ?? note).foregroundStyle(errorText == nil ? Color.secondary : .red)
                }
            }
            .formStyle(.grouped)
            FormActions(primary: L("Add", "Legg til"),
                        disabled: key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        action: add, cancel: onDone)
        }
    }

    private func add() {
        do {
            try model.addAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines),
                                provider: provider, label: label.isEmpty ? nil : label)
            onDone()
        } catch {
            errorText = (error as? ProviderError)?.userMessage ?? error.localizedDescription
        }
    }
}

private struct CursorSessionForm: View {
    var model: AppModel
    var onDone: () -> Void
    @State private var token = ""
    @State private var label = ""
    @State private var errorText: String?
    @State private var consent = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    SecureField(L("Session Token", "Øktnøkkel"), text: $token, prompt: Text("userID::token"))
                    TextField(L("Label", "Navn"), text: $label, prompt: Text(L("Personal", "Privat")))
                } header: {
                    Text(L("Cursor · Experimental", "Cursor · Eksperimentell"))
                } footer: {
                    Text(errorText ?? L("Adding a new token for the same Cursor account replaces its saved token.",
                                        "En ny øktnøkkel for samme Cursor-konto erstatter den lagrede nøkkelen."))
                        .foregroundStyle(errorText == nil ? Color.secondary : .red)
                }
                Section {
                    Link(L("Open Cursor Dashboard", "Åpne Cursor-kontrollpanelet"),
                         destination: URL(string: "https://cursor.com/dashboard?tab=usage")!)
                    Text(L("In your signed-in browser, open Developer Tools → Application/Storage → Cookies → cursor.com. Copy only the WorkosCursorSessionToken value.",
                           "Åpne utviklerverktøy i nettleseren der du er logget inn → Application/Storage → Cookies → cursor.com. Kopier bare verdien til WorkosCursorSessionToken."))
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Enable experimental access", "Aktiver eksperimentell tilgang"), isOn: $consent)
                        .toggleStyle(.checkbox)
                } footer: {
                    Text(L("Uses unofficial endpoints that may break. This is a sensitive account session, not a read-only API key. Stored in this Mac’s Keychain; no browser import or automatic renewal. Never share it in chat or screenshots.",
                           "Bruker uoffisielle endepunkter som kan slutte å virke. Dette er en sensitiv kontoøkt, ikke en skrivebeskyttet API-nøkkel. Lagres i nøkkelringen på denne Macen; ingen nettleserimport eller automatisk fornyelse. Del den aldri i chat eller skjermbilder."))
                }
            }
            .formStyle(.grouped)
            FormActions(primary: L("Save", "Lagre"),
                        disabled: !consent || token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        action: add, cancel: onDone)
        }
    }

    private func add() {
        guard consent else { return }
        do {
            try model.addSessionToken(token.trimmingCharacters(in: .whitespacesAndNewlines),
                                      label: label.isEmpty ? nil : label)
            onDone()
        } catch {
            let message = (error as? ProviderError)?.userMessage
                ?? L("The session token could not be saved.", "Øktnøkkelen kunne ikke lagres.")
            errorText = providerError(message, providerID: "cursor")
        }
    }
}

private struct CredentialProfileForm: View {
    var model: AppModel
    var providerID: String
    var onDone: () -> Void
    @State private var label = ""
    @State private var path = ""
    @State private var errorText: String?

    private var defaultPath: String? { AppModel.credentialPaths[providerID].map { "~/" + $0 } }
    private var defaultExists: Bool {
        defaultPath.map { FileManager.default.fileExists(atPath: ($0 as NSString).expandingTildeInPath) } ?? false
    }
    private var canAdd: Bool { !path.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                if let defaultPath {
                    Section {
                        LabeledContent(L("Main Account", "Hovedkonto")) {
                            Label(defaultExists ? L("Detected", "Funnet") : L("Not signed in", "Ikke logget inn"),
                                  systemImage: defaultExists ? "checkmark.circle.fill" : "minus.circle")
                                .foregroundStyle(defaultExists ? Color.green : .secondary)
                        }
                    } footer: {
                        Text(defaultExists
                             ? L("Read automatically from \(defaultPath).", "Leses automatisk fra \(defaultPath).")
                             : L("Sign in with the \(model.providerName(providerID)) CLI; OpenQuota then reads \(defaultPath) automatically.",
                                 "Logg inn med \(model.providerName(providerID))-CLI-en, så leser OpenQuota \(defaultPath) automatisk."))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Section {
                    TextField(L("Label", "Navn"), text: $label, prompt: Text(L("Work", "Jobb")))
                    LabeledContent(L("Credential File", "Påloggingsfil")) {
                        HStack {
                            Text(path.isEmpty ? L("Not chosen", "Ikke valgt") : (path as NSString).abbreviatingWithTildeInPath)
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            Button(L("Choose…", "Velg…"), action: choose)
                        }
                    }
                } header: {
                    Text(L("Another Account", "En annen konto"))
                } footer: {
                    Text(errorText ?? L("Pick a copy of another account's credential file. Press ⌘⇧. in the file dialog to show hidden folders.",
                                        "Velg en kopi av påloggingsfilen til en annen konto. Trykk ⌘⇧. i fildialogen for å vise skjulte mapper."))
                        .foregroundStyle(errorText == nil ? Color.secondary : .red)
                }
            }
            .formStyle(.grouped)
            FormActions(primary: L("Add", "Legg til"), disabled: !canAdd, action: add, cancel: onDone)
        }
    }

    private func add() {
        do {
            let name = label.trimmingCharacters(in: .whitespacesAndNewlines)
            try model.addProfile(providerID: providerID,
                                 label: name.isEmpty ? model.providerName(providerID) : name, path: path)
            onDone()
        } catch {
            errorText = L("Choose an existing credential file under 1 MB.", "Velg en eksisterende påloggingsfil under 1 MB.")
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let defaultPath {
            panel.directoryURL = URL(fileURLWithPath: (defaultPath as NSString).expandingTildeInPath)
                .deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url { path = url.path }
    }
}

/// Cancel + primary button along the sheet's bottom edge.
struct FormActions: View {
    var primary: String
    var disabled: Bool
    var action: () -> Void
    var cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Spacer()
                Button(L("Cancel", "Avbryt"), action: cancel).keyboardShortcut(.cancelAction)
                Button(primary, action: action)
                    .keyboardShortcut(.defaultAction)
                    .disabled(disabled)
            }
            .padding(12)
        }
    }
}
#endif
