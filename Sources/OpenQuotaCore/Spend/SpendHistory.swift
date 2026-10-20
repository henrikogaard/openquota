import Foundation

/// Daily token and cost totals per provider and model, kept on this Mac so
/// history outlives the logs (Claude Code deletes its logs after 30 days by
/// default). Holds only counts, costs, model names and dates.
public struct SpendHistory: Codable, Sendable, Equatable {
    public struct Row: Codable, Sendable, Equatable {
        /// Local calendar day, "yyyy-MM-dd".
        public var day: String
        public var provider: SpendProvider
        public var model: String
        public var total: SpendTotal
    }

    public static let maxRows = 200_000
    /// How far the first scan reaches back.
    public static let backfillDays = 365
    /// A first scan that hits a limit retries this much next time.
    static let retryDays = 30

    public var version = 1
    public private(set) var rows: [Row] = []
    /// When the last scan ran; the next one starts the day before.
    public private(set) var scannedThrough: Date?
    /// Days a scan could not read completely (a limit was reached).
    public private(set) var incompleteDays: Set<String> = []

    public init() {}

    public var isEmpty: Bool { rows.isEmpty }

    /// Where the next scan starts: the day before the last scan, or a year
    /// back on the first scan.
    public func nextScanStart(now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        guard let scannedThrough else {
            return calendar.date(byAdding: .day, value: -(Self.backfillDays - 1), to: today)!
        }
        let start = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: scannedThrough))!
        return min(start, today)
    }

    /// Takes a scan that read every log event from `since`. A day's row is
    /// replaced only when the scan saw at least as many requests: logs only
    /// gain events until they are deleted, so a smaller count means data the
    /// logs no longer have, and the saved row is kept.
    public mutating func record(_ summary: SpendSummary, since: Date, calendar: Calendar = .current) {
        func key(_ row: Row) -> String { "\(row.day)|\(row.provider.rawValue)|\(row.model)" }
        var index: [String: Int] = [:]
        for (offset, row) in rows.enumerated() { index[key(row)] = offset }
        for day in summary.days where day.date >= since {
            let row = Row(day: Self.dayKey(day.date, calendar: calendar), provider: day.provider,
                          model: day.model, total: day.total)
            if let offset = index[key(row)] {
                if row.total.events >= rows[offset].total.events { rows[offset] = row }
            } else if rows.count < Self.maxRows {
                index[key(row)] = rows.count
                rows.append(row)
            }
        }
        let now = summary.scannedAt ?? Date()
        let covered = Self.dayKeys(from: since, to: now, calendar: calendar)
        if summary.isPartial {
            incompleteDays.formUnion(covered)
        } else {
            incompleteDays.subtract(covered)
        }
        let today = calendar.startOfDay(for: now)
        let windowDays = calendar.dateComponents([.day], from: since, to: today).day ?? 0
        if summary.isPartial, windowDays > Self.retryDays {
            // A long first scan ran out of budget: retry the recent month
            // next time rather than move on.
            scannedThrough = calendar.date(byAdding: .day, value: -(Self.retryDays - 2), to: today)
        } else {
            scannedThrough = now
        }
    }

    /// Every saved row as a day, for summaries that filter by date.
    public func days(calendar: Calendar = .current) -> [SpendDay] {
        rows.compactMap { row in
            Self.date(row.day, calendar: calendar).map {
                SpendDay(date: $0, provider: row.provider, model: row.model, total: row.total)
            }
        }
    }

    public var firstDay: String? { rows.map(\.day).min() }

    // MARK: Queries

    public func total(
        _ range: SpendHistoryRange, provider: SpendProvider? = nil, now: Date = Date(),
        calendar: Calendar = .current
    ) -> SpendTotal {
        rows(in: range, now: now, calendar: calendar)
            .filter { provider == nil || $0.provider == provider }
            .reduce(into: SpendTotal()) { $0.add($1.total) }
    }

    /// Totals per provider per bucket (day, week or month, by range).
    public func buckets(
        _ range: SpendHistoryRange, now: Date = Date(), calendar: Calendar = .current
    ) -> [SpendBucket] {
        var sums: [SpendBucket.ID: SpendBucket] = [:]
        for row in rows(in: range, now: now, calendar: calendar) {
            guard let date = Self.date(row.day, calendar: calendar),
                  let start = calendar.dateInterval(of: range.granularity, for: date)?.start else { continue }
            let id = SpendBucket.ID(start: start, provider: row.provider)
            sums[id, default: SpendBucket(start: start, provider: row.provider, total: SpendTotal())].total.add(row.total)
        }
        return sums.values.sorted { ($0.start, $0.provider.rawValue) < ($1.start, $1.provider.rawValue) }
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

    /// Whether any incomplete day falls in the range.
    public func hasIncompleteDays(_ range: SpendHistoryRange, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard let start = range.start(now: now, firstDay: firstDay, calendar: calendar) else { return false }
        let first = Self.dayKey(start, calendar: calendar)
        return incompleteDays.contains { $0 >= first }
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

    static func dayKeys(from start: Date, to end: Date, calendar: Calendar) -> Set<String> {
        var keys = Set<String>()
        var day = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while day <= last, keys.count <= backfillDays + 1 {
            keys.insert(dayKey(day, calendar: calendar))
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        return keys
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
        public let provider: SpendProvider
    }
    public let start: Date
    public let provider: SpendProvider
    public var total: SpendTotal
    public var id: ID { ID(start: start, provider: provider) }
}

public struct SpendModelTotal: Sendable, Identifiable {
    public let provider: SpendProvider
    public let model: String
    public var total: SpendTotal
    public var id: String { "\(provider.rawValue)|\(model)" }
}

/// The saved history file: private to the user, bounded in size.
public struct SpendHistoryStore: Sendable {
    static let maxBytes = 64 * 1_048_576
    public let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> SpendHistory {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return SpendHistory() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxBytes + 1), data.count <= Self.maxBytes,
              let history = try? JSONDecoder.openQuota.decode(SpendHistory.self, from: data) else {
            return SpendHistory()
        }
        return history
    }

    public func save(_ history: SpendHistory) throws {
        try PrivateFile.write(JSONEncoder.openQuota.encode(history), to: url)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}
