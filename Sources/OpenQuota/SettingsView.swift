#if os(macOS)
import SwiftUI
import OpenQuotaCore

/// Settings: API keys for spec providers, session tokens for the few
/// cookie-only providers, and a read-only list of auto-detected
/// local-credential providers (Claude, Codex, CLI tools, …).
struct SettingsView: View {
    var model: AppModel
    @State private var newKey = ""
    @State private var newLabel = ""
    @State private var selectedProvider = "openrouter"
    @State private var sessionToken = ""
    @State private var errorText: String?
    @State private var detected: [(id: String, name: String, accounts: Int)] = []

    private var selectedSpec: GenericProvider? {
        model.specProviders().first { $0.id == selectedProvider }
    }

    var body: some View {
        Form {
            Section("Add API key") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(model.specProviders(), id: \.id) { provider in
                        Text(provider.unverified
                             ? "\(provider.displayName) (unverified)"
                             : provider.displayName).tag(provider.id)
                    }
                }
                SecureField(keyFieldTitle, text: $newKey)
                TextField("Label (optional)", text: $newLabel)
                if let spec = selectedSpec?.spec, spec.auth == .cookie {
                    Text("No API for this provider — paste the session cookie "
                         + "from your browser's dev tools. Expires often; "
                         + "re-paste when the row errors.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button("Add Key") { addKey() }
                        .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.caption)
                }
            }

            if !model.tokenProviders().isEmpty {
                Section("Session tokens") {
                    ForEach(model.tokenProviders(), id: \.id) { provider in
                        HStack {
                            Text(provider.displayName)
                            Spacer()
                            SecureField("userID::token", text: $sessionToken)
                                .frame(width: 220)
                            Button("Save") { addSessionToken(provider) }
                                .disabled(sessionToken.isEmpty)
                        }
                    }
                    Text("Manual paste only — OpenQuota never imports browser cookies.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Detected providers") {
                ForEach(detected, id: \.id) { item in
                    HStack {
                        Text(item.name)
                        Spacer()
                        Text(item.accounts > 0
                             ? "\(item.accounts) account\(item.accounts == 1 ? "" : "s")"
                             : "not found")
                            .foregroundStyle(item.accounts > 0 ? .primary : .secondary)
                            .font(.caption)
                    }
                }
                Text("These read credentials your provider CLIs already wrote — log in with the CLI and they appear here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 420)
        .task {
            detected = await model.detectedLocalProviders()
        }
    }

    private var keyFieldTitle: String {
        guard let spec = selectedSpec?.spec else { return "API key" }
        switch spec.auth {
        case .cookie: return "Session cookie"
        case .header:
            return spec.authHeader.map { "Key (\($0))" } ?? "API key"
        default: return "API key"
        }
    }

    /// ProviderError carries a userMessage; localizedDescription would show
    /// "ProviderError error N." to the user.
    private func message(_ error: Error) -> String {
        (error as? ProviderError)?.userMessage ?? error.localizedDescription
    }

    private func addKey() {
        guard let provider = selectedSpec else { return }
        do {
            _ = try model.addAPIKey(
                newKey.trimmingCharacters(in: .whitespacesAndNewlines),
                provider: provider,
                label: newLabel.isEmpty ? nil : newLabel)
            newKey = ""
            newLabel = ""
            errorText = nil
        } catch {
            errorText = message(error)
        }
    }

    private func addSessionToken(_ provider: any UsageProvider) {
        do {
            try model.addSessionToken(
                sessionToken.trimmingCharacters(in: .whitespacesAndNewlines),
                provider: provider)
            sessionToken = ""
            errorText = nil
        } catch {
            errorText = message(error)
        }
    }
}
#endif
