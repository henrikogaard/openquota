import Foundation

/// Mistral Vibe keeps one `meta.json` per session with running totals, so a
/// session is one usage event on the day it started. The day never moves, so
/// a session resumed later replaces its own entry instead of adding a second.
enum VibeUsage {
    static func event(from data: Data) -> SpendEvent? {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let stats = object["stats"] as? [String: Any],
              let sessionID = SpendLogParser.text(object["session_id"]),
              let timestamp = SpendLogParser.date(object["start_time"]) ?? SpendLogParser.date(object["end_time"])
        else { return nil }
        let prompt = SpendLogParser.integer(stats["session_prompt_tokens"]) ?? 0
        let completion = SpendLogParser.integer(stats["session_completion_tokens"]) ?? 0
        // Prompt tokens include the cached ones.
        let cached = min(SpendLogParser.integer(stats["session_cached_tokens"]) ?? 0, prompt)
        guard prompt + completion > 0 else { return nil }
        let model = SpendLogParser.text((object["config"] as? [String: Any])?["active_model"]) ?? ""
        let cost = SpendLogParser.number(stats["session_cost"]) ?? 0
        return SpendEvent(
            timestamp: timestamp, provider: .vibe, model: model,
            tokens: TokenBreakdown(input: prompt - cached, cacheRead: cached, output: completion),
            recordedUSD: cost > 0 ? cost : nil, identity: sessionID)
    }
}

/// OpenCode keeps messages in a SQLite database; each assistant message
/// carries its own token counts and cost. Opened read-only, never changed.
enum OpenCodeUsage {
    struct Page {
        var events: [SpendEvent]
        /// `time_updated` and id of the last row read; pass them back to read on.
        var cursor: Int
        var cursorID: String
        /// The row limit was reached; more rows are waiting.
        var more: Bool
    }

    static let databaseName = "opencode.db"

    /// Assistant messages after the cursor, in `(time_updated, id)` order, so
    /// any number of messages sharing one timestamp page through without a
    /// gap. A message updated again later is returned again; the scanner
    /// keeps the larger.
    static func read(databaseURL: URL, after cursor: Int, afterID: String = "", limit: Int) throws -> Page {
        let database = try SQLiteDatabase(readOnly: databaseURL)
        let statement = try database.prepare("""
            SELECT id, time_updated,
                json_extract(data, '$.time.created'), json_extract(data, '$.modelID'),
                json_extract(data, '$.cost'),
                json_extract(data, '$.tokens.input'), json_extract(data, '$.tokens.output'),
                json_extract(data, '$.tokens.reasoning'),
                json_extract(data, '$.tokens.cache.read'), json_extract(data, '$.tokens.cache.write'),
                json_extract(data, '$.role') = 'assistant'
            FROM (
                -- A row whose data isn't valid JSON is passed over, not an error.
                SELECT id, time_updated, CASE WHEN json_valid(data) THEN data END AS data
                FROM message
                WHERE time_updated > ?1 OR (time_updated = ?1 AND id > ?2)
                ORDER BY time_updated, id LIMIT ?3
            )
            ORDER BY time_updated, id
            """)
        var page = Page(events: [], cursor: cursor, cursorID: afterID, more: false)
        var rows = 0
        try statement.forEach([cursor, afterID, limit]) { row in
            rows += 1
            page.cursor = row.int(1)
            page.cursorID = row.string(0)
            // Every row moves the cursor; only assistant messages are usage.
            guard row.int(10) != 0 else { return }
            func count(_ column: Int32) -> Int { max(0, row.int(column)) }
            let tokens = TokenBreakdown(
                input: count(5), cacheWrite5m: count(9), cacheRead: count(8),
                // Reasoning is billed as output.
                output: count(6) + count(7))
            // The creation time never changes, so a message read again lands on the same day.
            let created = row.double(2)
            guard tokens.totalTokens > 0, created > 0 else { return }
            let cost = row.isNull(4) ? 0 : row.double(4)
            page.events.append(SpendEvent(
                timestamp: Date(timeIntervalSince1970: created / 1_000), provider: .opencode,
                model: row.isNull(3) ? "" : String(row.string(3).prefix(512)), tokens: tokens,
                recordedUSD: cost > 0 && cost.isFinite ? cost : nil, identity: row.string(0)))
        }
        page.more = rows >= limit
        return page
    }
}

/// Reads fields out of protobuf wire data without a schema: varints,
/// length-delimited values and fixed-width numbers, by field number. Data that
/// doesn't parse yields nil; nothing here traps on garbage.
struct ProtobufMessage {
    private let data: Data

    init(_ data: Data) { self.data = data }

    private enum Value {
        case varint(UInt64)
        case bytes(Range<Data.Index>)
    }

    /// The first varint field with this number.
    func varint(_ number: Int) -> UInt64? {
        if case .varint(let value)? = first(number) { return value }
        return nil
    }

    /// A copy of the first length-delimited field with this number.
    func bytes(_ number: Int) -> Data? {
        if case .bytes(let range)? = first(number) { return Data(data[range]) }
        return nil
    }

    /// The first length-delimited field with this number, as a nested message.
    func message(_ number: Int) -> ProtobufMessage? {
        if case .bytes(let range)? = first(number) { return ProtobufMessage(data[range]) }
        return nil
    }

