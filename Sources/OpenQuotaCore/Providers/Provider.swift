import Foundation

/// Where a credential was found. Used for display/debug; actual secrets never
/// leave the credential store.
public enum CredentialSource: String, Codable, Sendable {
    /// User pasted an API key in Settings; stored in Keychain on macOS.
    case userSuppliedKey
    /// Read from a provider CLI configuration file.
    case configFile
    /// macOS Keychain item written by the provider's own app/CLI.
    case keychainItem
    /// Environment variable (mainly for the `openquota` CLI).
    case environment
}

/// A discovered or configured account for a provider.
public struct AccountDescriptor: Sendable, Identifiable {
    public var account: AccountIdentity
    public var source: CredentialSource
    /// True when this account occupies the provider's default home. Badge only —
    /// never drives ordering.
    public var isDefaultHome: Bool
    public var id: String { account.id }

    public init(account: AccountIdentity, source: CredentialSource, isDefaultHome: Bool = false) {
        self.account = account
        self.source = source
        self.isDefaultHome = isDefaultHome
    }
}

/// The adapter contract every provider implements. Three jobs:
/// enumerate accounts → fetch each account's usage → normalize to UsageSnapshot.
public protocol UsageProvider: Sendable {
    /// Stable provider id: "claude", "codex", "openrouter", ...
    var id: String { get }
    var displayName: String { get }
    /// Deep link to the provider's own usage/billing page.
    var dashboardURL: URL? { get }

    /// Accounts this provider can currently see: local credentials + user-supplied keys.
    /// Must be cheap and local — no network.
    func accounts() async throws -> [AccountDescriptor]

    /// Fetch + normalize the latest usage for one account.
    func refresh(account: AccountDescriptor) async throws -> UsageSnapshot
}

/// Errors surfaced to the user; every case must have a short readable message.
public enum ProviderError: Error, Sendable, Equatable {
    case notLoggedIn
    case noAccounts
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(Int)
    case network(String)
    case badResponse(String)
    case timedOut
    /// Nothing to show yet (e.g. Claude Code hasn't written a status line). Not an error.
    case awaitingReading

    public var userMessage: String {
        switch self {
        case .notLoggedIn: Localized.text("Not signed in", "Ikke logget inn")
        case .noAccounts: Localized.text("No accounts configured", "Ingen kontoer er lagt til")
        case .unauthorized:
            Localized.text("Sign-in rejected. Sign in again or replace the key in Settings.",
                           "Påloggingen ble avvist. Logg inn på nytt eller bytt nøkkel i Innstillinger.")
        case .rateLimited(let t):
            t.map { Localized.text("Rate limited, retry in \(Int($0))s", "For mange forespørsler, prøv igjen om \(Int($0)) s") }
                ?? Localized.text("Rate limited", "For mange forespørsler")
        case .serverError(let code): Localized.text("Provider error \(code)", "Feil hos leverandøren (\(code))")
        case .network(let msg): Localized.text("Network: \(msg)", "Nettverk: \(msg)")
        case .badResponse(let msg):
            // Sentence-case messages are written for people; lowercase ones are diagnostics.
            msg.first?.isUppercase == true ? msg
                : Localized.text("Unexpected response (\(msg))", "Uventet svar (\(msg))")
        case .awaitingReading: Localized.text("Waiting for the first reading", "Venter på første måling")
        case .timedOut: Localized.text("Request timed out", "Forespørselen tok for lang tid")
        }
    }
}
