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

    public func snapshot(
        account: AccountIdentity, now: Date = Date(), staleAfter: TimeInterval = 600
    ) throws -> UsageSnapshot {
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
            fetchedAt: recordedAt, isStale: now.timeIntervalSince(recordedAt) > staleAfter)
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

/// Only the documented Antigravity CLI status-line quota and account fields
/// are retained. Never stores cwd, conversation ids, transcripts, prompts, or
/// workspace paths.
/// Reference: https://antigravity.google/docs/cli/statusline
public struct AntigravityUsageReading: Codable, Sendable, Equatable {
    public struct Bucket: Codable, Sendable, Equatable {
        public let id: String
        public let remainingFraction: Double?
        public let remainingAmount: Double?
        public let resetsAt: Date?

        public init(
            id: String,
            remainingFraction: Double? = nil,
            remainingAmount: Double? = nil,
            resetsAt: Date? = nil
        ) {
            self.id = id
            self.remainingFraction = remainingFraction
            self.remainingAmount = remainingAmount
            self.resetsAt = resetsAt
        }
    }

    public static let maxBuckets = 32

    public let recordedAt: Date
    public let planTier: String?
    public let email: String?
    public let buckets: [Bucket]

    public init(
        recordedAt: Date,
        planTier: String? = nil,
        email: String? = nil,
        buckets: [Bucket]
    ) {
        self.recordedAt = recordedAt
        self.planTier = planTier
        self.email = email
        self.buckets = buckets
    }

    public static func capture(_ input: Data, now: Date = Date()) throws -> Self? {
        struct RawBucket: Decodable {
            let remaining_fraction: Double?
            let remaining_amount: Double?
            let reset_time: String?
            let reset_in_seconds: Double?
            let disabled: Bool?
        }
        struct Input: Decodable {
            let quota: [String: RawBucket]?
            let plan_tier: String?
            let email: String?
        }
        guard input.count <= 1_048_576 else {
            throw ProviderError.badResponse(Localized.text(
                "Antigravity status input too large",
                "Statusdata fra Antigravity er for store"))
        }
        let decoded = try JSONDecoder().decode(Input.self, from: input)
        guard let rawQuota = decoded.quota, !rawQuota.isEmpty else { return nil }
        guard rawQuota.count <= maxBuckets else {
            throw ProviderError.badResponse(Localized.text(
                "Too many Antigravity quota buckets",
                "For mange kvoter fra Antigravity"))
        }

        var parsedBuckets: [Bucket] = []
        for id in rawQuota.keys.sorted() {
            guard let raw = rawQuota[id] else { continue }
            if raw.disabled == true { continue }
            let trimmedID = id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedID.isEmpty, trimmedID.utf8.count <= 128 else {
                throw ProviderError.badResponse(Localized.text(
                    "Invalid Antigravity quota window",
                    "Ugyldig kvotevindu fra Antigravity"))
            }
            if let fraction = raw.remaining_fraction {
                guard fraction.isFinite, (0...1).contains(fraction) else {
                    throw ProviderError.badResponse(Localized.text(
                        "Invalid Antigravity quota window",
                        "Ugyldig kvotevindu fra Antigravity"))
                }
            }
            if let amount = raw.remaining_amount {
                guard amount.isFinite, amount >= 0 else {
                    throw ProviderError.badResponse(Localized.text(
                        "Invalid Antigravity quota window",
                        "Ugyldig kvotevindu fra Antigravity"))
                }
            }
            if let seconds = raw.reset_in_seconds {
                guard seconds.isFinite, seconds >= 0 else {
                    throw ProviderError.badResponse(Localized.text(
                        "Invalid Antigravity quota window",
                        "Ugyldig kvotevindu fra Antigravity"))
                }
            }

            let resetsAt: Date?
            if let resetTime = raw.reset_time, let parsed = parseISO8601(resetTime) {
                resetsAt = parsed
            } else if let seconds = raw.reset_in_seconds {
                resetsAt = now.addingTimeInterval(seconds)
            } else {
                resetsAt = nil
            }

            let fraction: Double?
            if let rawFraction = raw.remaining_fraction {
                fraction = rawFraction
            } else if raw.remaining_amount == nil, resetsAt != nil {
                // Go/proto3 JSON may omit a zero remaining_fraction when a bucket is exhausted.
                fraction = 0
            } else {
                fraction = nil
            }
            guard fraction != nil || raw.remaining_amount != nil else { continue }
            parsedBuckets.append(Bucket(
                id: trimmedID,
                remainingFraction: fraction,
                remainingAmount: raw.remaining_amount,
                resetsAt: resetsAt))
        }

        guard !parsedBuckets.isEmpty else { return nil }
        let planTier = sanitizedPlan(decoded.plan_tier)
        let email = sanitizedEmail(decoded.email)
        let reading = Self(recordedAt: now, planTier: planTier, email: email, buckets: parsedBuckets)
        try reading.validate()
        return reading
    }

