import Foundation

/// One background worker, bounded metadata cache, no credential reads or network requests.
public actor LocalSpendScanner {
    struct Limits: Sendable {
        var files = 2_000
        var directoryEntries = 20_000
        var fileBytes = 64 * 1_024 * 1_024
        var scanBytes = 256 * 1_024 * 1_024
        var lineBytes = 1_048_576
        var events = 100_000
        var seconds: TimeInterval = 10
    }

    private struct CachedFile {
        var size: Int
        var modified: Date
        var events: [SpendEvent]
        var incomplete: Bool
    }

    private struct LogFile {
        var url: URL
        var provider: SpendProvider
        var size: Int
        var modified: Date
        var key: String { "\(provider.rawValue):\(url.path)" }
    }

    private let limits: Limits
    private var pricing: ModelPricing?
    private var cache: [String: CachedFile] = [:]

    public init() { limits = Limits() }
    init(limits: Limits, pricing: ModelPricing) {
        self.limits = limits
        self.pricing = pricing
    }

    public func clear() { cache.removeAll() }

    public func scan(sources: [SpendLogSource], now: Date = Date(), calendar: Calendar = .current) -> SpendSummary {
        let start = ContinuousClock.now
        let since = SpendPeriod.thirtyDays.interval(now: now, calendar: calendar).start
        var result = SpendSummary()
        result.scannedAt = now
        result.sourceCount = sources.count
        if pricing == nil { pricing = try? ModelPricing.bundled() }
        guard let pricing else {
            result.pricingUnavailable = true
            return result
        }
        let files = discover(sources, since: since, start: start, partial: &result.isPartial)
        result.hasLogs = !files.isEmpty
        var remainingBytes = limits.scanBytes
        var remainingEvents = limits.events
        var updatedCache: [String: CachedFile] = [:]
        var events: [SpendEvent] = []
        for file in files {
            guard !Task.isCancelled, start.duration(to: .now) < .seconds(limits.seconds),
                  remainingEvents > 0 else { result.isPartial = true; break }
            let parsed: CachedFile
            if let cached = cache[file.key], cached.size == file.size, cached.modified == file.modified {
                parsed = cached
                result.filesReused += 1
            } else {
                guard file.size <= limits.fileBytes, file.size <= remainingBytes else {
                    result.isPartial = true
                    continue
                }
                remainingBytes -= file.size
                do {
                    parsed = try parse(file, since: since, maxEvents: remainingEvents, start: start)
                    result.filesRead += 1
                } catch {
                    result.isPartial = true
                    continue
                }
            }
            let eligible = parsed.events.filter { $0.timestamp >= since }
            let retained = Array(eligible.prefix(remainingEvents))
            let truncated = retained.count < eligible.count
            if truncated {
                result.isPartial = true
            }
            remainingEvents -= retained.count
            events.append(contentsOf: retained.filter { $0.timestamp <= now })
            result.isPartial = result.isPartial || parsed.incomplete
            // Interrupted files must be reparsed, not preserved as apparently complete.
            if !parsed.incomplete && !truncated {
                updatedCache[file.key] = CachedFile(
                    size: parsed.size, modified: parsed.modified, events: retained, incomplete: false)
            }
        }
        cache = updatedCache
        result.days = Self.aggregate(Self.deduplicate(events), pricing: pricing, calendar: calendar)
        return result
    }

    private func discover(
        _ sources: [SpendLogSource], since: Date, start: ContinuousClock.Instant, partial: inout Bool
    ) -> [LogFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var files: [LogFile] = []
        var paths = Set<String>()
        var visited = 0
        var readError = false
        for source in sources {
            guard fm.fileExists(atPath: source.directory.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: source.directory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in readError = true; return true }
            ) else { partial = true; continue }
            for case let url as URL in enumerator {
                visited += 1
                guard visited <= limits.directoryEntries, !Task.isCancelled,
                      start.duration(to: .now) < .seconds(limits.seconds) else {
                    partial = true
                    return files.sorted { $0.modified > $1.modified }
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    partial = true
                    continue
                }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true, url.pathExtension == "jsonl",
                      let size = values.fileSize, let modified = values.contentModificationDate,
                      modified >= since else { continue }
                let file = LogFile(url: url, provider: source.provider, size: size, modified: modified)
                guard paths.insert(file.key).inserted else { continue }
                if files.count < limits.files { files.append(file) } else { partial = true }
            }
        }
        partial = partial || readError
        return files.sorted { $0.modified > $1.modified }
    }

    private func parse(
        _ file: LogFile, since: Date, maxEvents: Int, start: ContinuousClock.Instant
    ) throws -> CachedFile {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        var parser = SpendLogParser(provider: file.provider, fileIdentity: file.url.path)
        var buffer = Data()
        var events: [SpendEvent] = []
        var bytes = 0
        var lineNumber = 0
        var oversized = false
        var incomplete = false
        while true {
            guard !Task.isCancelled, start.duration(to: .now) < .seconds(limits.seconds),
                  events.count < maxEvents else { incomplete = true; break }
            // Snapshot size bounds a file that keeps growing while it is being read.
            let chunk = try handle.read(upToCount: min(65_536, max(0, file.size - bytes))) ?? Data()
            bytes += chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lineNumber += 1
                let length = buffer.distance(from: buffer.startIndex, to: newline)
                if !oversized && length <= limits.lineBytes {
                    events.append(contentsOf: parser.parse(Data(buffer[..<newline]), lineNumber: lineNumber)
                        .filter { $0.timestamp >= since }.prefix(max(0, maxEvents - events.count)))
                } else { incomplete = true }
                buffer.removeSubrange(...newline)
                oversized = false
                if events.count >= maxEvents { incomplete = true; break }
            }
            if buffer.count > limits.lineBytes {
                buffer.removeAll(keepingCapacity: false)
                oversized = true
                incomplete = true
            }
            if chunk.isEmpty {
                if !buffer.isEmpty && !oversized && events.count < maxEvents {
                    events.append(contentsOf: parser.parse(buffer, lineNumber: lineNumber + 1)
                        .filter { $0.timestamp >= since }.prefix(maxEvents - events.count))
                }
                break
            }
        }
        return CachedFile(size: file.size, modified: file.modified, events: events,
                          incomplete: incomplete || parser.incomplete)
    }

    static func deduplicate(_ events: [SpendEvent]) -> [SpendEvent] {
        var output: [SpendEvent] = []
        var exact: [String: Int] = [:]
        var messages: [String: [Int]] = [:]
        for event in events {
            let message = "\(event.provider.rawValue):\(event.identity)"
            let key = "\(message):\(event.requestID ?? "")"
            let collision = exact[key] ?? messages[message]?.first {
                event.sidechain || output[$0].sidechain
            }
            if let index = collision {
                let old = output[index]
                let replace: Bool
                if old.sidechain != event.sidechain { replace = old.sidechain }
                else if old.tokens.totalTokens != event.tokens.totalTokens {
                    replace = event.tokens.totalTokens > old.tokens.totalTokens
                } else { replace = (event.hasSpeed && !old.hasSpeed) || (event.recordedUSD != nil && old.recordedUSD == nil) }
                if replace {
                    var kept = event
                    if kept.recordedUSD == nil, old.sidechain == event.sidechain,
                       old.tokens.totalTokens == event.tokens.totalTokens {
                        kept.recordedUSD = old.recordedUSD
                    }
                    output[index] = kept
                }
                exact[key] = index
            } else {
                exact[key] = output.count
                messages[message, default: []].append(output.count)
                output.append(event)
            }
        }
        return output
    }

    static func aggregate(_ events: [SpendEvent], pricing: ModelPricing, calendar: Calendar) -> [SpendDay] {
        var days: [SpendProvider: [Date: SpendTotal]] = [:]
        var rates: [String: ModelRates?] = [:]
        var codexRates: [String: CodexUsagePricing.RateResolution] = [:]
        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            var total = days[event.provider, default: [:]][day] ?? SpendTotal()
            let cost: Double?
            if let recorded = event.recordedUSD {
                cost = recorded
                total.recordedUSD += recorded
            } else {
                if event.provider == .codex {
                    let resolution = codexRates[event.model] ?? CodexUsagePricing.resolveRates(pricing: pricing, model: event.model)
                    if codexRates.count < 2_000 { codexRates[event.model] = resolution }
                    cost = resolution.rates.map {
                        CodexUsagePricing.cost(
                            rates: $0, tokens: event.tokens, model: resolution.rateModel,
                            fastTier: resolution.isFastAlias ? resolution.hasBaseRates : event.fast,
                            ultrafastTier: event.ultrafast && (!resolution.isFastAlias || resolution.hasBaseRates))
                    }
                } else {
                    let resolved: ModelRates?
                    if let cached = rates[event.model] { resolved = cached }
                    else {
                        resolved = pricing.resolve(model: event.model)
                        if rates.count < 2_000 { rates[event.model] = .some(resolved) }
                    }
                    cost = resolved?.costDollars(for: event.tokens)
                }
                if let cost { total.estimatedUSD += cost }
            }
            if cost != nil { total.pricedEvents += 1 } else { total.unpricedEvents += 1 }
            days[event.provider, default: [:]][day] = total
        }
        return SpendProvider.allCases.flatMap { provider in
            (days[provider] ?? [:]).map { SpendDay(date: $0.key, provider: provider, total: $0.value) }
                .sorted { $0.date < $1.date }
        }
    }
}
