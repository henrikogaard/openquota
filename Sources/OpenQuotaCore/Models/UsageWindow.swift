import Foundation

/// One quota window a provider reports (e.g. "5-hour", "Weekly", "Monthly", "Credits").
public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// A time-boxed consumption allowance (session, weekly, monthly).
        case consumption
        /// A balance of spendable credits / currency.
        case credits
        /// A count of requests or tokens.
        case requests
    }

    public var id: String
    /// Short label shown in the popover: "5h", "Week", "Month", "Credits".
    public var label: String
    public var kind: Kind
    /// Amount consumed, when the provider reports it (percent 0-100 for consumption
    /// windows, absolute units otherwise).
    public var used: Double?
    /// The window's ceiling, same unit as `used`. Nil when unknown/unbounded.
    public var limit: Double?
    /// Absolute remaining amount, when directly reported.
    public var remaining: Double?
    /// Unit label for absolute values ("credits", "$", "requests"). Nil for percent.
    public var unit: String?
    /// When the window resets, if reported.
    public var resetsAt: Date?

    public init(
        id: String,
        label: String,
        kind: Kind = .consumption,
        used: Double? = nil,
        limit: Double? = nil,
        remaining: Double? = nil,
        unit: String? = nil,
        resetsAt: Date? = nil
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.unit = unit
        self.resetsAt = resetsAt
    }

    /// 0...1 fraction consumed, used for meters. Prefers direct used/limit,
    /// falls back to 1 - remaining/limit.
    public var fractionUsed: Double? {
        if let used, let limit, limit > 0 {
            return min(max(used / limit, 0), 1)
        }
        if let used, limit == nil, used <= 1.0 {
            // Provider reports a 0-1 (or 0-100 %) fraction with no explicit limit.
            return used <= 1.0 ? min(max(used, 0), 1) : min(max(used / 100, 0), 1)
        }
        if let remaining, let limit, limit > 0 {
            return min(max(1 - remaining / limit, 0), 1)
        }
        return nil
    }

    /// Percent remaining 0-100 when derivable.
    public var percentRemaining: Double? {
        fractionUsed.map { (1 - $0) * 100 }
    }
}
