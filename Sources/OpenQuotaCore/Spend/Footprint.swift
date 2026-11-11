import Foundation

/// A low, central and high estimate of one quantity.
public struct FootprintRange: Sendable, Equatable {
    public var low = 0.0
    public var mid = 0.0
    public var high = 0.0

    public init(low: Double = 0, mid: Double = 0, high: Double = 0) {
        self.low = low
        self.mid = mid
        self.high = high
    }

    public mutating func add(_ other: FootprintRange) {
        low += other.low
        mid += other.mid
        high += other.high
    }

    public func scaled(by factor: Double) -> FootprintRange {
        FootprintRange(low: low * factor, mid: mid * factor, high: high * factor)
    }

    /// Low times low, central times central, high times high.
    public func scaled(by factor: FootprintRange) -> FootprintRange {
        FootprintRange(low: low * factor.low, mid: mid * factor.mid, high: high * factor.high)
    }
}

/// A rough size class read from the model name. The multipliers are an
/// assumption: no provider publishes energy per model size.
public enum FootprintModelClass: String, Sendable, CaseIterable {
    case small, standard, large

    public init(model: String) {
        // Whole words only, so "gemini" is not read as "mini".
        let words = Set(model.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func has(_ names: [String]) -> Bool { !words.isDisjoint(with: names) }
        if has(["haiku", "mini", "nano", "flash", "spark", "small"]) {
            self = .small
        } else if has(["opus", "fable", "mythos", "pro"]) {
            self = .large
        } else {
            self = .standard
        }
    }
}

/// Carbon intensity of electricity generation for one grid.
public struct FootprintGrid: Sendable, Equatable, Identifiable {
    public let id: String
    public let gramsPerKWh: Double

    /// 2025 figures from Ember: countries as republished by Our World in Data
    /// (`carbon-intensity-electricity`), World and EU from Ember's Global
    /// Electricity Review 2026.
    public static let presets: [FootprintGrid] = [
        .init(id: "us", gramsPerKWh: 384),
        .init(id: "world", gramsPerKWh: 458),
        .init(id: "eu", gramsPerKWh: 210),
        .init(id: "germany", gramsPerKWh: 330),
        .init(id: "uk", gramsPerKWh: 217),
        .init(id: "france", gramsPerKWh: 41),
        .init(id: "sweden", gramsPerKWh: 35),
        .init(id: "norway", gramsPerKWh: 28),
    ]

    /// Most Claude and Codex requests are served from US data centres.
    public static let standard = presets[0]

    public static func preset(_ id: String) -> FootprintGrid {
        presets.first { $0.id == id } ?? standard
    }
}

/// The numbers behind the footprint estimate. None is a measurement of Claude
/// or Codex: neither Anthropic nor OpenAI publishes energy per token.
/// Sources are listed in `docs/estimated-spend.md`.
public struct FootprintFactors: Sendable, Equatable {
    /// Data-centre energy, overhead included, in Wh per 1,000 output tokens of
    /// a standard-size model. Low follows Google's measured Gemini prompt
    /// (2025). Central is Epoch AI's method scaled to Claude by Couch (2026),
    /// 0.99; Epoch's own GPT-4o figure is 0.6. High is a fit to Jegham et al.
    /// (2025).
    public var whPerThousandOutput = FootprintRange(low: 0.3, mid: 1.0, high: 3.0)
    /// Assumptions with no published energy measurement, taken from API price
    /// ratios: an input token against an output token, and cache writes and
    /// cache reads against plain input.
    public var inputPerOutput = 0.2
    public var cacheWritePerInput = 1.25
    public var cacheReadPerInput = 0.1
    public var classMultiplier: [FootprintModelClass: Double] = [.small: 0.25, .standard: 1, .large: 2]
    /// On-site cooling water in mL per Wh: AWS's 2024 figure (0.15) to
    /// Google's (1.15). The central value is their midpoint.
    public var waterMLPerWh = FootprintRange(low: 0.15, mid: 0.65, high: 1.15)

    public static let standard = FootprintFactors()

    public init() {}

    func multiplier(_ modelClass: FootprintModelClass) -> Double {
        classMultiplier[modelClass] ?? 1
    }
}

/// Estimated footprint of some token usage.
public struct Footprint: Sendable, Equatable {
    /// Estimated data-centre electricity in Wh.
    public var energyWh = FootprintRange()
    /// Central estimate of the Wh avoided because cache reads were not sent
    /// as plain input. Rests on the assumed cache-read factor.
    public var cacheSavedWh = 0.0
    public var requests = 0
    /// Plain input plus cache writes.
    public var newInputTokens = 0
    public var cacheReadTokens = 0
    public var outputTokens = 0

