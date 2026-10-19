import Foundation

/// Only the documented Claude Code status-line fields are retained.
public struct ClaudeUsageReading: Codable, Sendable, Equatable {
    public struct Window: Codable, Sendable, Equatable {
        public let usedPercentage: Double
        public let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case usedPercentage = "used_percentage"
            case resetsAt = "resets_at"
        }
    }

    public let recordedAt: Date
    public let fiveHour: Window?
    public let sevenDay: Window?

    public static func capture(_ input: Data, now: Date = Date()) throws -> Self? {
        struct Input: Decodable {
            struct Limits: Decodable {
                let five_hour: Window?
                let seven_day: Window?
            }
            let rate_limits: Limits?
        }
        guard input.count <= 1_048_576 else {
            throw ProviderError.badResponse(Localized.text("Claude status input too large", "Statusdata fra Claude er for store"))
        }
        let decoded = try JSONDecoder().decode(Input.self, from: input)
        let reading = Self(
            recordedAt: now,
            fiveHour: decoded.rate_limits?.five_hour,
            sevenDay: decoded.rate_limits?.seven_day)
        try reading.validate()
        return reading.fiveHour == nil && reading.sevenDay == nil ? nil : reading
    }

    public func snapshot(account: AccountIdentity, now: Date = Date()) throws -> UsageSnapshot {
        try validate()
        guard recordedAt <= now.addingTimeInterval(60) else {
            throw ProviderError.badResponse(Localized.text("Claude reading has a future timestamp", "Claude-målingen har et tidspunkt i fremtiden"))
        }
        let windows = [
            usageWindow(fiveHour, id: "claude.5h", label: "5h"),
            usageWindow(sevenDay, id: "claude.week", label: "Week"),
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw ProviderError.badResponse(Localized.text("No Claude usage reported yet", "Claude har ikke rapportert bruk ennå")) }
        return UsageSnapshot(
            account: account, providerID: "claude", windows: windows,
            fetchedAt: recordedAt, isStale: now.timeIntervalSince(recordedAt) > 600)
    }

    private func validate() throws {
        for window in [fiveHour, sevenDay].compactMap({ $0 }) {
            guard window.usedPercentage.isFinite, (0...100).contains(window.usedPercentage),
                  window.resetsAt.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                throw ProviderError.badResponse(Localized.text("Invalid Claude usage window", "Ugyldig bruksvindu fra Claude"))
            }
        }
    }

    private func usageWindow(_ window: Window?, id: String, label: String) -> UsageWindow? {
        guard let window else { return nil }
        return UsageWindow(
            id: id, label: label, kind: .consumption, used: window.usedPercentage,
            limit: 100, unit: "%", resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)))
    }
}

/// Which Claude client sent a status-line reading, when it says so. Claude
/// Desktop starts Claude Code with its own signed-in account in the
/// environment, and that account can differ from the CLI login in the same
/// config directory. Tagged readings get their own file and card, so one
/// account never overwrites another. Only a hash of the account ids is kept.
/// Untagged readings (the CLI) keep using `reading.json`.
public struct ClaudeReadingSource: Equatable, Hashable, Sendable {
    /// Add a case here to tag another client; the file name and card follow.
    public enum Client: String, CaseIterable, Sendable {
        case desktop

        public var displayName: String {
            switch self {
            case .desktop: Localized.text("Desktop", "Desktop")
            }
        }
    }

    public static let maxPerConnection = 8

    public let client: Client
    /// Eight lowercase hex characters.
    public let accountHash: String

    public init?(client: Client, accountHash: String) {
        guard accountHash.count == 8,
              accountHash.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        self.client = client
        self.accountHash = accountHash
    }

    /// The source for a bridge run, from the environment Claude Code passes
    /// to its status-line command. Nil means an untagged (CLI) reading.
    public static func from(environment: [String: String]) -> Self? {
        guard environment["CLAUDE_CODE_ENTRYPOINT"] == "claude-desktop",
              let account = environment["CLAUDE_CODE_ACCOUNT_UUID"], !account.isEmpty else {
            return nil
        }
        let organization = environment["CLAUDE_CODE_ORGANIZATION_UUID"] ?? ""
        let id = AccountIdentity.makeID(providerID: "claude", identityKey: "\(account):\(organization)")
        return Self(client: .desktop, accountHash: String(id.suffix(8)))
    }

