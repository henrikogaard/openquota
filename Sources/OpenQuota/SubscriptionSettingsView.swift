#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

struct SubscriptionSettingsView: View {
    var model: AppModel
    @State private var claudeLabel = ""
    @State private var claudeDirectory = "~/.claude"
    @State private var codexLabel = ""
    @State private var codexExecutable = ""
    @State private var errorText: String?
    @State private var removingConnection: SubscriptionConnection?

    var body: some View {
        Form {
            Section("Connected Subscriptions") {
                if model.subscriptionConnections.isEmpty {
                    Text("No subscription accounts connected.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.subscriptionConnections) { connection in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(connection.label)
                            Text("\(sourceName(connection.kind)) · \(connection.directory)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(connection.directory)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) {
                            removingConnection = connection
                        }
                    }
                }
            }

            Section("Claude Code status line") {
                TextField("Account label", text: $claudeLabel)
                HStack {
                    TextField("Claude config directory", text: $claudeDirectory)
                    Button("Choose…", action: chooseClaudeDirectory)
                }
                Text("Connect a separate Claude Code configuration for each login. The card follows the active login in that configuration and may not represent an immutable identity. A Claude Code subscriber response is required before limits appear.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("OpenQuota adds a status-line wrapper to settings.json, preserves the existing command and other settings, and restores it on disconnect only if it has not been changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Connect & Install Status Line", action: installClaude)
                    .disabled(claudeLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Link("Claude usage dashboard", destination: URL(string: "https://claude.ai/settings/usage")!)
                    .font(.caption)
            }

            Section("Codex subscription") {
                TextField("Account label", text: $codexLabel)
                HStack {
                    TextField("Codex executable (optional)", text: $codexExecutable)
                    Button("Choose…", action: chooseCodexExecutable)
                }
                Text("Sign in with ChatGPT in your browser. Each connection uses an isolated Codex home managed by Codex; removing it keeps Codex-managed credentials. API keys do not expose subscription quotas.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.codexLoginBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(model.codexLoginStatus ?? "Waiting for sign-in…")
                            .font(.caption)
                        Spacer()
                        Button("Cancel") { model.cancelCodexLogin() }
                    }
                } else {
                    Button("Sign in with ChatGPT", action: startCodexLogin)
                        .disabled(codexLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let status = model.codexLoginStatus {
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Link("Codex usage dashboard", destination: URL(string: "https://chatgpt.com/codex/settings/usage")!)
                    .font(.caption)
            }

            if let errorText {
                Section {
                    Text(errorText).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.cancelCodexLogin() }
        .alert("Disconnect Subscription Account?", isPresented: Binding(
            get: { removingConnection != nil },
            set: { if !$0 { removingConnection = nil } }
        )) {
            Button("Cancel", role: .cancel) { removingConnection = nil }
            Button("Remove", role: .destructive) {
                if let connection = removingConnection {
                    perform { try model.removeSubscriptionConnection(connection) }
                }
                removingConnection = nil
            }
        } message: {
            Text(removingConnection?.kind == .codexAppServer
                ? "This removes the OpenQuota connection but keeps the Codex-managed sign-in files in its private account home."
                : "This removes the OpenQuota connection. The Claude setting is restored only if its installed command is unchanged; credential files are not modified.")
        }
    }

    private func installClaude() {
        guard let helper = helperExecutable() else {
            errorText = "The openquota-bridge helper is missing. Reinstall the app or run it from a complete build."
            return
        }
        perform {
            try model.installClaudeStatusLine(
                label: claudeLabel,
                configurationDirectory: claudeDirectory,
                helper: helper)
            claudeLabel = ""
            errorText = nil
        }
    }

    private func startCodexLogin() {
        errorText = nil
        model.startCodexLogin(
            label: codexLabel,
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

    private func sourceName(_ kind: SubscriptionConnectionKind) -> String {
        switch kind {
        case .claudeStatusLine: "Claude Code status line"
        case .codexAppServer: "Codex managed ChatGPT sign-in"
        }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorText = nil
        } catch let error as ClaudeStatusLineInstallError {
            switch error {
            case .duplicateConfigurationDirectory:
                errorText = "That Claude configuration is already connected."
            case .configurationDirectoryNotFound:
                errorText = "Choose an existing Claude configuration directory."
            case .invalidHelper:
                errorText = "The OpenQuota bridge helper is unavailable."
            case .recursiveBridge:
                errorText = "This status line already invokes OpenQuota. Disconnect it before reconnecting."
            case .unsupportedStatusLine:
                errorText = "The existing status-line type is unsupported; settings were not changed."
            case .malformedSettings, .settingsTooLarge:
                errorText = "Claude settings could not be read safely; no changes were made."
            default:
                errorText = "Claude could not be connected. Check the label and configuration directory."
            }
        } catch {
            errorText = "The subscription connection could not be saved."
        }
    }
}
#endif
