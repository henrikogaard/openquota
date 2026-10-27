#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// A searchable grid of providers; choosing one shows its short form.
struct AddAccountSheet: View {
    enum Target: Hashable {
        case claude, codex, cursor, mistral, openCodeMethods
        case apiKey(String)
        case profile(String)

        /// Forms with a primary button draw their own Cancel/Add bar.
        var ownsActions: Bool {
            switch self {
            case .openCodeMethods: false
            case .claude, .codex, .cursor, .mistral, .apiKey, .profile: true
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
            "mistral": Tile(
                target: .mistral, providerID: "mistral",
                name: L("Mistral · Experimental", "Mistral · Eksperimentell")),
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
        case .mistral: "Mistral"
        case .openCodeMethods: model.providerName("opencode-go")
        case .apiKey(let id), .profile(let id): model.providerName(id)
        }
    }

    private var sheetHeight: CGFloat {
        switch target {
        case nil: 470
        case .some(.cursor): 480
        case .some(.mistral): 560
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
        case .mistral:
            MistralSessionWizard(model: model, onDone: onDone)
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

/// Guided three-step setup for a Mistral web session: open the console,
/// copy the Cookie header with per-browser instructions, then connect with a
/// live check that verifies the session against Mistral before saving.
private struct MistralSessionWizard: View {
    private enum Step { case signIn, copyCookie, connect }

    private enum Browser: String, CaseIterable, Identifiable {
        case safari, chrome, firefox
        var id: String { rawValue }

        var title: String {
            switch self {
            case .safari: "Safari"
            case .chrome: "Chrome/Edge"
            case .firefox: "Firefox"
            }
        }

        /// How to reach the Network tab in this browser.
        var instructions: String {
            switch self {
            case .safari:
                L("Safari → Settings → Advanced, turn on Show features for web developers. Then Develop → Show Web Inspector → Network.",
                  "Safari → Innstillinger → Avansert, slå på Vis funksjoner for nettutviklere. Deretter Utvikle → Vis nettkonsoll → Nettverk.")
            case .chrome:
                L("View → Developer → Developer Tools (⌘⌥I), then the Network tab.",
                  "Vis → Utvikler → Utviklerverktøy (⌘⌥I), deretter Nettverk-fanen.")
            case .firefox:
                L("Tools → Browser Tools → Web Developer Tools (⌘⌥I), then the Network tab.",
                  "Verktøy → Nettleserverktøy → Nettkonsoll (⌘⌥I), deretter Nettverk-fanen.")
            }
        }
    }

    var model: AppModel
    var onDone: () -> Void
    @State private var step = Step.signIn
    @State private var browser = Browser.safari
    @State private var cookie = ""
    @State private var label = ""
    @State private var consent = false
    @State private var connecting = false
    @State private var preview: UsageSnapshot?
    @State private var failure: ProviderError?
    @State private var errorText: String?

    private var pastedCookie: String {
        cookie.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var check: MistralProvider.CookieCheck {
        MistralProvider.checkCookieHeader(pastedCookie)
    }

    private var canConnect: Bool {
        consent && check.hasSessionCookie && !connecting && !model.isDemo
    }

    /// A failed check that doesn't prove the cookie dead still allows saving
    /// (the card retries later); an expired session or rate limit does not.
    private var offerSaveWithoutReading: Bool {
        switch failure {
        case .badResponse, .serverError, .network: true
        default: false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepHeader
                    switch step {
                    case .signIn: signInStep
                    case .copyCookie: copyCookieStep
                    case .connect:
                        if let preview {
                            summaryStep(preview)
                        } else {
                            connectStep
                        }
                    }
                    if let errorText {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            FormActions(
                primary: primaryLabel,
                disabled: primaryDisabled,
                action: primaryAction,
                cancel: onDone,
                back: backAction)
        }
    }

    // MARK: Steps

    private var stepHeader: some View {
        let number = switch step { case .signIn: 1; case .copyCookie: 2; case .connect: 3 }
        return Text(L("Step \(number) of 3", "Steg \(number) av 3"))
            .font(.caption).foregroundStyle(.secondary)
    }

    private var signInStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Sign in to Mistral", "Logg inn i Mistral"))
                .font(.headline)
            Link(L("Open admin.mistral.ai", "Åpne admin.mistral.ai"),
                 destination: URL(string: "https://admin.mistral.ai/subscription")!)
            Text(L("Sign in with the Mistral account you want to track (for example your Pro or Team account). OpenQuota never reads your browser — you paste the session yourself in the next steps.",
                   "Logg inn med Mistral-kontoen du vil følge (for eksempel Pro- eller Team-kontoen din). OpenQuota leser aldri nettleseren din — du limer inn økten selv i de neste stegene."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Mistral has no public API for subscription limits, so OpenQuota reads the web console session you paste. The cookie is stored in this Mac's Keychain only.",
                   "Mistral har ikke noe offentlig API for abonnementskvote, så OpenQuota leser nettkonsolløkten du limer inn. Cookien lagres bare i nøkkelringen på denne Macen."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var copyCookieStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Copy your session cookie", "Kopier øktcookien din"))
                .font(.headline)
            Picker(L("Browser", "Nettleser"), selection: $browser) {
                ForEach(Browser.allCases) { browser in
                    Text(browser.title).tag(browser)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(browser.instructions)
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            numbered(1, L("Open the Network tab as described above.", "Åpne Nettverk-fanen som beskrevet over."))
            numbered(2, L("Reload the admin.mistral.ai page, then click the first request in the list.", "Last inn admin.mistral.ai-siden på nytt, og klikk den første forespørselen i listen."))
            numbered(3, L("Under Request Headers, find the cookie header and copy its entire value.", "Under Request Headers finner du cookie-overskriften. Kopier hele verdien."))
            Text(L("It must contain an ory_session_… cookie. The value is long — that's fine. Treat it like a password: never share it.",
                   "Den må inneholde en ory_session_-cookie. Verdien er lang — det er greit. Behandle den som et passord: del den aldri."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Paste and connect", "Lim inn og koble til"))
                .font(.headline)
            SecureField(L("Cookie Header", "Cookie-overskrift"), text: $cookie,
                        prompt: Text("ory_session_…; csrftoken=…"))
            validationRows
            HStack {
                Text(L("Label", "Navn")).frame(width: 64, alignment: .leading)
                TextField(L("Label", "Navn"), text: $label, prompt: Text(L("Pro", "Pro")))
                    .labelsHidden().textFieldStyle(.roundedBorder)
            }
            Toggle(L("Enable experimental access", "Aktiver eksperimentell tilgang"), isOn: $consent)
                .toggleStyle(.checkbox)
            if model.isDemo {
                Text(L("Demo mode: adding accounts is disabled.", "Demomodus: å legge til kontoer er avslått."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(L("Uses the web console's unofficial endpoints, which may break. This is a sensitive session cookie, not a read-only API key. Stored in this Mac's Keychain; no browser import or automatic renewal. Sessions expire roughly monthly — use Replace Credential when the card shows a sign-in error.",
                   "Bruker nettkonsollens uoffisielle endepunkter, som kan slutte å virke. Dette er en sensitiv øktcookie, ikke en skrivebeskyttet API-nøkkel. Lagres i nøkkelringen på denne Macen; ingen nettleserimport eller automatisk fornyelse. Økter utløper omtrent månedlig — bruk Bytt påloggingsinformasjon når kortet viser en innloggingsfeil."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if connecting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Contacting Mistral…", "Kontakter Mistral …"))
                        .foregroundStyle(.secondary)
                }
            }
            if offerSaveWithoutReading {
                Divider()
                Text(L("The check couldn't read allowances, but the session may still be valid. The card retries on every refresh.",
                       "Sjekken kunne ikke lese kvoter, men økten kan fortsatt være gyldig. Kortet prøver på nytt ved hver oppdatering."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("Save without checking", "Lagre uten sjekk")) { save() }
                    .buttonStyle(.glass)
            }
        }
        .onChange(of: cookie) { _, _ in
            // A re-paste after a failure starts a clean slate.
            failure = nil
            errorText = nil
        }
    }

    @ViewBuilder private var validationRows: some View {
        Label(
            check.hasSessionCookie
                ? L("Session cookie found", "Fant øktcookie")
                : L("Missing ory_session_ cookie — paste the whole Cookie header", "Mangler ory_session_-cookie — lim inn hele Cookie-overskriften"),
            systemImage: check.hasSessionCookie ? "checkmark.circle.fill" : "circle.dashed")
            .foregroundStyle(check.hasSessionCookie ? Color.green : .secondary)
        if check.hasSessionCookie {
            Label(
                check.hasCsrfToken
                    ? L("csrftoken found — the Vibe fallback is available", "Fant csrftoken — Vibe-reserven er tilgjengelig")
                    : L("No csrftoken — the Vibe fallback will be skipped", "Ingen csrftoken — Vibe-reserven hoppes over"),
                systemImage: check.hasCsrfToken ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(check.hasCsrfToken ? Color.green : .secondary)
        }
    }

    private func summaryStep(_ snapshot: UsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Connected — check what Mistral reports", "Koblet til — se hva Mistral rapporterer"))
                .font(.headline)
            ForEach(snapshot.windows) { window in
                HStack {
                    Text(window.label)
                    Spacer()
                    Text(windowSummary(window))
                        .foregroundStyle(.secondary)
                }
            }
            if let credits = snapshot.creditsRemaining {
                HStack {
                    Text(L("Credits", "Kreditter"))
                    Spacer()
                    Text(Format.amount(credits, unit: snapshot.creditsUnit))
                        .foregroundStyle(.secondary)
                }
            }
            Text(L("Nothing is saved yet. Press Save to add this account.", "Ingenting er lagret ennå. Trykk Lagre for å legge til denne kontoen."))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func windowSummary(_ window: UsageWindow) -> String {
        var parts: [String] = []
        if let remaining = window.percentRemaining {
            parts.append("\(Int(remaining.rounded()))% \(L("left", "igjen"))")
        }
        if let resetsAt = window.resetsAt {
            parts.append("\(L("resets", "nullstilles")) \(resetsAt.formatted(.dateTime.month(.abbreviated).day().locale(Localized.appLocale)))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private var primaryLabel: String {
        switch step {
        case .signIn, .copyCookie: L("Continue", "Fortsett")
        case .connect: preview == nil ? L("Connect", "Koble til") : L("Save", "Lagre")
        }
    }

    private var primaryDisabled: Bool {
        step == .connect && preview == nil && !canConnect
    }

    private func primaryAction() {
        errorText = nil
        switch step {
        case .signIn: step = .copyCookie
        case .copyCookie: step = .connect
        case .connect:
            if preview == nil { connect() } else { save() }
        }
    }

    private var backAction: (() -> Void)? {
        switch step {
        case .signIn: nil
        case .copyCookie: { step = .signIn }
        case .connect: { preview = nil; failure = nil; step = .copyCookie }
        }
    }

    private func numbered(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func connect() {
        guard canConnect else { return }
        connecting = true
        failure = nil
        errorText = nil
        Task {
            do {
                let snapshot = try await model.previewMistralSession(pastedCookie)
                preview = snapshot
                connecting = false
            } catch is CancellationError {
                connecting = false
            } catch {
                connecting = false
                failure = error as? ProviderError
                let message = (error as? ProviderError)?.userMessage ?? error.localizedDescription
                errorText = providerError(message, providerID: "mistral")
            }
        }
    }

    private func save() {
        do {
            // An empty label falls back to the placeholder the field shows.
            try model.addMistralSession(pastedCookie, label: SubscriptionConnectForm.resolvedLabel(label, fallback: "Pro"))
            onDone()
        } catch {
            errorText = providerError(
                (error as? ProviderError)?.userMessage
                    ?? L("The session cookie could not be saved.", "Øktcookien kunne ikke lagres."),
                providerID: "mistral")
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
    var back: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                if let back {
                    Button(L("Back", "Tilbake"), action: back)
                }
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