    public init?(fileName: String) {
        let prefix = "reading-", suffix = ".json"
        guard fileName.hasPrefix(prefix), fileName.hasSuffix(suffix) else { return nil }
        let parts = fileName.dropFirst(prefix.count).dropLast(suffix.count)
            .split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, let client = Client(rawValue: String(parts[0])) else { return nil }
        self.init(client: client, accountHash: String(parts[1]))
    }

    public var fileName: String { "reading-\(client.rawValue)-\(accountHash).json" }
}

/// Maps account/rateLimits/read results, not the private ChatGPT HTTP response.
public enum CodexUsageMapping {
    private struct Response: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
    }

    private struct Bucket: Decodable {
        let limitId: String?
        let limitName: String?
        let primary: Window?
        let secondary: Window?
        let planType: String?
        let credits: Credits?
    }

    private struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int?
        let resetsAt: Double?
    }

    private struct Credits: Decodable {
        let balance: Double?
        let unlimited: Bool?

        enum CodingKeys: String, CodingKey { case balance, unlimited }

        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            unlimited = try c.decodeIfPresent(Bool.self, forKey: .unlimited)
            if let number = try? c.decode(Double.self, forKey: .balance) {
                balance = number
            } else if let string = try c.decodeIfPresent(String.self, forKey: .balance) {
                guard let number = Double(string), number.isFinite else {
                    throw ProviderError.badResponse(Localized.text("Invalid Codex credit balance", "Ugyldig kredittsaldo fra Codex"))
                }
                balance = number
            } else {
                balance = nil
            }
        }
    }

    public static func snapshot(
        result: Data, account: AccountIdentity, now: Date = Date()
    ) throws -> UsageSnapshot {
        guard result.count <= 1_048_576 else {
            throw ProviderError.badResponse(Localized.text("Codex response too large", "Svaret fra Codex er for stort"))
        }
        let response = try JSONDecoder().decode(Response.self, from: result)
        let buckets: [(String, Bucket)]
        if let all = response.rateLimitsByLimitId, !all.isEmpty {
            guard all.count <= 32 else { throw ProviderError.badResponse(Localized.text("Too many Codex quota buckets", "For mange kvoter fra Codex")) }
            buckets = all.sorted { $0.key < $1.key }
        } else if let one = response.rateLimits {
            buckets = [(one.limitId ?? "codex", one)]
        } else {
            throw ProviderError.badResponse(Localized.text("No Codex usage reported", "Codex har ikke rapportert bruk"))
        }
        var windows: [UsageWindow] = []
        for (key, bucket) in buckets {
            for (slot, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
                guard let window else { continue }
                guard window.usedPercent.isFinite, (0...100).contains(window.usedPercent),
                      window.resetsAt.map({ $0.isFinite && $0 >= 0 }) ?? true else {
                    throw ProviderError.badResponse(Localized.text("Invalid Codex usage window", "Ugyldig bruksvindu fra Codex"))
                }
                let duration = window.windowDurationMins.flatMap { minutes -> String? in
                    guard minutes > 0 else { return nil }
                    if minutes % 10_080 == 0 { return "\(minutes / 10_080)w" }
                    if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
                    if minutes % 60 == 0 { return "\(minutes / 60)h" }
                    return "\(minutes)m"
                } ?? slot.capitalized
                let label = buckets.count > 1 ? "\(bucket.limitName ?? key) · \(duration)" : duration
                windows.append(UsageWindow(
                    id: "codex.\(key).\(slot)", label: label, kind: .consumption,
                    used: window.usedPercent, limit: 100, unit: "%",
                    resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:))))
            }
        }
        // Credit balances may repeat across buckets; never add them together.
        let primary = buckets.first(where: { $0.0 == "codex" })?.1
            ?? (buckets.count == 1 ? buckets.first?.1 : nil)
        let balance = primary?.credits?.unlimited == true ? nil : primary?.credits?.balance
        guard !windows.isEmpty || balance != nil else {
            throw ProviderError.badResponse(Localized.text("No Codex usage windows or credit balance", "Codex rapporterte verken bruk eller kredittsaldo"))
        }
        var identity = account
        identity.plan = primary?.planType ?? identity.plan
        return UsageSnapshot(
            account: identity, providerID: "codex", windows: windows,
            creditsRemaining: balance, creditsUnit: balance == nil ? nil : "credits", fetchedAt: now)
    }
}
