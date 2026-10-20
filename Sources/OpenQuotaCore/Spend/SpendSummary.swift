import Foundation

public enum SpendProvider: String, CaseIterable, Sendable, Codable {
    case claude, codex
}

public enum SpendPeriod: String, CaseIterable, Sendable {
    case today, yesterday, thirtyDays

    public func interval(now: Date, calendar: Calendar = .current) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let start: Date
        let end: Date
        switch self {
        case .today:
            start = today
            end = now
        case .yesterday:
            start = calendar.date(byAdding: .day, value: -1, to: today)!
            end = today
        case .thirtyDays:
            start = calendar.date(byAdding: .day, value: -29, to: today)!
            end = now
        }
        return DateInterval(start: start, end: end)
    }
}

public struct SpendTotal: Codable, Sendable, Equatable {
    public var estimatedUSD: Double = 0
    public var recordedUSD: Double = 0
    public var pricedEvents = 0
    public var unpricedEvents = 0
    /// Plain input, cache writes (5 min + 1 h), cache reads and output.
    public var inputTokens = 0
    public var cacheWriteTokens = 0
    public var cacheReadTokens = 0
    public var outputTokens = 0
    public var dollars: Double { estimatedUSD + recordedUSD }
    public var events: Int { pricedEvents + unpricedEvents }
    public var tokens: Int { inputTokens + cacheWriteTokens + cacheReadTokens + outputTokens }
    public init() {}

    public mutating func add(_ other: SpendTotal) {
        estimatedUSD += other.estimatedUSD
        recordedUSD += other.recordedUSD
        pricedEvents += other.pricedEvents
        unpricedEvents += other.unpricedEvents
        inputTokens += other.inputTokens
        cacheWriteTokens += other.cacheWriteTokens
        cacheReadTokens += other.cacheReadTokens
        outputTokens += other.outputTokens
    }

    mutating func add(_ tokens: TokenBreakdown) {
        inputTokens += tokens.input
        cacheWriteTokens += tokens.cacheWrite5m + tokens.cacheWrite1h
        cacheReadTokens += tokens.cacheRead
        outputTokens += tokens.output
    }

    // Older saved totals have no token fields.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        estimatedUSD = try c.decodeIfPresent(Double.self, forKey: .estimatedUSD) ?? 0
        recordedUSD = try c.decodeIfPresent(Double.self, forKey: .recordedUSD) ?? 0
        pricedEvents = try c.decodeIfPresent(Int.self, forKey: .pricedEvents) ?? 0
        unpricedEvents = try c.decodeIfPresent(Int.self, forKey: .unpricedEvents) ?? 0
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
    }
}

/// One source's usage of one model on one local calendar day.
public struct SpendDay: Sendable {
    public let date: Date
    public let provider: SpendProvider
    /// Where the usage came from: provider, log folder and (for Claude) the
    /// app that wrote it, as `provider:folder:app`. See `SpendSource`.
    public let source: String
    public let model: String
    public var total: SpendTotal
    public init(date: Date, provider: SpendProvider, source: String = "", model: String = "", total: SpendTotal) {
        self.date = date
        self.provider = provider
        self.source = source
        self.model = model
        self.total = total
    }
}

/// A usage source key, `provider:folder:app`, split back into its parts.
public struct SpendSource: Hashable, Sendable {
    public let provider: SpendProvider
    /// The CLI home the logs came from, e.g. `/Users/me/.claude`.
    public let folder: String
    /// Claude's entrypoint ("claude-desktop", "cli", "sdk-ts", …); empty for Codex.
    public let app: String

    public init(provider: SpendProvider, folder: String, app: String) {
        self.provider = provider
        self.folder = folder
        self.app = app
    }

    public init?(key: String) {
        let parts = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let provider = SpendProvider(rawValue: String(parts[0])) else { return nil }
        let rest = String(parts[1])
        guard let split = rest.lastIndex(of: ":") else { return nil }
        self.init(provider: provider, folder: String(rest[..<split]), app: String(rest[rest.index(after: split)...]))
    }

    public var key: String { "\(provider.rawValue):\(folder):\(app)" }
}

public struct SpendSummary: Sendable {
    public var days: [SpendDay] = []
    public var scannedAt: Date?
    public var isPartial = false
    public var pricingUnavailable = false
    public var filesRead = 0
    public var filesReused = 0
    /// Log files not read yet; later scans continue with them.
    public var pendingFiles = 0
    /// Files too large to read, skipped until they change.
    public var skippedFiles = 0
    public var sourceCount = 0
    public var hasLogs = false
    public init() {}

    public func total(
        provider: SpendProvider? = nil, period: SpendPeriod, now: Date = Date(),
        calendar: Calendar = .current
    ) -> SpendTotal {
        let interval = period.interval(now: now, calendar: calendar)
        return days.filter {
            $0.date >= interval.start && $0.date < interval.end
                && (provider == nil || $0.provider == provider)
        }.reduce(into: SpendTotal()) { sum, day in sum.add(day.total) }
    }
}

/// A directory is a local source, never proof of which subscription paid for its history.
public struct SpendLogSource: Sendable, Hashable {
    public let provider: SpendProvider
    public let directory: URL

    public init(provider: SpendProvider, directory: URL) {
        self.provider = provider
        self.directory = directory.standardizedFileURL.resolvingSymlinksInPath()
    }

    public static func localSources(
        connections: [SubscriptionConnection], home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [SpendLogSource] {
        func homeFor(_ key: String, fallback: String) -> URL {
            if let path = environment[key], path.hasPrefix("/") { return URL(fileURLWithPath: path) }
            return home.appendingPathComponent(fallback)
        }
        var homes: [(SpendProvider, URL)] = [
            (.claude, homeFor("CLAUDE_CONFIG_DIR", fallback: ".claude")),
            (.codex, homeFor("CODEX_HOME", fallback: ".codex")),
        ]
        homes += connections.map {
            ($0.kind == .claudeStatusLine ? .claude : .codex, URL(fileURLWithPath: $0.directory))
        }
        var seen = Set<SpendLogSource>()
        return homes.flatMap { provider, directory in
            (provider == .claude ? ["projects"] : ["sessions", "archived_sessions"]).map {
                SpendLogSource(provider: provider, directory: directory.appendingPathComponent($0))
            }
        }.filter { seen.insert($0).inserted }
    }
}

struct SpendEvent: Sendable {
    var timestamp: Date
    var provider: SpendProvider
    var model: String
    var tokens: TokenBreakdown
    var recordedUSD: Double?
    var identity: String
    var requestID: String?
    var sidechain = false
    var hasSpeed = false
    var fast = false
    var ultrafast = false
    /// Claude's entrypoint (which app wrote it); empty for Codex.
    var client = ""
    /// `SpendSource.key`, set by the scanner from the file's folder and `client`.
    var source = ""
}

extension ModelPricing {
    static func bundled() throws -> ModelPricing {
        func data(_ name: String) throws -> Data {
            let packaged = Bundle.main.resourceURL?.appendingPathComponent("openquota_OpenQuotaCore.bundle")
            let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
            guard let url = bundle.url(forResource: name, withExtension: "json") else {
                throw CocoaError(.fileNoSuchFile)
            }
            return try Data(contentsOf: url)
        }
        return try ModelPricing(
            supplement: PricingSupplement.decode(from: data("pricing_supplement")),
            primary: PricingCatalogCodecs.catalogFromCompact(data("pricing_litellm_snapshot")),
            secondary: PricingCatalogCodecs.catalogFromCompact(data("pricing_models_dev_snapshot"))
        )
    }
}
