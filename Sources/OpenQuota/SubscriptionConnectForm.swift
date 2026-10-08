#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

struct SubscriptionConnectForm: View {
    var model: AppModel
    var kind: SubscriptionConnectionKind
    var onConnected: () -> Void = {}
    var onCancel: () -> Void = {}
    @State private var claudeLabel = ""
    @State private var claudeDirectory = "~/.claude"
    @State private var codexLabel = ""
    @State private var codexExecutable = ""
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch kind {
                    case .claudeStatusLine: claudeSection
                    case .codexAppServer: codexSection
                    }
                    if let errorText {
                        Text(errorText).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            FormActions(
                primary: kind == .claudeStatusLine
                    ? L("Connect", "Koble til")
                    : L("Sign In with ChatGPT…", "Logg inn med ChatGPT…"),
                disabled: kind == .codexAppServer && model.codexLoginBusy,
                action: {
                    if kind == .claudeStatusLine { installClaude() }
                    else { startCodexLogin() }
                },
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

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    fieldLabel(L("Label", "Navn"))
                    TextField(L("Label", "Navn"), text: $claudeLabel, prompt: Text(Self.claudeDefaultLabel))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                }
                GridRow {
                    fieldLabel(L("Configuration", "Konfigurasjon"))
                    HStack {
                        Text(claudeDirectory).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(claudeDirectory)
                        Button(L("Choose…", "Velg…"), action: chooseClaudeDirectory)
                    }
                }
            }
            Text(L("Adds a status-line bridge to this configuration. Usage appears after your next Claude Code reply. Your existing status line keeps working.",
                    "Legger til en statuslinjebro i denne konfigurasjonen. Bruken vises etter neste svar i Claude Code. Den eksisterende statuslinjen fortsetter å virke."))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text(L("Another subscription?", "Et annet abonnement?"))
                    .font(.callout.weight(.medium))
                Text(L("Sign in to a separate Claude profile in Terminal, then choose its folder above. Your normal CLI login stays unchanged.",
                       "Logg inn med en egen Claude-profil i Terminal, og velg mappen ovenfor. Den vanlige CLI-påloggingen endres ikke."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("CLAUDE_CONFIG_DIR=\"$HOME/.claude-work\" claude")
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("Readings update only while that profile is used and become outdated after 10 minutes.",
                       "Målinger oppdateres bare mens profilen brukes, og blir utdaterte etter 10 minutter."))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    static let claudeDefaultLabel = "Claude"
    static let codexDefaultLabel = "ChatGPT"

    /// An empty label falls back to the placeholder the field shows.
    static func resolvedLabel(_ label: String, fallback: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func installClaude() {
        guard let helper = helperExecutable() else {
            errorText = L("The openquota-bridge helper is missing. Reinstall the app or run it from a complete build.", "Hjelpeprogrammet openquota-bridge mangler. Installer appen på nytt.")
            return
        }
        perform {
            try model.installClaudeStatusLine(
                label: Self.resolvedLabel(claudeLabel, fallback: Self.claudeDefaultLabel),
                configurationDirectory: claudeDirectory,
                helper: helper)
            claudeLabel = ""
            errorText = nil
            onConnected()
        }
    }

    private func startCodexLogin() {
        errorText = nil
        model.startCodexLogin(
            label: Self.resolvedLabel(codexLabel, fallback: Self.codexDefaultLabel),
            executablePath: codexExecutable.isEmpty ? nil : codexExecutable,
            openAuthURL: { url in NSWorkspace.shared.open(url) })
        codexLabel = ""
    }

    private func chooseClaudeDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            claudeDirectory = url.path
        }
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

    private func helperExecutable() -> URL? {
        let bundled = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/openquota-bridge")
        if FileManager.default.isExecutableFile(atPath: bundled.path) { return bundled }
        var candidates = [Bundle.main.executableURL].compactMap { $0 }
        if let argument = CommandLine.arguments.first {
            if argument.contains("/") {
                candidates.append(URL(fileURLWithPath: argument))
            } else {
                for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "")
                    .split(separator: ":").map(String.init) {
                    candidates.append(URL(fileURLWithPath: directory).appendingPathComponent(argument))
                }
            }
        }
        for candidate in candidates {
            let sibling = candidate.resolvingSymlinksInPath()
                .deletingLastPathComponent().appendingPathComponent("openquota-bridge")
            if FileManager.default.isExecutableFile(atPath: sibling.path) { return sibling }
        }
        return nil
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorText = nil
        } catch let error as ClaudeStatusLineInstallError {
            switch error {
            case .duplicateConfigurationDirectory:
                errorText = L("That Claude configuration is already connected.", "Denne Claude-konfigurasjonen er allerede koblet til.")
            case .configurationDirectoryNotFound:
                errorText = L("Choose an existing Claude configuration directory.", "Velg en eksisterende Claude-konfigurasjonsmappe.")
            case .invalidHelper:
                errorText = L("The OpenQuota bridge helper is unavailable.", "Hjelpeprogrammet til OpenQuota er utilgjengelig.")
            case .recursiveBridge:
                errorText = L("This status line already invokes OpenQuota. Disconnect it before reconnecting.", "Denne statuslinjen bruker allerede OpenQuota. Koble den fra før du kobler til på nytt.")
            case .unsupportedStatusLine:
                errorText = L("The existing status-line type is unsupported; settings were not changed.", "Den eksisterende statuslinjetypen støttes ikke; innstillingene ble ikke endret.")
            case .malformedSettings, .settingsTooLarge:
                errorText = L("Claude settings could not be read safely; no changes were made.", "Claude-innstillingene kunne ikke leses trygt; ingenting ble endret.")
            default:
                errorText = L("Claude could not be connected. Check the label and configuration directory.", "Claude kunne ikke kobles til. Sjekk navnet og konfigurasjonsmappen.")
            }
        } catch {
            errorText = L("The subscription connection could not be saved.", "Abonnementstilkoblingen kunne ikke lagres.")
        }
    }
}
#endif