    private func first(_ number: Int) -> Value? {
        var index = data.startIndex
        while index < data.endIndex {
            guard let key = nextVarint(&index), key >> 3 > 0 else { return nil }
            let found = key >> 3 == UInt64(number)
            switch key & 7 {
            case 0:
                guard let value = nextVarint(&index) else { return nil }
                if found { return .varint(value) }
            case 1, 5:
                let width = key & 7 == 1 ? 8 : 4
                guard data.endIndex - index >= width else { return nil }
                index += width
            case 2:
                guard let length = nextVarint(&index), length <= UInt64(data.endIndex - index) else { return nil }
                let range = index..<(index + Int(length))
                index = range.upperBound
                if found { return .bytes(range) }
            default:
                // Groups and unknown wire types: not something to guess at.
                return nil
            }
        }
        return nil
    }

    private func nextVarint(_ index: inout Data.Index) -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while index < data.endIndex, shift < 64 {
            let byte = data[index]
            index += 1
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}

/// Google Antigravity keeps each conversation in its own SQLite database, with
/// one protobuf record per model generation. There is no published schema:
/// the field numbers below were worked out from the numbers in real databases
/// (see docs/estimated-spend.md), so this reader is a best guess. Opened
/// read-only, never changed. A conversation that is closed has no write-ahead
/// log and is read as a plain file, so SQLite leaves no side files next to it.
enum AntigravityUsage {
    struct Usage {
        var events: [SpendEvent]
        /// Bytes of records read, for the pass budget.
        var bytes: Int
        /// The row limit was reached; later generations were left out.
        var truncated: Bool
    }

    /// Steps carry the time; a conversation with more than this is cut short.
    private static let stepLimit = 200_000
    private static let tokenLimit: UInt64 = 1_000_000_000

    static func read(databaseURL: URL, limit: Int) throws -> Usage {
        let live = FileManager.default.fileExists(atPath: databaseURL.path + "-wal")
        let database = try SQLiteDatabase(readOnly: databaseURL, immutable: !live)
        var usage = Usage(events: [], bytes: 0, truncated: false)
        // Some other database in the folder: nothing to read, and not an error.
        let tables = try database.prepare(
            "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('gen_metadata', 'steps')")
            .first { $0.int(0) } ?? 0
        guard tables == 2 else { return usage }
        // One view of the database for both tables, so a generation and its step are seen together.
        try database.execute("BEGIN")

        // A generation has no time of its own. The step it produced has one,
        // and repeats the generation's response id (step.9.7).
        var times: [Data: Date] = [:]
        var steps = 0
        try database.prepare("SELECT metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx LIMIT ?1")
            .forEach([stepLimit]) { row in
                steps += 1
                let blob = row.data(0)
                usage.bytes += blob.count
                let step = ProtobufMessage(blob)
                guard let id = step.message(9)?.bytes(7), !id.isEmpty, times[id] == nil,
                      let created = step.message(1), let seconds = created.varint(1),
                      (1_000_000_000...4_102_444_800).contains(seconds) else { return }
                let nanos = min(created.varint(2) ?? 0, 999_999_999)
                times[id] = Date(timeIntervalSince1970: Double(seconds) + Double(nanos) / 1_000_000_000)
            }

        var rows = 0
        var previous: Date?
        try database.prepare("SELECT idx, data FROM gen_metadata WHERE data IS NOT NULL ORDER BY idx LIMIT ?1")
            .forEach([limit + 1]) { row in
                rows += 1
                guard rows <= limit else { return }
                let blob = row.data(1)
                usage.bytes += blob.count
                guard let generation = ProtobufMessage(blob).message(1), let counts = generation.message(4) else { return }
                func count(_ field: Int) -> Int? {
                    guard let value = counts.varint(field) else { return 0 }
                    return value <= tokenLimit ? Int(value) : nil
                }
                // Input (2) leaves out the cached part (5); output (3) includes thinking.
                guard let input = count(2), let output = count(3), let cacheRead = count(5),
                      input + output + cacheRead > 0 else { return }
                let id = counts.bytes(7) ?? Data()
                // A generation whose step isn't written yet borrows the time of the one before it.
                guard let timestamp = times[id] ?? previous else { return }
                previous = timestamp
                let identity = id.isEmpty ? "\(databaseURL.path)#\(row.int(0))"
                    : id.map { String($0, radix: 16) }.joined(separator: ".")
                usage.events.append(SpendEvent(
                    timestamp: timestamp, provider: .antigravity, model: modelName(generation.bytes(19)),
                    tokens: TokenBreakdown(input: input, cacheRead: cacheRead, output: output),
                    recordedUSD: nil, identity: identity))
            }
        usage.truncated = rows > limit || steps >= stepLimit
        return usage
    }

    /// Only something shaped like a model id is kept; anything else is dropped.
    private static func modelName(_ data: Data?) -> String {
        guard let data, (1...128).contains(data.count), let name = String(data: data, encoding: .utf8),
              name.unicodeScalars.allSatisfy({ scalar in
                  scalar.isASCII && (scalar.properties.isAlphabetic || ("0"..."9").contains(scalar) || "-._:/".unicodeScalars.contains(scalar))
              }) else { return "" }
        return name
    }
}
