import Foundation

/// Daily token and cost totals per source and model, as saved by
/// `LocalSpendScanner`, with the queries the History tab needs.
public struct SpendHistory: Sendable, Equatable {
    public struct Row: Sendable, Equatable {
        /// Local calendar day, "yyyy-MM-dd".
        public var day: String
        public var provider: SpendProvider
        /// `SpendSource.key`.
        public var source: String
        public var model: String
        public var total: SpendTotal
    }

    public private(set) var rows: [Row] = []

    public init() {}

    public init(days: [SpendDay], calendar: Calendar = .current) {
        rows = days.map {
            Row(day: Self.dayKey($0.date, calendar: calendar), provider: $0.provider,
                source: $0.source, model: $0.model, total: $0.total)
        }
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var firstDay: String? { rows.map(\.day).min() }

    public func total(
        _ range: SpendHistoryRange, provider: SpendProvider? = nil, source: String? = nil,
        now: Date = Date(), calendar: Calendar = .current
    ) -> SpendTotal {
        rows(in: range, now: now, calendar: calendar)
            .filter { (provider == nil || $0.provider == provider) && (source == nil || $0.source == source) }
            .reduce(into: SpendTotal()) { $0.add($1.total) }
    }

    /// Sources with usage in the range, largest cost (then tokens) first.
    public func sources(
        _ range: SpendHistoryRange, now: Date = Date(), calendar: Calendar = .current
    ) -> [SpendSourceTotal] {
        var sums: [String: SpendSourceTotal] = [:]
        for row in rows(in: range, now: now, calendar: calendar) {
            sums[row.source, default: SpendSourceTotal(source: row.source, provider: row.provider, total: SpendTotal())]
                .total.add(row.total)
        }
        return sums.values.filter { $0.total.tokens > 0 || $0.total.dollars > 0 }.sorted {
            if $0.total.dollars != $1.total.dollars { return $0.total.dollars > $1.total.dollars }
            if $0.total.tokens != $1.total.tokens { return $0.total.tokens > $1.total.tokens }
            return $0.source < $1.source
        }
    }

    /// Totals per source per bucket (day, week or month, by range).
    public func buckets(
        _ range: SpendHistoryRange, now: Date = Date(), calendar: Calendar = .current
    ) -> [SpendBucket] {
        var sums: [SpendBucket.ID: SpendBucket] = [:]
        for row in rows(in: range, now: now, calendar: calendar) {
            guard let date = Self.date(row.day, calendar: calendar),
                  let start = calendar.dateInterval(of: range.granularity, for: date)?.start else { continue }
            let id = SpendBucket.ID(start: start, source: row.source)
            sums[id, default: SpendBucket(start: start, source: row.source, provider: row.provider, total: SpendTotal())]
                .total.add(row.total)
        }
        return sums.values.sorted { ($0.start, $0.source) < ($1.start, $1.source) }
    }

    /// Models by cost (then tokens) within the range.
    public func topModels(
        _ range: SpendHistoryRange, limit: Int = 8, now: Date = Date(), calendar: Calendar = .current
    ) -> [SpendModelTotal] {
        var sums: [String: SpendModelTotal] = [:]
        for row in rows(in: range, now: now, calendar: calendar) {
            let id = "\(row.provider.rawValue)|\(row.model)"
            sums[id, default: SpendModelTotal(provider: row.provider, model: row.model, total: SpendTotal())]
                .total.add(row.total)
        }
        // Rows with no tokens (e.g. Claude's synthetic error messages) say nothing.
        return Array(sums.values.filter { $0.total.tokens > 0 || $0.total.dollars > 0 }.sorted {
            ($0.total.dollars, $0.total.tokens) > ($1.total.dollars, $1.total.tokens)
        }.prefix(limit))
    }

    private func rows(in range: SpendHistoryRange, now: Date, calendar: Calendar) -> [Row] {
        guard let start = range.start(now: now, firstDay: firstDay, calendar: calendar) else { return [] }
        let first = Self.dayKey(start, calendar: calendar)
        let last = Self.dayKey(now, calendar: calendar)
        return rows.filter { $0.day >= first && $0.day <= last }
    }

    // MARK: Day keys

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(_ key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }
}

public enum SpendHistoryRange: String, CaseIterable, Sendable {
    case days30, days90, year, all

    /// Bars are days for 30 and 90 days, weeks for a year, months for all.
    public var granularity: Calendar.Component {
        switch self {
        case .days30, .days90: .day
        case .year: .weekOfYear
        case .all: .month
        }
    }

    /// First day included; nil for "all" with no history.
    func start(now: Date, firstDay: String?, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        switch self {
        case .days30: return calendar.date(byAdding: .day, value: -29, to: today)
        case .days90: return calendar.date(byAdding: .day, value: -89, to: today)
        case .year: return calendar.date(byAdding: .day, value: -364, to: today)
        case .all: return firstDay.flatMap { SpendHistory.date($0, calendar: calendar) }
        }
    }
}

public struct SpendBucket: Sendable, Identifiable {
    public struct ID: Hashable, Sendable {
        public let start: Date
        public let source: String
    }
    public let start: Date
    public let source: String
    public let provider: SpendProvider
    public var total: SpendTotal
    public var id: ID { ID(start: start, source: source) }
}

public struct SpendSourceTotal: Sendable, Identifiable {
    public let source: String
    public let provider: SpendProvider
    public var total: SpendTotal
    public var id: String { source }
}

public struct SpendModelTotal: Sendable, Identifiable {
    public let provider: SpendProvider
    public let model: String
    public var total: SpendTotal
    public var id: String { "\(provider.rawValue)|\(model)" }
}
