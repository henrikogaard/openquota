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

public struct SpendTotal: Sendable {
    public var estimatedUSD: Double = 0
    public var recordedUSD: Double = 0
    public var pricedEvents = 0
    public var unpricedEvents = 0
    public var dollars: Double { estimatedUSD + recordedUSD }
    public init() {}
}

public struct SpendDay: Sendable {
    public let date: Date
    public let provider: SpendProvider
    public var total: SpendTotal
    public init(date: Date, provider: SpendProvider, total: SpendTotal) {
        self.date = date
        self.provider = provider
        self.total = total
    }
}

public struct SpendSummary: Sendable {
    public var days: [SpendDay] = []
    public var scannedAt: Date?
    public var isPartial = false
    public var pricingUnavailable = false
    public var filesRead = 0
    public var filesReused = 0
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
        }.reduce(into: SpendTotal()) { sum, day in
            sum.estimatedUSD += day.total.estimatedUSD
            sum.recordedUSD += day.total.recordedUSD
            sum.pricedEvents += day.total.pricedEvents
            sum.unpricedEvents += day.total.unpricedEvents
        }
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
