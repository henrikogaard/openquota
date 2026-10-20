import Foundation

/// Reads local Claude and Codex logs into a small SQLite database:
/// which files were read (so unchanged files are never read again), recent
/// per-request token counts (to drop duplicates across files), and daily
/// totals per source and model (the history). One worker, bounded passes, no
/// credential reads or network requests.
public actor LocalSpendScanner {
    struct Limits: Sendable {
        var files = 2_000
        var directoryEntries = 20_000
        /// Sanity cap; files are read in pieces, so size alone rarely matters.
        var fileBytes = 8 * 1_024 * 1_024 * 1_024
        var scanBytes = 256 * 1_024 * 1_024
        var lineBytes = 1_048_576
        var events = 100_000
        var seconds: TimeInterval = 10
        /// Per-request rows are kept this many days; older days keep only totals.
        var eventDays = 40
    }

    private struct LogFile {
        var url: URL
        var provider: SpendProvider
        /// The CLI home the file belongs to (parent of projects/ or sessions/).
        var folder: String
        var size: Int
        var modified: Date
        var key: String { "\(provider.rawValue):\(url.path)" }
    }

    private struct Parsed {
        var events: [SpendEvent]
        /// Bytes read through the last complete line.
        var endOffset: Int
        /// Lines read so far, for line-based request identities.
        var lines: Int
        /// The pass ran out of time, bytes or event budget before the end.
        var interrupted: Bool
        /// Some lines couldn't be used.
        var malformed: Bool
        /// Where the parser stopped, to read on next time (Codex).
        var parserState: SpendLogParser.State
    }

    private struct SavedFile {
        var size: Int
        var modified: Double
        var state: String
        var offset: Int
        var lines: Int
        var parserState: SpendLogParser.State?
    }

    /// What to read of a file: from the start, or on from a saved offset.
    private struct Work {
        var file: LogFile
        var offset = 0
        var firstLine = 0
        var parserState: SpendLogParser.State?
        var appends: Bool { offset > 0 }
    }

    private static let schemaVersion = 3

    private let limits: Limits
    private let databaseURL: URL?
    private var pricing: ModelPricing?
    private var database: SQLiteDatabase?

    /// `databaseURL` nil keeps the database in memory (tests).
    public init(databaseURL: URL? = nil) {
        limits = Limits()
        self.databaseURL = databaseURL
    }

    init(limits: Limits, pricing: ModelPricing, databaseURL: URL? = nil) {
        self.limits = limits
        self.pricing = pricing
        self.databaseURL = databaseURL
    }

    /// Deletes everything read so far: files, requests and daily totals.
    public func deleteAll() {
        database = nil
        if let databaseURL {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: databaseURL.path + suffix))
            }
        }
    }

    /// Daily totals saved so far, without reading any logs.
    public func savedDays(calendar: Calendar = .current) -> [SpendDay] {
        guard let database = try? open() else { return [] }
        return (try? Self.loadDays(database, calendar: calendar)) ?? []
    }

    /// One bounded pass: finds log files, reads new or changed ones (newest
    /// first, taking turns between providers) until the budget runs out, and
    /// updates the daily totals for the days they touch. Call again while
    /// `pendingFiles` is above zero to continue.
    public func scan(sources: [SpendLogSource], now: Date = Date(), calendar: Calendar = .current) -> SpendSummary {
        let start = ContinuousClock.now
        var result = SpendSummary()
        result.scannedAt = now
        result.sourceCount = sources.count
        if pricing == nil { pricing = try? ModelPricing.bundled() }
        guard let pricing else {
            result.pricingUnavailable = true
            return result
        }
        let database: SQLiteDatabase
        do { database = try open() } catch {
            result.isPartial = true
            return result
        }
        let files = discover(sources, start: start, partial: &result.isPartial)
        let known = (try? Self.loadFiles(database)) ?? [:]
        var pending: [Work] = []
        for file in files {
            guard let saved = known[file.key] else { pending.append(Work(file: file)); continue }
            let unchanged = saved.size == file.size && saved.modified == file.modified.timeIntervalSince1970
            if unchanged && saved.state != "partial" { continue }
            // A grown or half-read file is read on from where the last pass
            // stopped, with the Codex parser's running totals restored. A file
            // that shrank was rewritten and is read again from the start.
            if saved.offset > 0, saved.size <= file.size, saved.offset <= file.size,
               file.provider == .claude || saved.parserState != nil {
                pending.append(Work(file: file, offset: saved.offset, firstLine: saved.lines,
                                    parserState: saved.parserState))
            } else {
                pending.append(Work(file: file))
            }
        }
        result.filesReused = files.count - pending.count
        let ordered = Self.takingTurns(pending)

        var remainingBytes = limits.scanBytes
        var affectedDays = Set<String>()
        var processed = 0
        for work in ordered {
            let file = work.file
            guard !Task.isCancelled, start.duration(to: .now) < .seconds(limits.seconds), remainingBytes > 0 else { break }
            if file.size > limits.fileBytes {
                try? Self.saveFile(database, file, state: "skipped", offset: 0, lines: 0, parserState: nil)
                result.skippedFiles += 1
                processed += 1
                continue
            }
            let parsed: Parsed
            do {
                parsed = try parse(file, from: work.offset, firstLine: work.firstLine,
                                   parserState: work.parserState, byteBudget: remainingBytes, start: start)
            } catch {
                result.isPartial = true
                processed += 1
                continue
            }
            remainingBytes -= parsed.endOffset - work.offset
            result.isPartial = result.isPartial || parsed.malformed
            // A file is read once, so keep requests stamped slightly ahead of
            // this Mac's clock too; they count on their own day.
            var events = parsed.events
            for index in events.indices {
                let app = file.provider == .claude ? events[index].client : ""
                events[index].source = SpendSource(provider: file.provider, folder: file.folder, app: app).key
            }
            do {
                let days = try database.transaction {
                    try Self.saveEvents(
                        database, file: file, events: events, replacing: !work.appends,
                        state: parsed.interrupted ? "partial" : "read",
                        offset: parsed.endOffset, lines: parsed.lines,
                        parserState: file.provider == .codex ? parsed.parserState : nil, calendar: calendar)
                }
                affectedDays.formUnion(days)
                if !parsed.interrupted { result.filesRead += 1 }
            } catch {
                result.isPartial = true
            }
            // A file stopped mid-way continues next pass.
            if parsed.interrupted { break }
            processed += 1
        }
        result.pendingFiles = ordered.count - processed
        do {
            try database.transaction {
                try Self.recompute(database, days: affectedDays, pricing: pricing, calendar: calendar)
                if result.pendingFiles == 0 {
                    try Self.prune(database, now: now, keepDays: limits.eventDays, calendar: calendar)
                }
            }
        } catch {
            result.isPartial = true
        }
        result.skippedFiles = (try? database.prepare("SELECT COUNT(*) FROM files WHERE state = 'skipped'")
            .first { $0.int(0) }) ?? result.skippedFiles
        // Skipped files leave the totals short.
        result.isPartial = result.isPartial || result.skippedFiles > 0
        result.days = (try? Self.loadDays(database, calendar: calendar)) ?? []
        result.hasLogs = !files.isEmpty || !result.days.isEmpty
        return result
    }

    // MARK: Database

    private func open() throws -> SQLiteDatabase {
        if let database { return database }
        let database = try SQLiteDatabase(url: databaseURL)
        if database.userVersion != Self.schemaVersion {
            try database.execute("""
                DROP TABLE IF EXISTS files; DROP TABLE IF EXISTS events;
                DROP TABLE IF EXISTS days; DROP TABLE IF EXISTS pruned_days;
                PRAGMA auto_vacuum = INCREMENTAL; VACUUM;
                CREATE TABLE files(
                    id INTEGER PRIMARY KEY, key TEXT NOT NULL UNIQUE, size INTEGER NOT NULL,
                    mtime REAL NOT NULL, state TEXT NOT NULL, offset INTEGER NOT NULL,
                    lines INTEGER NOT NULL, parser TEXT);
                CREATE TABLE events(
                    file INTEGER NOT NULL, day TEXT NOT NULL, ts REAL NOT NULL, provider TEXT NOT NULL,
                    source TEXT NOT NULL, model TEXT NOT NULL,
                    input INTEGER NOT NULL, cache_write_5m INTEGER NOT NULL, cache_write_1h INTEGER NOT NULL,
                    cache_read INTEGER NOT NULL, output INTEGER NOT NULL, token_fast INTEGER NOT NULL,
                    recorded REAL, identity INTEGER NOT NULL, request INTEGER,
                    sidechain INTEGER NOT NULL, has_speed INTEGER NOT NULL, fast INTEGER NOT NULL,
                    ultrafast INTEGER NOT NULL);
                CREATE INDEX events_day ON events(day);
                CREATE INDEX events_file ON events(file);
                CREATE TABLE days(
                    day TEXT NOT NULL, provider TEXT NOT NULL, source TEXT NOT NULL, model TEXT NOT NULL,
                    estimated REAL NOT NULL, recorded REAL NOT NULL, priced INTEGER NOT NULL,
                    unpriced INTEGER NOT NULL, input INTEGER NOT NULL, cache_write INTEGER NOT NULL,
                    cache_read INTEGER NOT NULL, output INTEGER NOT NULL,
                    PRIMARY KEY(day, provider, source, model));
                CREATE TABLE pruned_days(day TEXT PRIMARY KEY);
                """)
            try database.setUserVersion(Self.schemaVersion)
        }
        self.database = database
        return database
    }

    private static func loadFiles(_ database: SQLiteDatabase) throws -> [String: SavedFile] {
        var files: [String: SavedFile] = [:]
        try database.prepare("SELECT key, size, mtime, state, offset, lines, parser FROM files").forEach { row in
            let state = row.isNull(6) ? nil
                : try? JSONDecoder().decode(SpendLogParser.State.self, from: Data(row.string(6).utf8))
            files[row.string(0)] = SavedFile(
                size: row.int(1), modified: row.double(2), state: row.string(3), offset: row.int(4),
                lines: row.int(5), parserState: state)
        }
        return files
    }

    /// Saves how far a file was read; returns its row id.
    @discardableResult
    private static func saveFile(
        _ database: SQLiteDatabase, _ file: LogFile, state: String, offset: Int, lines: Int,
        parserState: SpendLogParser.State?
    ) throws -> Int {
        let parser = try parserState.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try database.prepare("""
            INSERT INTO files(key, size, mtime, state, offset, lines, parser) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
            ON CONFLICT(key) DO UPDATE SET size = ?2, mtime = ?3, state = ?4, offset = ?5, lines = ?6, parser = ?7
            """).run([file.key, file.size, file.modified.timeIntervalSince1970, state, offset, lines, parser])
        return try database.prepare("SELECT id FROM files WHERE key = ?1").first([file.key]) { $0.int(0) } ?? 0
    }

    /// Request identities are compared, never shown: a 64-bit FNV-1a hash
    /// keeps the table small.
    static func fingerprint(_ text: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(bitPattern: UInt(hash))
    }

    /// Saves a file's requests (replacing earlier ones, or appending to them)
    /// and how far it was read; returns the days touched.
    private static func saveEvents(
        _ database: SQLiteDatabase, file: LogFile, events: [SpendEvent], replacing: Bool,
        state: String, offset: Int, lines: Int, parserState: SpendLogParser.State?, calendar: Calendar
    ) throws -> Set<String> {
        let id = try saveFile(database, file, state: state, offset: offset, lines: lines, parserState: parserState)
        var days = Set<String>()
        if replacing {
            try database.prepare("SELECT DISTINCT day FROM events WHERE file = ?1").forEach([id]) {
                days.insert($0.string(0))
            }
            try database.prepare("DELETE FROM events WHERE file = ?1").run([id])
        }
        let insert = try database.prepare("""
            INSERT INTO events(file, day, ts, provider, source, model, input, cache_write_5m, cache_write_1h,
                cache_read, output, token_fast, recorded, identity, request, sidechain, has_speed, fast, ultrafast)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19)
            """)
        for event in events {
            let day = SpendHistory.dayKey(event.timestamp, calendar: calendar)
            days.insert(day)
            let t = event.tokens
            try insert.run([
                id, day, event.timestamp.timeIntervalSince1970, event.provider.rawValue, event.source,
                event.model, t.input, t.cacheWrite5m, t.cacheWrite1h, t.cacheRead, t.output, t.isFast,
                event.recordedUSD, fingerprint(event.identity), event.requestID.map(fingerprint),
                event.sidechain, event.hasSpeed, event.fast, event.ultrafast,
            ])
        }
        return days
    }

    /// Rebuilds the daily totals for `days` from the requests in the database.
    /// Days whose requests were already pruned keep their totals: new requests
    /// for them come from copied or resumed sessions and would double count.
    private static func recompute(
        _ database: SQLiteDatabase, days: Set<String>, pricing: ModelPricing, calendar: Calendar
    ) throws {
        guard !days.isEmpty else { return }
        var pruned = Set<String>()
        try database.prepare("SELECT day FROM pruned_days").forEach { pruned.insert($0.string(0)) }
        let select = try database.prepare("""
            SELECT ts, provider, source, model, input, cache_write_5m, cache_write_1h, cache_read, output,
                token_fast, recorded, identity, request, sidechain, has_speed, fast, ultrafast
            FROM events WHERE day = ?1
            """)
        let deleteDay = try database.prepare("DELETE FROM days WHERE day = ?1")
        let deleteEvents = try database.prepare("DELETE FROM events WHERE day = ?1")
        let insert = try database.prepare("""
            INSERT OR REPLACE INTO days(day, provider, source, model, estimated, recorded, priced, unpriced,
                input, cache_write, cache_read, output)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
            """)
        for day in days {
            if pruned.contains(day) {
                try deleteEvents.run([day])
                continue
            }
            var events: [SpendEvent] = []
            try select.forEach([day]) { row in
                guard let provider = SpendProvider(rawValue: row.string(1)) else { return }
                var event = SpendEvent(
                    timestamp: Date(timeIntervalSince1970: row.double(0)), provider: provider,
                    model: row.string(3),
                    tokens: TokenBreakdown(
                        input: row.int(4), cacheWrite5m: row.int(5), cacheWrite1h: row.int(6),
                        cacheRead: row.int(7), output: row.int(8), isFast: row.int(9) != 0),
                    recordedUSD: row.isNull(10) ? nil : row.double(10), identity: String(row.int(11)),
                    sidechain: row.int(13) != 0, hasSpeed: row.int(14) != 0,
                    fast: row.int(15) != 0, ultrafast: row.int(16) != 0)
                event.requestID = row.isNull(12) ? nil : String(row.int(12))
                event.source = row.string(2)
                events.append(event)
            }
            try deleteDay.run([day])
            for total in aggregate(deduplicate(events), pricing: pricing, calendar: calendar) {
                let t = total.total
                try insert.run([
                    day, total.provider.rawValue, total.source, total.model, t.estimatedUSD, t.recordedUSD,
                    t.pricedEvents, t.unpricedEvents, t.inputTokens, t.cacheWriteTokens, t.cacheReadTokens,
                    t.outputTokens,
                ])
            }
        }
    }

    /// Drops per-request rows older than `keepDays`; their days keep their totals.
    private static func prune(_ database: SQLiteDatabase, now: Date, keepDays: Int, calendar: Calendar) throws {
        let cutoff = calendar.date(byAdding: .day, value: -keepDays, to: calendar.startOfDay(for: now))!
        let key = SpendHistory.dayKey(cutoff, calendar: calendar)
        try database.prepare("INSERT OR IGNORE INTO pruned_days(day) SELECT DISTINCT day FROM events WHERE day < ?1")
            .run([key])
        try database.prepare("DELETE FROM events WHERE day < ?1").run([key])
        try database.execute("PRAGMA incremental_vacuum")
    }

    private static func loadDays(_ database: SQLiteDatabase, calendar: Calendar) throws -> [SpendDay] {
        var days: [SpendDay] = []
        try database.prepare("""
            SELECT day, provider, source, model, estimated, recorded, priced, unpriced, input, cache_write,
                cache_read, output FROM days ORDER BY day
            """).forEach { row in
            guard let date = SpendHistory.date(row.string(0), calendar: calendar),
                  let provider = SpendProvider(rawValue: row.string(1)) else { return }
            var total = SpendTotal()
            total.estimatedUSD = row.double(4)
            total.recordedUSD = row.double(5)
            total.pricedEvents = row.int(6)
            total.unpricedEvents = row.int(7)
            total.inputTokens = row.int(8)
            total.cacheWriteTokens = row.int(9)
            total.cacheReadTokens = row.int(10)
            total.outputTokens = row.int(11)
            days.append(SpendDay(date: date, provider: provider, source: row.string(2), model: row.string(3), total: total))
        }
        return days
    }

    // MARK: Files

    /// Newest first within each provider, alternating between providers so
    /// one provider's many files can't use up the pass.
    private static func takingTurns(_ files: [Work]) -> [Work] {
        var queues = SpendProvider.allCases.map { provider in
            files.filter { $0.file.provider == provider }.sorted { $0.file.modified > $1.file.modified }[...]
        }
        var ordered: [Work] = []
        while queues.contains(where: { !$0.isEmpty }) {
            for index in queues.indices {
                if let next = queues[index].popFirst() { ordered.append(next) }
            }
        }
        return ordered
    }

    private func discover(
        _ sources: [SpendLogSource], start: ContinuousClock.Instant, partial: inout Bool
    ) -> [LogFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        var files: [LogFile] = []
        var paths = Set<String>()
        var readError = false
        // Each source gets its own entry and file budget, so a large Claude
        // folder can't hide the Codex one.
        for source in sources {
            guard fm.fileExists(atPath: source.directory.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: source.directory, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in readError = true; return true }
            ) else { partial = true; continue }
            let folder = source.directory.deletingLastPathComponent().path
            var visited = 0
            var found = 0
            for case let url as URL in enumerator {
                visited += 1
                guard visited <= limits.directoryEntries, !Task.isCancelled,
                      start.duration(to: .now) < .seconds(limits.seconds) else {
                    partial = true
                    break
                }
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    partial = true
                    continue
                }
                if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                guard values.isRegularFile == true, url.pathExtension == "jsonl",
                      let size = values.fileSize, let modified = values.contentModificationDate else { continue }
                let file = LogFile(url: url, provider: source.provider, folder: folder, size: size, modified: modified)
                guard paths.insert(file.key).inserted else { continue }
                if found < limits.files {
                    files.append(file)
                    found += 1
                } else {
                    partial = true
                }
            }
        }
        partial = partial || readError
        return files
    }

    /// Reads complete lines from `offset` until the end of the file or the
    /// pass budget, and stops at the last complete line so a line still being
    /// written is read next time.
    private func parse(
        _ file: LogFile, from offset: Int, firstLine: Int, parserState: SpendLogParser.State?,
        byteBudget: Int, start: ContinuousClock.Instant
    ) throws -> Parsed {
        let handle = try FileHandle(forReadingFrom: file.url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var parser = SpendLogParser(provider: file.provider, fileIdentity: file.url.path)
        if let parserState { parser.state = parserState }
        var buffer = Data()
        var bufferStart = offset
        var events: [SpendEvent] = []
        var bytes = offset
        var lineNumber = firstLine
        var oversized = false
        var malformed = false
        var interrupted = false
        reading: while true {
            // Always finish at least one line, so a pass can't stall on a file.
            let progressed = bufferStart > offset
            guard !Task.isCancelled, start.duration(to: .now) < .seconds(limits.seconds) || !progressed,
                  events.count < limits.events, bytes - offset < byteBudget || !progressed else {
                interrupted = true
                break
            }
            // Snapshot size bounds a file that keeps growing while it is being read.
            let budgetLeft = progressed ? max(1, byteBudget - (bytes - offset)) : 65_536
            let chunk = try handle.read(upToCount: min(65_536, budgetLeft, max(0, file.size - bytes))) ?? Data()
            bytes += chunk.count
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lineNumber += 1
                let length = buffer.distance(from: buffer.startIndex, to: newline)
                if !oversized && length <= limits.lineBytes {
                    events.append(contentsOf: parser.parse(Data(buffer[..<newline]), lineNumber: lineNumber))
                } else { malformed = true }
                buffer.removeSubrange(...newline)
                bufferStart += length + 1
                oversized = false
                if bufferStart - offset >= byteBudget || events.count >= limits.events {
                    interrupted = bufferStart < file.size
                    break reading
                }
            }
            if buffer.count > limits.lineBytes {
                bufferStart += buffer.count
                buffer.removeAll(keepingCapacity: false)
                oversized = true
                malformed = true
            }
            if chunk.isEmpty { break }
        }
        return Parsed(events: events, endOffset: bufferStart, lines: lineNumber, interrupted: interrupted,
                      malformed: malformed || parser.incomplete, parserState: parser.state)
    }

    // MARK: Totals

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
        struct Key: Hashable { let day: Date; let source: String; let model: String }
        var days: [SpendProvider: [Key: SpendTotal]] = [:]
        var rates: [String: ModelRates?] = [:]
        var codexRates: [String: CodexUsagePricing.RateResolution] = [:]
        for event in events {
            let day = Key(day: calendar.startOfDay(for: event.timestamp), source: event.source, model: event.model)
            var total = days[event.provider, default: [:]][day] ?? SpendTotal()
            total.add(event.tokens)
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
            (days[provider] ?? [:]).map {
                SpendDay(date: $0.key.day, provider: provider, source: $0.key.source, model: $0.key.model, total: $0.value)
            }
            .sorted { ($0.date, $0.source, $0.model) < ($1.date, $1.source, $1.model) }
        }
    }
}
