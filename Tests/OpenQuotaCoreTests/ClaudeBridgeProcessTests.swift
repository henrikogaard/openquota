import Foundation
import XCTest
@testable import OpenQuotaCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class ClaudeBridgeProcessTests: XCTestCase {
    func test_largeInputAndUnusedChildStdinPreserveOutputAndOnlyPersistReading() throws {
        let prefix = #"{"session_id":"fixture-session-secret","cwd":"/private/work","transcript":"fixture-transcript-secret","rate_limits":{"five_hour":{"used_percentage":25}},"padding":""#
        let suffix = #""}"#
        let targetSize = 200 * 1_024
        let padding = String(repeating: "x", count: targetSize - prefix.utf8.count - suffix.utf8.count)
        let input = Data((prefix + padding + suffix).utf8)
        XCTAssertEqual(input.count, targetSize)

        let result = try runBridge(command: "printf before", input: input)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, Data("before".utf8))
        assertSanitizedReading(in: result.connectionDirectory, excludes: [
            "fixture-session-secret", "/private/work", "fixture-transcript-secret", "padding",
        ])
    }

    func test_catReceivesAndForwardsOriginalInputExactly() throws {
        let input = Data(#"{"session_id":"fixture-session-secret","rate_limits":{"five_hour":{"used_percentage":12.5}},"transcript":"fixture-transcript-secret"}"#.utf8)
        let result = try runBridge(command: "cat", input: input)

        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, input)
        assertSanitizedReading(in: result.connectionDirectory, excludes: [
            "fixture-session-secret", "fixture-transcript-secret",
        ])
    }

    func test_runtimeKillsAndReapsChildIgnoringSIGTERM() throws {
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":1}}}"#.utf8)
        let temporaryDirectory = try makeDirectory()
        let pidFile = temporaryDirectory.appendingPathComponent("child.pid")
        let command = "trap '' TERM; printf '%s' \"$$\" > \(pidFile.path); while :; do :; done"
        let startedAt = Date()
        let result = try runBridge(
            command: command,
            input: input,
            in: temporaryDirectory,
            cleanupPIDFile: pidFile,
            timeout: 15)

        XCTAssertFalse(result.timedOut, "Bridge exceeded its external subprocess deadline")
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 15)
        XCTAssertNotNil(try? Data(contentsOf: pidFile))
    }

    private func runBridge(
        command: String,
        input: Data,
        in parent: URL? = nil,
        cleanupPIDFile: URL? = nil,
        timeout: TimeInterval = 5
    ) throws -> BridgeResult {
        signal(SIGPIPE, SIG_IGN)
        let directory = try makeDirectory(inside: parent)
        let metadata = ClaudeBridgeMetadata(
            installedCommand: "openquota-bridge test",
            originalStatusLine: try JSONSerialization.data(withJSONObject: [
                "type": "command",
                "command": command,
            ], options: [.sortedKeys]))
        try JSONEncoder.openQuota.encode(metadata)
            .write(to: directory.appendingPathComponent("bridge-metadata.json"))

        let executable = try findBridgeExecutable()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--connection-directory", directory.path]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }
        try process.run()
        let processID = process.processIdentifier
        inputPipe.fileHandleForReading.closeFile()
        outputPipe.fileHandleForWriting.closeFile()

        let writer = BridgeInputWriter(handle: inputPipe.fileHandleForWriting, input: input)
        let reader = BridgeOutputReader(handle: outputPipe.fileHandleForReading)
        let writerDone = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            writer.write()
            writerDone.signal()
        }
        DispatchQueue.global().async {
            reader.read()
            readerDone.signal()
        }

        let timedOut = terminated.wait(timeout: .now() + timeout) == .timedOut
        if timedOut {
            _ = kill(processID, SIGKILL)
            process.waitUntilExit()
            if let cleanupPIDFile { killRecordedChild(at: cleanupPIDFile) }
        } else {
            process.waitUntilExit()
        }
        _ = writerDone.wait(timeout: .now() + 2)
        _ = readerDone.wait(timeout: .now() + 2)
        let result = BridgeResult(
            output: reader.value,
            status: process.terminationStatus,
            timedOut: timedOut,
            connectionDirectory: directory)
        return result
    }

    private func assertSanitizedReading(in directory: URL, excludes values: [String]) {
        let readingURL = directory.appendingPathComponent("reading.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: readingURL.path))
        let data = (try? Data(contentsOf: readingURL)) ?? Data()
        let encoded = String(decoding: data, as: UTF8.self)
        for value in values {
            XCTAssertFalse(encoded.contains(value))
        }
        XCTAssertNoThrow(try JSONDecoder.openQuota.decode(ClaudeUsageReading.self, from: data))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertEqual(Set(files), ["bridge-metadata.json", "reading.json"])
    }

    private func findBridgeExecutable() throws -> URL {
        // macOS runs the bundle inside Xcode's xctest host, so arguments[0]
        // points at the runner, not the build dir — also search from the
        // test bundle's own location.
        let roots = [
            URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent(),
            Bundle(for: Self.self).bundleURL,
        ]
        for root in roots {
            var directory = root
            for _ in 0..<8 {
                let candidate = directory.appendingPathComponent("openquota-bridge")
                if FileManager.default.isExecutableFile(atPath: candidate.path) {
                    return candidate
                }
                directory.deleteLastPathComponent()
            }
        }
        throw BridgeTestError.helperNotFound
    }

    private func makeDirectory(inside parent: URL? = nil) throws -> URL {
        let directory = (parent ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("openquota-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func killRecordedChild(at pidURL: URL) {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = Int32(text) else {
            return
        }
        _ = kill(pid_t(pid), SIGKILL)
    }
}

private struct BridgeResult {
    let output: Data
    let status: Int32
    let timedOut: Bool
    let connectionDirectory: URL
}

private final class BridgeInputWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let input: Data

    init(handle: FileHandle, input: Data) {
        self.handle = handle
        self.input = input
    }

    func write() {
        defer { try? handle.close() }
        try? handle.write(contentsOf: input)
    }
}

private final class BridgeOutputReader: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var output = Data()

    init(handle: FileHandle) {
        self.handle = handle
    }

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return output
    }

    func read() {
        let data = handle.readDataToEndOfFile()
        lock.lock()
        output = data
        lock.unlock()
        try? handle.close()
    }
}

private enum BridgeTestError: Error {
    case helperNotFound
}
