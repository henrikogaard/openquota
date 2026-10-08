import Foundation

/// Stable identity for one provider account. `id` is minted once from an
/// identity key (email, org id, key fingerprint) and never re-derived —
/// mirroring OpenUsage's `provider@hash8` scheme. Uses FNV-1a: this is a
/// local identifier, not a security boundary, so no crypto dep is needed.
public struct AccountIdentity: Codable, Equatable, Hashable, Sendable {
    public var providerID: String
    public var id: String
    /// Human label shown in the UI: email, org name, or a user-supplied nickname.
    public var label: String?
    public var plan: String?

    public init(providerID: String, id: String, label: String? = nil, plan: String? = nil) {
        self.providerID = providerID
        self.id = id
        self.label = label
        self.plan = plan
    }

    /// Mint `provider@ab12cd34` from a stable identity key.
    public static func makeID(providerID: String, identityKey: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in identityKey.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        // %x on Darwin reads only the low 32 bits — produce the full 64-bit
        // hex explicitly or every account id collides to provider@00000000.
        let hex = String(hash, radix: 16)
        let padded = String(repeating: "0", count: max(0, 16 - hex.count)) + hex
        return "\(providerID)@\(padded.prefix(8))"
    }
}

/// Everything the UI needs to render one account card.
public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var account: AccountIdentity
    public var providerID: String
    /// Windows in display order: tightest/shortest first.
    public var windows: [UsageWindow]
    /// Available credits, when the provider exposes a balance.
    public var creditsRemaining: Double?
    public var creditsUnit: String?
    /// When this data was fetched.
    public var fetchedAt: Date
    /// True when kept from a previous successful fetch after a failure.
    public var isStale: Bool
    /// Short, user-readable error when the last refresh failed.
    public var errorMessage: String?
    public var lastAttemptedAt: Date?
    public var credentialSource: CredentialSource?

    /// Empty first-failure/waiting snapshots are not successful readings.
    public var lastSuccessfulAt: Date? {
        windows.contains { $0.used != nil || $0.remaining != nil } || creditsRemaining != nil
            ? fetchedAt : nil
    }

    public init(
        account: AccountIdentity,
        providerID: String,
        windows: [UsageWindow] = [],
        creditsRemaining: Double? = nil,
        creditsUnit: String? = nil,
        fetchedAt: Date = Date(),
        isStale: Bool = false,
        errorMessage: String? = nil,
        lastAttemptedAt: Date? = nil,
        credentialSource: CredentialSource? = nil
    ) {
        self.account = account
        self.providerID = providerID
        self.windows = windows
        self.creditsRemaining = creditsRemaining
        self.creditsUnit = creditsUnit
        self.fetchedAt = fetchedAt
        self.isStale = isStale
        self.errorMessage = errorMessage
        self.lastAttemptedAt = lastAttemptedAt
        self.credentialSource = credentialSource
    }

    /// Worst remaining percent across consumption windows — drives the menu-bar number.
    public var lowestPercentRemaining: Double? {
        windows.compactMap(\.percentRemaining).min()
    }
}
