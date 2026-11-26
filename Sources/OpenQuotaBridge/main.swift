import Foundation
import OpenQuotaCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct OpenQuotaBridge {
    private enum Provider: String {
        case claude
        case antigravity
    }

    private struct Invocation {
        let provider: Provider
        let directory: URL
    }

    private static let inputLimit = 1_048_576
    private static let outputLimit = 1_048_576
    private static let runtimeLimit: TimeInterval = 10
    private static let metadataName = "bridge-metadata.json"

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let deadline = Date().addingTimeInterval(runtimeLimit)
        guard let invocation = parseArguments(),
              let originalCommand = loadOriginalCommand(from: invocation.directory, provider: invocation.provider),
              let input = readInput(deadline: deadline) else {
            return
        }
        captureReading(input: input, invocation: invocation)
        guard let command = originalCommand.command, !command.isEmpty else { return }
        let status = run(command: command, input: input, deadline: deadline)
        exit(status)
    }

    private struct LoadedMetadata {
        let command: String?
    }

    private static func captureReading(input: Data, invocation: Invocation) {
        switch invocation.provider {
        case .claude:
            if let reading = try? ClaudeUsageReading.capture(input),
               let encoded = try? encode(reading) {
                let source = ClaudeReadingSource.from(environment: ProcessInfo.processInfo.environment)
                writeReading(encoded, to: invocation.directory.appendingPathComponent(source?.fileName ?? "reading.json"))
            }
        case .antigravity:
            if let reading = try? AntigravityUsageReading.capture(input),
               let encoded = try? encode(reading) {
                writeReading(encoded, to: invocation.directory.appendingPathComponent("reading.json"))
            }
        }
    }

    private static func parseArguments() -> Invocation? {
        let arguments = CommandLine.arguments
        var provider: Provider = .claude
        var directoryPath: String?
        var index = 1
        while index < arguments.count {
            switch arguments[index] {
            case "--connection-directory":
                guard index + 1 < arguments.count, directoryPath == nil else { return nil }
                directoryPath = arguments[index + 1]
                index += 2
            case "--provider":
                guard index + 1 < arguments.count,
                      let parsed = Provider(rawValue: arguments[index + 1]) else { return nil }
                provider = parsed
                index += 2
            default:
                return nil
            }
        }
        guard let directoryPath, directoryPath.hasPrefix("/") else { return nil }
        let directory = URL(fileURLWithPath: directoryPath).standardizedFileURL
        guard directory.path == directoryPath,
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else {
            return nil
        }
        return Invocation(provider: provider, directory: directory)
    }

    private static func loadOriginalCommand(from directory: URL, provider: Provider) -> LoadedMetadata? {
        let url = directory.appendingPathComponent(metadataName)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              let handle = try? FileHandle(forReadingFrom: url) else {
            return nil
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: inputLimit + 1),
              data.count <= inputLimit else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        switch provider {
        case .claude:
            guard let metadata = try? decoder.decode(ClaudeBridgeMetadata.self, from: data) else { return nil }
            return LoadedMetadata(command: metadata.originalCommand)
        case .antigravity:
            guard let metadata = try? decoder.decode(AntigravityBridgeMetadata.self, from: data) else { return nil }
            return LoadedMetadata(command: metadata.originalCommand)
        }
    }

    private static func readInput(deadline: Date) -> Data? {
        var input = Data()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var descriptor = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN | POLLHUP), revents: 0)
            let timeout = max(1, Int32(min(remaining * 1_000, Double(Int32.max))))
            let ready = poll(&descriptor, 1, timeout)
            guard ready > 0 else { return nil }
            let count = buffer.withUnsafeMutableBytes {
                read(STDIN_FILENO, $0.baseAddress, $0.count)
            }
            if count == 0 { return input }
            guard count > 0, input.count + count <= inputLimit else { return nil }
            input.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func writeReading(_ data: Data, to url: URL) {
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
        } catch {
            return
        }
    }

    private static func encode<T: Encodable>(_ reading: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(reading)
    }

    private static func run(command: String, input: Data, deadline: Date) -> Int32 {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.standardError
        do {
            try process.run()
        } catch {
            stdin.fileHandleForReading.closeFile()
            stdin.fileHandleForWriting.closeFile()
            stdout.fileHandleForReading.closeFile()
            stdout.fileHandleForWriting.closeFile()
            return 1
        }

        let pid = process.processIdentifier
        _ = setpgid(pid, pid)
        stdin.fileHandleForReading.closeFile()
        stdout.fileHandleForWriting.closeFile()
        let inputFD = stdin.fileHandleForWriting.fileDescriptor
        let outputFD = stdout.fileHandleForReading.fileDescriptor
        setNonblocking(inputFD)
        setNonblocking(outputFD)
        var inputOffset = 0
        var output = Data()
        var childOutputClosed = false
        var childInputClosed = false
        var failed = false
        var timedOut = false
        var inputBuffer = [UInt8](input)
        var readBuffer = [UInt8](repeating: 0, count: 32 * 1024)
        let closeChildInput = {
            guard !childInputClosed else { return }
            stdin.fileHandleForWriting.closeFile()
            childInputClosed = true
        }
        if inputBuffer.isEmpty {
            closeChildInput()
        }

        while true {
            if !process.isRunning && childOutputClosed {
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                timedOut = true
                break
            }

            var descriptors: [pollfd] = []
            let inputIndex: Int?
            if !childInputClosed && inputOffset < inputBuffer.count {
                inputIndex = descriptors.count
                descriptors.append(pollfd(fd: inputFD, events: Int16(POLLOUT | POLLERR | POLLHUP), revents: 0))
            } else {
                inputIndex = nil
            }
            let readIndex = descriptors.count
            if !childOutputClosed {
                descriptors.append(pollfd(fd: outputFD, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0))
            }
            let ready = descriptors.withUnsafeMutableBufferPointer {
                poll($0.baseAddress, nfds_t($0.count), max(1, Int32(min(remaining * 1_000, 100))))
            }
            if ready < 0 {
                if errno == EINTR { continue }
                failed = true
                break
            }

            if let inputIndex, descriptors.indices.contains(inputIndex) {
                let events = descriptors[inputIndex].revents
                if events & Int16(POLLNVAL) != 0 {
                    failed = true
                    break
                }
                if events & Int16(POLLOUT) != 0 {
                    let count = inputBuffer.withUnsafeBytes { bytes -> Int in
                        guard let base = bytes.baseAddress else { return 0 }
                        return write(inputFD, base.advanced(by: inputOffset),
                                     min(bytes.count - inputOffset, 32 * 1024))
                    }
                    if count > 0 {
                        inputOffset += count
                    } else if count == 0 || errno == EPIPE {
                        closeChildInput()
                    } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                        failed = true
                        break
                    }
                }
                if !childInputClosed && events & Int16(POLLERR | POLLHUP) != 0 {
                    closeChildInput()
                }
            }

            if !childOutputClosed {
                let index = readIndex
                if descriptors.indices.contains(index),
                   descriptors[index].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                    while true {
                        let count = readBuffer.withUnsafeMutableBytes {
                            read(outputFD, $0.baseAddress, $0.count)
                        }
                        if count > 0 {
                            guard output.count + count <= outputLimit else {
                                failed = true
                                break
                            }
                            output.append(contentsOf: readBuffer.prefix(count))
                        } else if count == 0 {
                            childOutputClosed = true
                            stdout.fileHandleForReading.closeFile()
                            break
                        } else if errno == EAGAIN || errno == EWOULDBLOCK {
                            break
                        } else if errno == EINTR {
                            continue
                        } else {
                            failed = true
                            break
                        }
                    }
                    if failed { break }
                }
            }

            if inputOffset == inputBuffer.count {
                closeChildInput()
            }
            if !process.isRunning && !childOutputClosed && ready == 0 {
                continue
            }
        }

        if timedOut || failed {
            if process.isRunning { process.terminate() }
            _ = kill(-pid, SIGKILL)
            if process.isRunning { _ = kill(pid, SIGKILL) }
        }
        let reapedStatus = reap(pid: pid)
        if !childInputClosed { stdin.fileHandleForWriting.closeFile() }
        if !childOutputClosed { stdout.fileHandleForReading.closeFile() }
        if !failed {
            failed = !writeAll(output, deadline: deadline)
        }
        inputBuffer.removeAll(keepingCapacity: false)
        if timedOut || failed { return 1 }
        if let reapedStatus { return reapedStatus }
        // terminationStatus is only valid once Foundation knows the task
        // ended; give its monitor a moment after our waitpid/ECHILD, then
        // fail rather than query a task it still reports as running.
        let settle = Date().addingTimeInterval(0.5)
        while process.isRunning, Date() < settle { usleep(10_000) }
        return process.isRunning ? 1 : process.terminationStatus
    }

    // NSConcreteTask.waitUntilExit() can spin a runloop forever on macOS when
    // the termination notification is delivered to a blocked thread; reap via
    // waitpid with a hard bound instead. Returns the child's exit status when
    // we reap it; nil on ECHILD (Foundation already reaped) or any other
    // error — the caller then resolves the status through the task object.
    private static func reap(pid: pid_t) -> Int32? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid {
                if status & 0x7f == 0 { return (status >> 8) & 0xff }
                return 128 + (status & 0x7f)
            }
            if result == -1 {
                if errno == EINTR { continue }
                return nil
            }
            usleep(10_000)
        }
        return nil
    }

    private static func setNonblocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
    }

    private static func writeAll(_ data: Data, deadline: Date) -> Bool {
        let fd = STDOUT_FILENO
        let originalFlags = fcntl(fd, F_GETFL)
        setNonblocking(fd)
        defer {
            if originalFlags >= 0 { _ = fcntl(fd, F_SETFL, originalFlags) }
        }
        var written = 0
        while written < data.count {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT | POLLERR | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, max(1, Int32(min(remaining * 1_000, Double(Int32.max)))))
            guard ready > 0 else {
                if ready < 0 && errno == EINTR { continue }
                return false
            }
            guard descriptor.revents & Int16(POLLOUT) != 0 else { return false }
            let count = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return write(fd, base.advanced(by: written), min(bytes.count - written, 32 * 1024))
            }
            if count > 0 {
                written += count
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