    public init() {}

    public init(_ total: SpendTotal, model: String, factors: FootprintFactors = .standard) {
        let scale = factors.multiplier(FootprintModelClass(model: model)) / 1000
        // Everything as output-token equivalents.
        let input = Double(total.inputTokens) + Double(total.cacheWriteTokens) * factors.cacheWritePerInput
        let cached = Double(total.cacheReadTokens)
        let equivalent = Double(total.outputTokens)
            + (input + cached * factors.cacheReadPerInput) * factors.inputPerOutput
        energyWh = factors.whPerThousandOutput.scaled(by: equivalent * scale)
        cacheSavedWh = cached * (1 - factors.cacheReadPerInput) * factors.inputPerOutput
            * scale * factors.whPerThousandOutput.mid
        requests = total.events
        newInputTokens = total.inputTokens + total.cacheWriteTokens
        cacheReadTokens = total.cacheReadTokens
        outputTokens = total.outputTokens
    }

    public var tokens: Int { newInputTokens + cacheReadTokens + outputTokens }

    /// Share of the uncached energy that caching avoided, 0 to 1.
    public var cacheSavedShare: Double {
        let uncached = energyWh.mid + cacheSavedWh
        return uncached > 0 ? cacheSavedWh / uncached : 0
    }

    public mutating func add(_ other: Footprint) {
        energyWh.add(other.energyWh)
        cacheSavedWh += other.cacheSavedWh
        requests += other.requests
        newInputTokens += other.newInputTokens
        cacheReadTokens += other.cacheReadTokens
        outputTokens += other.outputTokens
    }

    /// Grams of CO2e if the electricity came from `grid`.
    public func co2Grams(_ grid: FootprintGrid) -> FootprintRange {
        energyWh.scaled(by: grid.gramsPerKWh / 1000)
    }

    /// On-site cooling water in mL.
    public func waterML(_ factors: FootprintFactors = .standard) -> FootprintRange {
        energyWh.scaled(by: factors.waterMLPerWh)
    }
}

public struct FootprintBucket: Sendable, Identifiable {
    public let start: Date
    public var footprint: Footprint
    public var id: Date { start }
}

public struct FootprintModel: Sendable, Identifiable {
    public let provider: SpendProvider
    public let model: String
    public let modelClass: FootprintModelClass
    public var footprint: Footprint
    public var id: String { "\(provider.rawValue)|\(model)" }
}

extension SpendHistory {
    public func footprint(
        _ range: SpendHistoryRange, factors: FootprintFactors = .standard,
        now: Date = Date(), calendar: Calendar = .current
    ) -> Footprint {
        rows(in: range, now: now, calendar: calendar).reduce(into: Footprint()) {
            $0.add(Footprint($1.total, model: $1.model, factors: factors))
        }
    }

    /// Footprint per bucket (day, week or month, by range), oldest first.
    public func footprintBuckets(
        _ range: SpendHistoryRange, factors: FootprintFactors = .standard,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [FootprintBucket] {
        var sums: [Date: Footprint] = [:]
        for row in rows(in: range, now: now, calendar: calendar) {
            guard let date = Self.date(row.day, calendar: calendar),
                  let start = calendar.dateInterval(of: range.granularity, for: date)?.start else { continue }
            sums[start, default: Footprint()].add(Footprint(row.total, model: row.model, factors: factors))
        }
        return sums.filter { $0.value.tokens > 0 }
            .map { FootprintBucket(start: $0.key, footprint: $0.value) }
            .sorted { $0.start < $1.start }
    }

    /// Models by estimated energy within the range.
    public func footprintModels(
        _ range: SpendHistoryRange, limit: Int = 8, factors: FootprintFactors = .standard,
        now: Date = Date(), calendar: Calendar = .current
    ) -> [FootprintModel] {
        var sums: [String: FootprintModel] = [:]
        for row in rows(in: range, now: now, calendar: calendar) {
            let id = "\(row.provider.rawValue)|\(row.model)"
            sums[id, default: FootprintModel(
                provider: row.provider, model: row.model,
                modelClass: FootprintModelClass(model: row.model), footprint: Footprint())]
                .footprint.add(Footprint(row.total, model: row.model, factors: factors))
        }
        return Array(sums.values.filter { $0.footprint.tokens > 0 }.sorted {
            ($0.footprint.energyWh.mid, $0.id) > ($1.footprint.energyWh.mid, $1.id)
        }.prefix(limit))
    }
}
