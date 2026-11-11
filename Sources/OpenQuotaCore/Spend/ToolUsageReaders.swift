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
