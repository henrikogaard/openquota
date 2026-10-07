#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

struct SubscriptionConnectForm: View {
    var model: AppModel
    var kind: SubscriptionConnectionKind
    var onConnected: () -> Void = {}
    @State private var claudeLabel = ""
    @State private var claudeDirectory = "~/.claude"
    @State private var codexLabel = ""
    @State private var codexExecutable = ""
    @State private var errorText: String?

    var body: some View {
        Form {
            switch kind {
            case .claudeStatusLine: claudeSection
            case .codexAppServer: codexSection
            }
            if let errorText {
                Text(errorText).font(.callout).foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .onDisappear { model.cancelCodexLogin() }
        .onChange(of: model.codexLoginStatus) { _, status in
            if status == "Codex account connected." { onConnected() }
        }
    }

    private var claudeSection: some View {
        Section {
            TextField("Label", text: $claudeLabel, prompt: Text(Self.claudeDefaultLabel))
            LabeledContent("Configuration") {
                HStack {
                    Text(claudeDirectory).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseClaudeDirectory)
                }
            }
            HStack {
                Spacer()
                Button("Connect", action: installClaude)
                    .keyboardShortcut(.defaultAction)
            }
        } header: {
            Text("Claude Code")
        } footer: {
            Text("Adds a status-line bridge to this configuration. Usage appears after your next Claude Code reply. Your existing status line keeps working.")
                .foregroundStyle(.secondary)
        }
    }

    private var codexSection: some View {
        Section {
            TextField("Label", text: $codexLabel, prompt: Text(Self.codexDefaultLabel))
            LabeledContent("Codex CLI") {
                HStack {
                    Text(codexExecutable.isEmpty ? "Automatic" : codexExecutable)
                        .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Button("Choose…", action: chooseCodexExecutable)
                }
            }
            if model.codexLoginBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(model.codexLoginStatus ?? "Waiting for sign-in…").foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") { model.cancelCodexLogin() }
                }
            } else {
                HStack {
                    if let status = model.codexLoginStatus {
                        Text(status).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Sign In with ChatGPT…", action: startCodexLogin)
                        .keyboardShortcut(.defaultAction)
                }
            }
        } header: {
            Text("Codex / ChatGPT")
        } footer: {
            Text("Sign in through Codex in your browser. Each account gets its own private Codex home.")
                .foregroundStyle(.secondary)
        }
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
            errorText = "The openquota-bridge helper is missing. Reinstall the app or run it from a complete build."
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
