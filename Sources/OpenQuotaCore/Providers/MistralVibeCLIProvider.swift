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

    init(http: any HTTPClient, files: LocalCredentialFiles,
         environment: [String: String]? = nil, keychain: (@Sendable () throws -> String?)? = nil) {
        self.http = http
        let systemHome = files.home == FileManager.default.homeDirectoryForCurrentUser
        let env = environment ?? (systemHome ? ProcessInfo.processInfo.environment : [:])
        credential = {
            if let key = env["MISTRAL_API_KEY"], !key.isEmpty { return (key, .environment) }
            let dir = env["VIBE_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                ?? files.home.appendingPathComponent(".vibe")
            if let contents = LocalCredentialFiles(home: dir).readText(".env"),
               let key = Self.savedKey(contents) { return (key, .configFile) }
            let key = try keychain.map { try $0() } ?? (systemHome ? Self.keychainKey() : nil)
            return key.map { ($0, .keychainItem) }
        }
    }

    private static func savedKey(_ contents: String) -> String? {
        // Keys have no whitespace. Accept Vibe's optional export, quotes and trailing comment.
        let pattern = #"^(?:export\s+)?MISTRAL_API_KEY\s*=\s*(?:'([^'\s]+)'|"([^"\s]+)"|([^\s'"]+))(?:\s+#.*|\s*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for line in contents.components(separatedBy: .newlines) {
            let text = line.trimmingCharacters(in: .whitespaces) as NSString
            guard let match = regex.firstMatch(in: text as String, range: NSRange(location: 0, length: text.length)) else { continue }
            for i in 1..<match.numberOfRanges where match.range(at: i).location != NSNotFound {
                return text.substring(with: match.range(at: i))
            }
        }
        return nil
    }

    private static func keychainKey() throws -> String? {
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
                return key
            }
            guard status == errSecItemNotFound else {
                throw ProviderError.badResponse(Localized.text("Vibe Keychain item unavailable.", "Nøkkelringoppføringen for Vibe er utilgjengelig."))
            }
        #endif
        return nil
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
        var enabled = budget.payg_enabled
        if enabled == nil {
            struct Subscription: Decodable { let vibe_payg_enabled: Bool? }
            let request = HTTPRequest(url: URL(string: "https://api.mistral.ai/v1/billing/subscription")!,
                                      headers: ["Authorization": "Bearer \(key)"], allowsRedirects: false)
            if let response = try? await http.send(request), let data = try? requireOK(response) {
                enabled = (try? JSONDecoder().decode(Subscription.self, from: data))?.vibe_payg_enabled
            }
            try Task.checkCancellation()
        }
        let payg = enabled.map {
            $0 ? Localized.text(" · PAYG on", " · betaling per bruk på") : Localized.text(" · PAYG off", " · betaling per bruk av")
        } ?? ""
        return UsageSnapshot(account: account.account, providerID: id, windows: [
            UsageWindow(id: "\(id).monthly", label: label + payg, used: budget.usage_percentage,
                        limit: 100, unit: "%", resetsAt: MistralSubscriptionParser.parseDate(budget.reset_at)),
        ])
    }
}
