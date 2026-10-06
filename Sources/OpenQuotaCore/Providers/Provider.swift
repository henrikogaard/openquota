import Foundation

/// Where a credential was found. Used for display/debug; actual secrets never
/// leave the credential store.
public enum CredentialSource: String, Codable, Sendable {
    /// User pasted an API key in Settings; stored in Keychain on macOS.
    case userSuppliedKey
    /// Read from the provider CLI's config dir (`~/.codex/auth.json` etc).
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
    /// True when this account occupies the provider's "default home" (e.g. the
    /// login currently in `~/.claude`). Badge only — never drives ordering.
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

    public var userMessage: String {
        switch self {
        case .notLoggedIn: "Not logged in"
        case .noAccounts: "No accounts configured"
        case .unauthorized: "Credentials rejected (re-login?)"
        case .rateLimited(let t): t.map { "Rate limited, retry in \(Int($0))s" } ?? "Rate limited"
        case .serverError(let code): "Provider error \(code)"
        case .network(let msg): "Network: \(msg)"
        case .badResponse(let msg): "Bad response: \(msg)"
        case .timedOut: "Request timed out"
        }
    }
}