    public func snapshot(
        account: AccountIdentity, now: Date = Date(), staleAfter: TimeInterval = 600
    ) throws -> UsageSnapshot {
        try validate()
        guard recordedAt <= now.addingTimeInterval(60) else {
            throw ProviderError.badResponse(Localized.text(
                "Antigravity reading has a future timestamp",
                "Antigravity-målingen har et tidspunkt i fremtiden"))
        }
        var windows: [UsageWindow] = []
        for bucket in buckets {
            let windowID = "antigravity.\(Self.slug(bucket.id))"
            let label = Self.displayLabel(for: bucket.id)
            if let fraction = bucket.remainingFraction {
                let used = min(max((1 - fraction) * 100, 0), 100)
                windows.append(UsageWindow(
                    id: windowID, label: label, kind: .consumption,
                    used: used, limit: 100, unit: "%", resetsAt: bucket.resetsAt))
            } else if let amount = bucket.remainingAmount {
                windows.append(UsageWindow(
                    id: windowID, label: label, kind: .credits,
                    remaining: amount, resetsAt: bucket.resetsAt))
            }
        }
        guard !windows.isEmpty else {
            throw ProviderError.badResponse(Localized.text(
                "No Antigravity usage reported yet",
                "Antigravity har ikke rapportert bruk ennå"))
        }
        var identity = account
        identity.plan = planTier ?? identity.plan
        identity.email = email ?? identity.email
        return UsageSnapshot(
            account: identity, providerID: "antigravity", windows: windows,
            fetchedAt: recordedAt, isStale: now.timeIntervalSince(recordedAt) > staleAfter)
    }

    private func validate() throws {
        guard buckets.count <= Self.maxBuckets else {
            throw ProviderError.badResponse(Localized.text(
                "Too many Antigravity quota buckets",
                "For mange kvoter fra Antigravity"))
        }
        for bucket in buckets {
            guard !bucket.id.isEmpty, bucket.id.utf8.count <= 128 else {
                throw ProviderError.badResponse(Localized.text(
                    "Invalid Antigravity quota window",
                    "Ugyldig kvotevindu fra Antigravity"))
            }
            if let fraction = bucket.remainingFraction {
                guard fraction.isFinite, (0...1).contains(fraction) else {
                    throw ProviderError.badResponse(Localized.text(
                        "Invalid Antigravity quota window",
                        "Ugyldig kvotevindu fra Antigravity"))
                }
            }
            if let amount = bucket.remainingAmount {
                guard amount.isFinite, amount >= 0 else {
                    throw ProviderError.badResponse(Localized.text(
                        "Invalid Antigravity quota window",
                        "Ugyldig kvotevindu fra Antigravity"))
                }
            }
            guard bucket.remainingFraction != nil || bucket.remainingAmount != nil else {
                throw ProviderError.badResponse(Localized.text(
                    "Invalid Antigravity quota window",
                    "Ugyldig kvotevindu fra Antigravity"))
            }
        }
    }

    /// Formats a documented status-line quota bucket id such as "gemini-weekly"
    /// or "claude-gpt-5h" into a concise display label.
    public static func displayLabel(for bucketID: String) -> String {
        let rawParts = bucketID
            .split(whereSeparator: { $0 == "-" || $0 == "_" || $0.isWhitespace })
            .map(String.init)
        guard !rawParts.isEmpty else { return bucketID }

        let periodMap: [String: String] = [
            "weekly": "Week", "week": "Week", "7d": "Week",
            "5h": "5h", "5hr": "5h", "5hours": "5h",
            "daily": "Day", "day": "Day", "24h": "Day",
            "monthly": "Month", "month": "Month", "30d": "Month",
        ]
        let acronyms: [String: String] = [
            "ai": "AI", "gpt": "GPT", "oss": "OSS", "g1": "AI", "cli": "CLI",
        ]

        var parts = rawParts
        var period: String?
        if let last = parts.last?.lowercased(), let mapped = periodMap[last] {
            period = mapped
            parts.removeLast()
        }
        let prefix = parts.map { token -> String in
            let lower = token.lowercased()
            if let acronym = acronyms[lower] { return acronym }
            guard let first = token.first else { return token }
            return first.uppercased() + token.dropFirst()
        }.joined(separator: " ")

        switch (prefix.isEmpty, period) {
        case (false, let period?): return "\(prefix) · \(period)"
        case (true, let period?): return period
        case (false, nil): return prefix
        case (true, nil): return bucketID
        }
    }

    private static func slug(_ value: String) -> String {
        value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
    }

    private static func sanitizedPlan(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, trimmed.utf8.count <= 128,
              !trimmed.contains(where: \.isNewline) else { return nil }
        return trimmed
    }

    private static func sanitizedEmail(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.contains("@"), trimmed.utf8.count <= 254,
              !trimmed.contains(where: \.isWhitespace) else { return nil }
        return trimmed
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }
}
