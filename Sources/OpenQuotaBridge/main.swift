import Foundation
import OpenQuotaCore
#if os(Linux)
import Glibc
#else
import Darwin
#endif

@main
struct OpenQuotaBridge {
    private static let inputLimit = 1_048_576
    private static let outputLimit = 1_048_576
    private static let runtimeLimit: TimeInterval = 10
    private static let metadataName = "bridge-metadata.json"

    static func main() {
        signal(SIGPIPE, SIG_IGN)
        let deadline = Date().addingTimeInterval(runtimeLimit)
        guard let directory = connectionDirectory(),
              let metadata = loadMetadata(from: directory),
              let input = readInput(deadline: deadline) else {
            return
        }
        if let reading = try? ClaudeUsageReading.capture(input),
           let encoded = try? encodeReading(reading) {
            writeReading(encoded, to: directory.appendingPathComponent("reading.json"))
        }
        guard let command = metadata.originalCommand, !command.isEmpty else { return }
        let status = run(command: command, input: input, deadline: deadline)
        exit(status)
    }

    private static func connectionDirectory() -> URL? {
        let arguments = CommandLine.arguments
        guard arguments.count == 3,
              arguments[1] == "--connection-directory",
              arguments[2].hasPrefix("/") else {
            return nil
        }
        let directory = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        guard directory.path == arguments[2],
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else {
            return nil
        }
        return directory
    }

    private static func loadMetadata(from directory: URL) -> ClaudeBridgeMetadata? {
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
        return try? decoder.decode(ClaudeBridgeMetadata.self, from: data)
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

    private static func encodeReading(_ reading: ClaudeUsageReading) throws -> Data {
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
        if inputBuffer.isEmpty {
            stdin.fileHandleForWriting.closeFile()
            childInputClosed = true
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
            if inputOffset < inputBuffer.count {
                descriptors.append(pollfd(fd: inputFD, events: Int16(POLLOUT | POLLERR | POLLHUP), revents: 0))
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

            if inputOffset < inputBuffer.count,
               !descriptors.isEmpty,
               descriptors[0].revents & Int16(POLLOUT) != 0 {
                let count = inputBuffer.withUnsafeBytes { bytes -> Int in
                    guard let base = bytes.baseAddress else { return 0 }
                    return write(inputFD, base.advanced(by: inputOffset),
                                 min(bytes.count - inputOffset, 32 * 1024))
                }
                if count > 0 {
                    inputOffset += count
                } else if count < 0 && errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
                    failed = true
                    break
                }
            } else if inputOffset < inputBuffer.count,
                      !descriptors.isEmpty,
                      descriptors[0].revents & Int16(POLLERR | POLLHUP) != 0 {
                failed = true
                break
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

            if inputOffset == inputBuffer.count && !childInputClosed {
                stdin.fileHandleForWriting.closeFile()
                childInputClosed = true
            }
            if !process.isRunning && !childOutputClosed && ready == 0 {
                continue
            }
        }

        if timedOut || failed {
            if process.isRunning { process.terminate() }
            _ = kill(-pid, SIGKILL)
        }
        if process.isRunning { process.waitUntilExit() }
        if !childInputClosed { stdin.fileHandleForWriting.closeFile() }
        if !childOutputClosed { stdout.fileHandleForReading.closeFile() }
        if !failed {
            failed = !writeAll(output, deadline: deadline)
        }
        inputBuffer.removeAll(keepingCapacity: false)
        return timedOut || failed ? 1 : process.terminationStatus
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
