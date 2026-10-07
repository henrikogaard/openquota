import Foundation
import CoreFoundation

/// Adapts OpenUsage's Claude request and Codex rollout normalization; see docs/estimated-spend.md.
struct SpendLogParser {
    let provider: SpendProvider
    let fileIdentity: String
    private var model = ""
    private var sessionID = ""
    private var previous: CodexTokens?
    private var sawMeta = false
    private var childGate: Date?
    private var fast = false
    private var ultrafast = false
    private(set) var incomplete = false

    init(provider: SpendProvider, fileIdentity: String) {
        self.provider = provider
        self.fileIdentity = fileIdentity
    }

    mutating func parse(_ line: Data, lineNumber: Int) -> [SpendEvent] {
        guard line.range(of: Data("usage".utf8)) != nil
            || (provider == .codex && line.range(of: Data("\"type\"".utf8)) != nil) else { return [] }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            incomplete = true
            return []
        }
        if provider == .codex { return codex(object).map { [$0] } ?? [] }
        guard object["isApiErrorMessage"] as? Bool != true,
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any] else { return [] }
        guard let timestamp = Self.date(object["timestamp"]),
              let tokens = Self.claudeTokens(usage) else { incomplete = true; return [] }
        let messageID = Self.text(message["id"])
        let identity = messageID ?? "\(fileIdentity):\(lineNumber)"
        let model = Self.text(message["model"]) ?? ""
        let cost = Self.number(object["costUSD"])
        var event = SpendEvent(
            timestamp: timestamp, provider: .claude, model: model, tokens: tokens,
            recordedUSD: cost, identity: identity,
            sidechain: object["isSidechain"] as? Bool == true,
            hasSpeed: usage["speed"] != nil)
        event.requestID = Self.text(object["requestId"])
        var events = [event]
        for (index, iteration) in ((usage["iterations"] as? [[String: Any]]) ?? []).enumerated()
            where iteration["type"] as? String == "advisor_message" {
            guard let tokens = Self.claudeTokens(iteration), let model = Self.text(iteration["model"]) else {
                incomplete = true
                continue
            }
            var advisor = event
            advisor.identity += ":advisor:\(index)"
            advisor.model = model
            advisor.tokens = tokens
            advisor.recordedUSD = nil
            events.append(advisor)
        }
        return events
    }

    private mutating func codex(_ object: [String: Any]) -> SpendEvent? {
        guard let payload = object["payload"] as? [String: Any] else { return nil }
        let type = object["type"] as? String
        if type == "session_meta", !sawMeta {
            sawMeta = true
            sessionID = Self.text(payload["id"]) ?? fileIdentity
            let source = payload["source"] as? [String: Any]
            let child = Self.text(payload["forked_from_id"]) != nil
                || Self.text(payload["parent_thread_id"]) != nil
                || payload["thread_source"] as? String == "subagent"
                || (source?["subagent"] != nil && !(source?["subagent"] is NSNull))
            if child { childGate = Self.date(object["timestamp"]) ?? .distantFuture }
            return nil
        }
        if type == "turn_context" {
            if let value = Self.model(payload) { model = value }
            updateTier(payload)
            return nil
        }
        guard type == "event_msg" else { return nil }
        switch payload["type"] as? String {
        case "thread_settings_applied":
            updateTier(payload)
            return nil
        case "task_started":
            if let gate = childGate, let started = Self.number(payload["started_at"]) {
                let threshold = gate == .distantFuture ? Self.date(object["timestamp"]) : gate
                if let threshold, started >= threshold.timeIntervalSince1970.rounded(.down) {
                    childGate = nil
                }
            }
            return nil
        case "token_count": break
        default: return nil
        }
        guard let info = payload["info"] as? [String: Any] else { return nil }
        let totals = (info["total_token_usage"] as? [String: Any]).flatMap(CodexTokens.init)
        if childGate != nil {
            previous = totals ?? previous
            return nil
        }
        if let totals, totals == previous { return nil }
        let last = (info["last_token_usage"] as? [String: Any]).flatMap(CodexTokens.init)
        let delta = last ?? totals.map { $0.subtracting(previous) }
        previous = totals ?? previous
        guard let delta, let timestamp = Self.date(object["timestamp"]) else {
            incomplete = true
            return nil
        }
        if let value = Self.model(payload) ?? Self.model(info) { model = value }
        let cached = min(delta.cached, delta.input)
        let tokens = TokenBreakdown(input: delta.input - cached, cacheRead: cached, output: delta.output)
        guard tokens.totalTokens > 0 else { return nil }
        let identity = [
            sessionID.isEmpty ? fileIdentity : sessionID,
            String(timestamp.timeIntervalSince1970),
            model, String(delta.input), String(cached), String(delta.output), String(delta.reasoning)
        ].joined(separator: "|")
        return SpendEvent(
            timestamp: timestamp, provider: .codex, model: model, tokens: tokens,
            recordedUSD: nil, identity: identity, fast: fast, ultrafast: ultrafast)
    }

    private mutating func updateTier(_ payload: [String: Any]) {
        let settings = payload["thread_settings"] as? [String: Any]
        if let tier = Self.text(settings?["service_tier"] ?? payload["service_tier"]) {
            fast = tier == "fast" || tier == "priority"
            ultrafast = tier == "ultrafast"
            if !["fast", "priority", "ultrafast", "default", "standard", "auto"].contains(tier) {
                incomplete = true
            }
        }
    }

    private static func claudeTokens(_ usage: [String: Any]) -> TokenBreakdown? {
        guard let input = integer(usage["input_tokens"]), let output = integer(usage["output_tokens"]) else {
            return nil
        }
        if let speed = usage["speed"] as? String, !["fast", "standard"].contains(speed) { return nil }
        let creation = usage["cache_creation"] as? [String: Any]
        guard let write5 = integer(creation != nil ? (creation?["ephemeral_5m_input_tokens"] ?? 0)
                                  : (usage["cache_creation_input_tokens"] ?? 0)),
              let write1 = integer(creation?["ephemeral_1h_input_tokens"] ?? 0),
              let read = integer(usage["cache_read_input_tokens"] ?? 0) else { return nil }
        return TokenBreakdown(input: input, cacheWrite5m: write5, cacheWrite1h: write1,
                              cacheRead: read, output: output, isFast: usage["speed"] as? String == "fast")
    }

    static func number(_ value: Any?) -> Double? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue >= 0, value.doubleValue <= 1_000_000_000_000
        else { return nil }
        return value.doubleValue
    }

    static func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value.rounded(.down) == value else { return nil }
        return Int(value)
    }

    static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512 else { return nil }
        return value
    }

    static func date(_ value: Any?) -> Date? {
        guard let value = text(value) else { return nil }
        return (try? Date(value, strategy: .iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon)))
            ?? (try? Date(value, strategy: .iso8601))
    }

    private static func model(_ object: [String: Any]) -> String? {
        text(object["model"]) ?? text(object["model_name"])
            ?? text((object["metadata"] as? [String: Any])?["model"])
    }

    private struct CodexTokens: Equatable {
        var input: Int
        var cached: Int
        var output: Int
        var reasoning: Int

        init?(_ object: [String: Any]) {
            guard let input = SpendLogParser.integer(object["input_tokens"] ?? object["prompt_tokens"] ?? object["input"] ?? 0),
                  let cached = SpendLogParser.integer(object["cached_input_tokens"] ?? object["cache_read_input_tokens"] ?? object["cached_tokens"] ?? 0),
                  let output = SpendLogParser.integer(object["output_tokens"] ?? object["completion_tokens"] ?? object["output"] ?? 0),
                  let reasoning = SpendLogParser.integer(object["reasoning_output_tokens"] ?? object["reasoning_tokens"] ?? 0)
            else { return nil }
            self.input = input
            self.cached = cached
            self.output = output
            self.reasoning = reasoning
        }

        func subtracting(_ other: Self?) -> Self {
            var result = self
            result.input = max(0, input - (other?.input ?? 0))
            result.cached = max(0, cached - (other?.cached ?? 0))
            result.output = max(0, output - (other?.output ?? 0))
            result.reasoning = max(0, reasoning - (other?.reasoning ?? 0))
            return result
        }
    }
}
