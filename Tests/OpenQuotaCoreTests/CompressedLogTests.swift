import XCTest
import libzstd
@testable import OpenQuotaCore

/// Codex compresses older rollouts to `.jsonl.zst`. All data here is synthetic.
final class CompressedLogTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_374_400) // 2026-10-07 12:00 UTC
    private let stamp = "2026-10-07T10:00:00.000Z"
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var pricing: ModelPricing {
        let rates = ModelRates(inputPerMillion: 2, outputPerMillion: 10, cacheWritePerMillion: 2.5,
                               cacheReadPerMillion: 0.2, inputAbove200kPerMillion: 4, outputAbove200kPerMillion: 20,
                               cacheWriteAbove200kPerMillion: 5, cacheReadAbove200kPerMillion: 0.4,
                               fastMultiplier: 2)
        return ModelPricing(supplement: PricingSupplement(),
                            primary: PricingCatalog(entries: ["gpt-5": rates]), secondary: PricingCatalog())
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("oq-zst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func compress(_ data: Data) -> Data {
        var output = [UInt8](repeating: 0, count: ZSTD_compressBound(data.count))
        let written = data.withUnsafeBytes { ZSTD_compress(&output, output.count, $0.baseAddress, data.count, 3) }
        XCTAssertEqual(ZSTD_isError(written), 0)
        return Data(output[0..<written])
    }

    private func decompress(_ url: URL, maxOutput: Int = 1 << 30) throws -> Data {
        var result = Data()
        try ZstdFile.read(url, maxOutput: maxOutput) { result.append($0) }
        return result
    }

    /// A Codex rollout: session, model, then cumulative token snapshots.
    private func rollout(session: String, snapshots: [(input: Int, output: Int)]) throws -> Data {
        var lines: [[String: Any]] = [
            ["type": "session_meta", "timestamp": stamp, "payload": ["id": session]],
            ["type": "turn_context", "payload": ["model": "gpt-5"]],
        ]
        for snapshot in snapshots {
            lines.append(["type": "event_msg", "timestamp": stamp, "payload":
                ["type": "token_count", "info":
                    ["total_token_usage": ["input_tokens": snapshot.input, "cached_input_tokens": 0,
                                          "output_tokens": snapshot.output, "reasoning_output_tokens": 0]]]])
        }
        return try lines.reduce(into: Data()) {
            $0.append(try JSONSerialization.data(withJSONObject: $1, options: [.sortedKeys]))
            $0.append(0x0A)
        }
    }

    // MARK: Decompression

    func testReadsBackDataLargerThanOneChunk() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        // Several megabytes that don't compress to nothing, so both the input
        // and the output side take many rounds.
        var generator = SystemRandomNumberGenerator()
        var original = Data()
        for index in 0..<60_000 {
            original.append(Data("line \(index) \(UInt64.random(in: 0...UInt64.max, using: &generator))\n".utf8))
        }
        let url = root.appendingPathComponent("big.zst")
        try compress(original).write(to: url)
        XCTAssertEqual(try decompress(url), original)
    }

    func testFrameEndingExactlyOnTheOutputBufferEdgeIsComplete() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let edge = ZSTD_DStreamOutSize()
        for (name, count) in [("one", edge), ("two", edge * 2), ("under", edge - 1), ("over", edge + 1)] {
            let original = Data((0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 7) })
            let url = root.appendingPathComponent("\(name).zst")
            try compress(original).write(to: url)
            XCTAssertEqual(try decompress(url), original, name)
        }
        // Two frames, the first ending on the edge.
        let first = Data(repeating: 0x61, count: edge)
        let two = root.appendingPathComponent("frames.zst")
        try (compress(first) + compress(Data("tail\n".utf8))).write(to: two)
        XCTAssertEqual(try decompress(two), first + Data("tail\n".utf8))
    }

    func testEmptyFrameAndSeveralFramesInOneFile() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let empty = root.appendingPathComponent("empty.zst")
        try compress(Data()).write(to: empty)
        XCTAssertEqual(try decompress(empty), Data())
        let two = root.appendingPathComponent("two.zst")
        try (compress(Data("one\n".utf8)) + compress(Data("two\n".utf8))).write(to: two)
        XCTAssertEqual(try decompress(two), Data("one\ntwo\n".utf8))
    }

    func testRejectsGarbageCutOffFilesAndOversizedOutput() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = root.appendingPathComponent("garbage.zst")
        try Data("this is not zstd at all".utf8).write(to: garbage)
        XCTAssertThrowsError(try decompress(garbage))

        let whole = compress(Data(repeating: 0x41, count: 500_000) + Data((0..<50_000).map { UInt8($0 % 251) }))
        let cut = root.appendingPathComponent("cut.zst")
        try whole.prefix(whole.count / 2).write(to: cut)
        XCTAssertThrowsError(try decompress(cut)) { XCTAssertEqual($0 as? ZstdFile.Failure, .init(description: "incomplete")) }

        let bomb = root.appendingPathComponent("bomb.zst")
        try whole.write(to: bomb)
        XCTAssertThrowsError(try decompress(bomb, maxOutput: 100_000)) {
            XCTAssertEqual($0 as? ZstdFile.Failure, .init(description: "too large"))
        }
        XCTAssertThrowsError(try decompress(root.appendingPathComponent("missing.zst")))
    }

    // MARK: Scanner

    func testScannerReadsCompressedCodexRolloutsOnce() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent(".codex/sessions/2026/10/07")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try compress(rollout(session: "old", snapshots: [(1_000, 100), (1_500, 180)]))
            .write(to: logs.appendingPathComponent("rollout-old.jsonl.zst"))
        try rollout(session: "new", snapshots: [(200, 20)]).write(to: logs.appendingPathComponent("rollout-new.jsonl"))
        // Other compressed files are not logs.
        try compress(Data("{}\n".utf8)).write(to: logs.appendingPathComponent("notes.txt.zst"))

        let sources = [SpendLogSource(provider: .codex, directory: root.appendingPathComponent(".codex/sessions"))]
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        let first = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(first.filesRead, 2)
        XCTAssertFalse(first.isPartial)
        let total = first.total(provider: .codex, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(total.inputTokens, 1_500 + 200)
        XCTAssertEqual(total.outputTokens, 180 + 20)
        XCTAssertEqual(total.pricedEvents, 3)

        let second = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(second.filesRead, 0)
        XCTAssertEqual(second.filesReused, 2)
    }

    func testPlainLogAndItsCompressedCopyCountOnce() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let data = try rollout(session: "s", snapshots: [(1_000, 100)])
        let plain = logs.appendingPathComponent("rollout-s.jsonl")
        try data.write(to: plain)
        let sources = [SpendLogSource(provider: .codex, directory: logs)]
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        _ = await scanner.scan(sources: sources, now: now, calendar: calendar)
        // Codex compresses the log and removes the plain one.
        try compress(data).write(to: logs.appendingPathComponent("rollout-s.jsonl.zst"))
        try FileManager.default.removeItem(at: plain)
        let after = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(after.filesRead, 1)
        let total = after.total(provider: .codex, period: .today, now: now, calendar: calendar)
        XCTAssertEqual(total.inputTokens, 1_000)
        XCTAssertEqual(total.events, 1)
    }

    func testDamagedCompressedLogIsMarkedAndNotReadAgain() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try Data("not zstd".utf8).write(to: logs.appendingPathComponent("rollout-bad.jsonl.zst"))
        let sources = [SpendLogSource(provider: .codex, directory: logs)]
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        let first = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertTrue(first.isPartial)
        XCTAssertEqual(first.unreadableFiles, 1)
        XCTAssertEqual(first.pendingFiles, 0)
        let second = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(second.filesRead, 0)
        XCTAssertEqual(second.filesReused, 1)
    }

    func testHugeCodexToolOutputLineIsSkippedWithoutMarkingTheLogPartial() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let big = String(repeating: "x", count: 1_200_000)
        let toolOutput = Data(#"{"timestamp":"\#(stamp)","type":"response_item","payload":{"type":"custom_tool_call_output","output":"\#(big)"}}"#.utf8) + Data([0x0A])
        let unknown = Data(#"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","junk":"\#(big)"}}"#.utf8) + Data([0x0A])
        let usage = try rollout(session: "s", snapshots: [(1_000, 100)])
        // Compressed and plain, with the long line before the usage.
        try compress(toolOutput + usage).write(to: logs.appendingPathComponent("rollout-a.jsonl.zst"))
        try (toolOutput + (try rollout(session: "t", snapshots: [(500, 50)]))).write(to: logs.appendingPathComponent("rollout-b.jsonl"))
        let sources = [SpendLogSource(provider: .codex, directory: logs)]
        let scanner = LocalSpendScanner(limits: .init(), pricing: pricing)
        let clean = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertFalse(clean.isPartial)
        XCTAssertEqual(clean.unreadableFiles, 0)
        XCTAssertEqual(clean.total(provider: .codex, period: .today, now: now, calendar: calendar).inputTokens, 1_500)

        // A long line that could have held usage still marks its log.
        try compress(unknown + usage).write(to: logs.appendingPathComponent("rollout-c.jsonl.zst"))
        let marked = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertTrue(marked.isPartial)
        XCTAssertEqual(marked.unreadableFiles, 1)
        XCTAssertTrue(LocalSpendScanner.oversizedLineMatters(.claude, head: toolOutput))
    }

    func testFolderWithMoreFilesThanOnePassTakesIsFinishedOverPasses() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent(".codex/sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for index in 0..<7 {
            try compress(rollout(session: "s\(index)", snapshots: [(100 + index, 10)]))
                .write(to: logs.appendingPathComponent("rollout-\(index).jsonl.zst"))
        }
        var limits = LocalSpendScanner.Limits()
        limits.files = 3
        let scanner = LocalSpendScanner(limits: limits, pricing: pricing)
        let sources = [SpendLogSource(provider: .codex, directory: logs)]
        var pass = await scanner.scan(sources: sources, now: now, calendar: calendar)
        XCTAssertEqual(pass.filesRead, 3)
        XCTAssertEqual(pass.pendingFiles, 4)
        var passes = 1
        while pass.pendingFiles > 0, passes < 10 {
            pass = await scanner.scan(sources: sources, now: now, calendar: calendar)
            passes += 1
        }
        XCTAssertEqual(passes, 3)
        XCTAssertFalse(pass.isPartial)
        XCTAssertEqual(pass.total(provider: .codex, period: .today, now: now, calendar: calendar).events, 7)
    }
}
