import Foundation
#if os(macOS)
import LocalAuthentication
import Security
#endif

/// Vibe's monthly Code allowance, using the same billing route as its CLI footer.
struct MistralVibeCLIProvider: UsageProvider {
    let id = "mistral-vibe-cli"
    let displayName = "Mistral Vibe CLI"
    let dashboardURL = URL(string: "https://admin.mistral.ai/subscription")
    let http: any HTTPClient
    let credential: @Sendable () throws -> (String, CredentialSource)?

    init(http: any HTTPClient, files: LocalCredentialFiles) {
        self.http = http
        credential = {
            #if os(macOS)
            // Vibe owns this item. Never migrate it or prompt during polling.
            let context = LAContext()
            context.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "ai.mistral.vibe",
                kSecAttrAccount as String: "MISTRAL_API_KEY",
                kSecUseAuthenticationContext as String: context,
                kSecReturnData as String: true,
            ]
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess, let data = item as? Data,
               let key = String(data: data, encoding: .utf8) {
                return (key, .keychainItem)
            }
            guard status == errSecItemNotFound else {
                throw ProviderError.badResponse(Localized.text("Vibe Keychain item unavailable.", "Nøkkelringoppføringen for Vibe er utilgjengelig."))
            }
            #endif
            for line in (files.readText(".vibe/.env") ?? "").split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1)
                if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == "MISTRAL_API_KEY" {
                    return (parts[1].trimmingCharacters(in: .whitespaces)
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'")), .configFile)
                }
            }
            return nil
        }
    }

    init(http: any HTTPClient, credential: @escaping @Sendable () throws -> (String, CredentialSource)?) {
        self.http = http
        self.credential = credential
    }

    private func connection() throws -> (String, AccountDescriptor)? {
        guard let (key, source) = try credential(), !key.isEmpty, key != "vibe-cli-oidc",
              key.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
        let identity = AccountIdentity(providerID: id, id: AccountIdentity.makeID(providerID: id, identityKey: key),
                                       label: displayName)
        return (key, AccountDescriptor(account: identity, source: source, isDefaultHome: true))
    }

    func accounts() async throws -> [AccountDescriptor] {
        try connection().map { [$0.1] } ?? []
    }

    private struct Billing: Decodable {
        struct Budget: Decodable {
            let initial_budget: Double
            let usage_percentage: Double
            let reset_at: String?
            let payg_enabled: Bool?
        }
        let vibe_budget: Budget?
    }

    func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let (key, current) = try connection(), current.id == account.id else { throw ProviderError.notLoggedIn }
        let response = try await http.send(HTTPRequest(
            url: URL(string: "https://api.mistral.ai/v1/billing/budget")!,
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"], allowsRedirects: false))
        if response.status == 403 {
            throw ProviderError.badResponse(Localized.text("This account cannot view Vibe billing usage.",
                                                         "Denne kontoen har ikke tilgang til Vibe-forbruk."))
        }
        let data = try requireOK(response)
        guard let budget = (try? JSONDecoder().decode(Billing.self, from: data))?.vibe_budget,
              budget.initial_budget > 0, budget.usage_percentage >= 0 else {
            throw ProviderError.badResponse(Localized.text("Mistral reported no monthly Vibe Code allowance.",
                                                         "Mistral rapporterte ingen månedskvote for Vibe Code."))
        }
        let label = Localized.text("Vibe Code · monthly", "Vibe Code · månedlig")
        let payg = budget.payg_enabled.map {
            $0 ? Localized.text(" · PAYG on", " · betaling per bruk på") : Localized.text(" · PAYG off", " · betaling per bruk av")
        } ?? ""
        return UsageSnapshot(account: account.account, providerID: id, windows: [
            UsageWindow(id: "\(id).monthly", label: label + payg, used: budget.usage_percentage,
                        limit: 100, unit: "%", resetsAt: MistralSubscriptionParser.parseDate(budget.reset_at)),
        ])
    }
}
