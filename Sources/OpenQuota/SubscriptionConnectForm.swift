#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

struct SubscriptionConnectForm: View {
    var model: AppModel
    var kind: SubscriptionConnectionKind
    var onConnected: () -> Void = {}
    var onCancel: () -> Void = {}
    @State private var codexLabel = ""
    @State private var codexExecutable = ""
    @State private var errorText: String?

    var body: some View {
        switch kind {
        case .claudeStatusLine:
            ClaudeSetupWizard(model: model, onConnected: onConnected, onCancel: onCancel)
        case .codexAppServer:
            codexForm
        case .antigravityStatusLine:
            AntigravitySetupForm(model: model, onConnected: onConnected, onCancel: onCancel)
        }
    }

    private var codexForm: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    codexSection
                    if let errorText {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            FormActions(
                primary: L("Sign In with ChatGPT…", "Logg inn med ChatGPT…"),
                disabled: model.codexLoginBusy,
                action: startCodexLogin,
                cancel: {
                    model.cancelCodexLogin()
                    onCancel()
                })
        }
        .onDisappear { model.cancelCodexLogin() }
        .onChange(of: model.codexLoginStatus) { _, status in
            if status == AppModel.codexConnectedStatus { onConnected() }
        }
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    fieldLabel(L("Label", "Navn"))
                    TextField(L("Label", "Navn"), text: $codexLabel, prompt: Text(Self.codexDefaultLabel))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                        .disabled(model.codexLoginBusy)
                }
                GridRow {
                    fieldLabel("Codex CLI")
                    HStack {
                        Text(codexPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(codexPath)
                        Button(L("Choose…", "Velg…"), action: chooseCodexExecutable)
                            .disabled(model.codexLoginBusy)
                    }
                }
            }
            Text(L("Sign in through Codex in your browser. Each account gets its own private Codex home.",
                    "Logg inn via Codex i nettleseren. Hver konto får sin egen private Codex-mappe."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let status = model.codexLoginStatus {
                Text(status)
                    .font(.callout)
                    .foregroundStyle(model.codexLoginBusy ? Color.secondary : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if model.codexLoginBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(L("Waiting for sign-in…", "Venter på pålogging…"))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var codexPath: String {
        if !codexExecutable.isEmpty { return codexExecutable }
        return CodexExecutableResolver.resolve()?.path ?? L("Not found — choose Codex CLI", "Ikke funnet – velg Codex CLI")
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title).frame(width: 96, alignment: .leading)
    }

    static let codexDefaultLabel = "ChatGPT"

    /// An empty label falls back to the placeholder the field shows.
    static func resolvedLabel(_ label: String, fallback: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func startCodexLogin() {
        errorText = nil
        model.startCodexLogin(
            label: Self.resolvedLabel(codexLabel, fallback: Self.codexDefaultLabel),
            executablePath: codexExecutable.isEmpty ? nil : codexExecutable,
            openAuthURL: { url in NSWorkspace.shared.open(url) })
        codexLabel = ""
    }

    private func chooseCodexExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            codexExecutable = url.path
        }
    }

}

struct AntigravitySetupForm: View {
    var model: AppModel
    var onConnected: () -> Void = {}
    var onCancel: () -> Void = {}

    @State private var label = ""
    @State private var folder = "~/.gemini/antigravity-cli"
    @State private var status = AntigravityCLIStatus.check(configurationDirectory: "~/.gemini/antigravity-cli")
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                        GridRow {
                            Text(L("Label", "Navn")).frame(width: 96, alignment: .leading)
                            TextField(L("Label", "Navn"), text: $label, prompt: Text("Antigravity"))
                                .labelsHidden().textFieldStyle(.roundedBorder)
                        }
                        GridRow {
                            Text(L("Folder", "Mappe")).frame(width: 96, alignment: .leading)
                            HStack {
                                TextField(L("Folder", "Mappe"), text: $folder)
                                    .labelsHidden().textFieldStyle(.roundedBorder)
                                Button(L("Choose…", "Velg…"), action: chooseFolder)
                            }
                        }
                    }
                    statusRow
                    Text(L(
                        "Installs OpenQuota’s local helper in Antigravity CLI’s documented statusLine setting (settings.json). Readings update passively while you use agy — showing your Google AI plan tier and quota buckets. OpenQuota reads no tokens and makes no network requests. Your existing status line keeps working.",
                        "Installerer OpenQuotas lokale hjelpeprogram i den dokumenterte statusLine-innstillingen til Antigravity CLI (settings.json). Målingene oppdateres passivt mens du bruker agy – og viser Google AI-plan og kvoter. OpenQuota leser ingen nøkler og gjør ingen nettverkskall. Den eksisterende statuslinjen fortsetter å virke."))
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(L(
                        "If you haven’t signed in to Antigravity CLI yet, run agy in Terminal to sign in with your Google account. ACP clients (agy acp) share the same Google account quota, but do not run statusLine — open agy or run /usage inside agy to update.",
                        "Hvis du ikke har logget inn i Antigravity CLI ennå, kjør agy i Terminal for å logge inn med Google-kontoen din. ACP-klienter (agy acp) deler samme Google-kontokvote, men kjører ikke statusLine – åpne agy eller kjør /usage i agy for å oppdatere."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let errorText {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            FormActions(
                primary: L("Connect", "Koble til"),
                disabled: model.isDemo || folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                action: connect,
                cancel: onCancel)
        }
        .task(id: folder) {
            status = AntigravityCLIStatus.check(configurationDirectory: folder)
        }
    }

    @ViewBuilder private var statusRow: some View {
        HStack(spacing: 8) {
            if let path = status.executablePath {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(status.folderExists
                     ? L("Antigravity CLI found (\(path)).", "Fant Antigravity CLI (\(path)).")
                     : L("Antigravity CLI found. OpenQuota will create the settings folder when you connect.",
                         "Fant Antigravity CLI. OpenQuota oppretter innstillingsmappen når du kobler til."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(L("agy was not found on PATH. Install Antigravity CLI and sign in with agy to receive readings.",
                       "Fant ikke agy i PATH. Installer Antigravity CLI og logg inn med agy for å motta målinger."))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            folder = url.path
        }
    }

    private func connect() {
        errorText = nil
        guard let helper = ClaudeBridgeHelper.executable() else {
            errorText = L(
                "The openquota-bridge helper is missing. Reinstall the app or run it from a complete build.",
                "Hjelpeprogrammet openquota-bridge mangler. Installer appen på nytt.")
            return
        }
        let trimmedFolder = folder.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try model.installAntigravityStatusLine(
                label: SubscriptionConnectForm.resolvedLabel(label, fallback: "Antigravity"),
                configurationDirectory: trimmedFolder,
                helper: helper,
                createDirectoryIfMissing: true)
            onConnected()
        } catch {
            errorText = Self.message(for: error)
        }
    }

    private static func message(for error: Error) -> String {
        guard let error = error as? AntigravityStatusLineInstallError else {
            return L("The subscription connection could not be saved.", "Abonnementstilkoblingen kunne ikke lagres.")
        }
        switch error {
        case .duplicateConfigurationDirectory:
            return L("That Antigravity CLI configuration is already connected.", "Denne Antigravity CLI-konfigurasjonen er allerede koblet til.")
        case .configurationDirectoryNotFound, .invalidConfigurationDirectory:
            return L("Choose a valid Antigravity CLI configuration directory.", "Velg en gyldig konfigurasjonsmappe for Antigravity CLI.")
        case .invalidHelper:
            return L("The OpenQuota bridge helper is unavailable.", "Hjelpeprogrammet til OpenQuota er utilgjengelig.")
        case .recursiveBridge:
            return L("This status line already invokes OpenQuota. Disconnect it before reconnecting.", "Denne statuslinjen bruker allerede OpenQuota. Koble den fra før du kobler til på nytt.")
        case .unsupportedStatusLine:
            return L("The existing status-line setting is unsupported; settings were not changed.", "Den eksisterende statuslinjeinnstillingen støttes ikke; innstillingene ble ikke endret.")
        case .malformedSettings, .settingsTooLarge:
            return L("Antigravity CLI settings could not be read safely; no changes were made.", "Innstillingene til Antigravity CLI kunne ikke leses trygt; ingenting ble endret.")
        default:
            return L("Antigravity could not be connected. Check the label and configuration directory.", "Antigravity kunne ikke kobles til. Sjekk navnet og konfigurasjonsmappen.")
        }
    }
}
#endif
