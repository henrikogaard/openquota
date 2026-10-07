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
        .onDisappear { model.cancelCodexLogin() }
        .onChange(of: model.codexLoginStatus) { _, status in
            if status == "Codex account connected." { onConnected() }
        }
    }

    private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    fieldLabel("Label")
                    TextField("Label", text: $claudeLabel, prompt: Text(Self.claudeDefaultLabel))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                }
                GridRow {
                    fieldLabel("Configuration")
                    HStack {
                        Text(claudeDirectory).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Choose…", action: chooseClaudeDirectory)
                    }
                }
            }
            Text("Adds a status-line bridge to this configuration. Usage appears after your next Claude Code reply. Your existing status line keeps working.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Connect", action: installClaude)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var codexSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    fieldLabel("Label")
                    TextField("Label", text: $codexLabel, prompt: Text(Self.codexDefaultLabel))
                        .labelsHidden().textFieldStyle(.roundedBorder)
                }
                GridRow {
                    fieldLabel("Codex CLI")
                    HStack {
                        Text(codexPath)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(codexPath)
                        Button("Choose…", action: chooseCodexExecutable)
                            .disabled(model.codexLoginBusy)
                    }
                }
            }
            Text("Sign in through Codex in your browser. Each account gets its own private Codex home.")
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
                    Spacer()
                    Button("Cancel") { model.cancelCodexLogin() }
                }
            } else {
                HStack {
                    Spacer()
                    Button("Sign In with ChatGPT…", action: startCodexLogin)
                        .buttonStyle(.glassProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var codexPath: String {
        if !codexExecutable.isEmpty { return codexExecutable }
        return CodexExecutableResolver.resolve()?.path ?? "Not found — choose Codex CLI"
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
