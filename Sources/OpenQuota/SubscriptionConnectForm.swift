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
        if kind == .claudeStatusLine {
            ClaudeSetupWizard(model: model, onConnected: onConnected, onCancel: onCancel)
        } else {
            codexForm
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
#endif
