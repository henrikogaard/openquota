#if os(macOS)
import SwiftUI
import OpenQuotaCore

/// Settings: manage API keys for key-based providers. Local-credential
/// providers (Claude, Codex, …) appear here once their adapters land.
struct SettingsView: View {
    var model: AppModel
    @State private var newKey = ""
    @State private var newLabel = ""
    @State private var selectedProvider = "openrouter"
    @State private var errorText: String?

    var body: some View {
        Form {
            Section("Add API key") {
                Picker("Provider", selection: $selectedProvider) {
                    ForEach(model.specProviders(), id: \.id) { provider in
                        Text(provider.displayName).tag(provider.id)
                    }
                }
                SecureField("API key", text: $newKey)
                TextField("Label (optional)", text: $newLabel)
                HStack {
                    Spacer()
                    Button("Add Key") { addKey() }
                        .disabled(newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let errorText {
                    Text(errorText).foregroundStyle(.red).font(.caption)
                }
            }
            Section("Notes") {
                Text("Keys are stored in your login Keychain. Each key becomes its own account row in the menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440, height: 300)
    }

    private func addKey() {
        guard let provider = model.specProviders().first(where: { $0.id == selectedProvider }) else { return }
        do {
            _ = try model.addAPIKey(
                newKey.trimmingCharacters(in: .whitespacesAndNewlines),
                provider: provider,
                label: newLabel.isEmpty ? nil : newLabel)
            newKey = ""
            newLabel = ""
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}
#endif
