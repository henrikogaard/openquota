import Foundation
#if os(Linux)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// Providers that already have their own CLI on the machine (Amp, Kiro,
/// Augment). Running `binary usage --json` inherits the CLI's auth entirely —
/// no credentials to store, no endpoints to hard-code. If the binary isn't
/// on PATH the provider simply reports no accounts and stays hidden.
public struct CLISpec: Sendable {
    public var id: String
    public var displayName: String
    /// Executable name, resolved against PATH-like dirs.
    public var binary: String
    /// Args that produce a usage JSON payload on stdout.
    public var args: [String]
    public var dashboardURL: String?
    /// Window field paths applied to the stdout JSON, same syntax as specs.
    public var windows: [ProviderSpec.WindowSpec]

    public init(id: String, displayName: String, binary: String, args: [String],
                dashboardURL: String? = nil,
                windows: [ProviderSpec.WindowSpec]) {
        self.id = id
        self.displayName = displayName
        self.binary = binary
        self.args = args
        self.dashboardURL = dashboardURL
        self.windows = windows
    }
}

public struct CLIProvider: UsageProvider {
    public let spec: CLISpec
    public var id: String { spec.id }
    public var displayName: String { spec.displayName }
    public var dashboardURL: URL? { spec.dashboardURL.flatMap(URL.init(string:)) }

    private let searchPath: [String]

    public init(spec: CLISpec, searchPath: [String]? = nil) {
        self.spec = spec
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.searchPath = searchPath ?? [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
        ]
    }

    private func binaryURL() -> URL? {
        for dir in searchPath {
            let url = URL(fileURLWithPath: dir).appendingPathComponent(spec.binary)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    public func accounts() async throws -> [AccountDescriptor] {
        guard binaryURL() != nil else { return [] }
        let identity = AccountIdentity(
            providerID: spec.id,
            id: AccountIdentity.makeID(providerID: spec.id, identityKey: spec.binary),
            label: spec.binary)
        return [AccountDescriptor(account: identity, source: .configFile)]
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let binary = binaryURL() else { throw ProviderError.notLoggedIn }
        let data = try await Self.run(binary: binary, args: spec.args)
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ProviderError.badResponse("non-JSON CLI output")
        }
        var windows: [UsageWindow] = []
        for (index, ws) in spec.windows.enumerated() {
            let window = UsageWindow(
                id: "\(spec.id).\(index)",
                label: ws.label,
                kind: ws.kind ?? .consumption,
                used: JSONPath.double(json, at: ws.used),
                limit: JSONPath.double(json, at: ws.limit),
                remaining: JSONPath.double(json, at: ws.remaining),
                unit: ws.unit,
                resetsAt: JSONPath.date(json, at: ws.resetsAt,
                                        format: ws.resetsAtFormat))
            windows.append(window)
        }
        guard windows.contains(where: {
            $0.used != nil || $0.remaining != nil
        }) else {
            throw ProviderError.badResponse("no usage fields in CLI output")
        }
        return UsageSnapshot(account: account.account,
                             providerID: spec.id, windows: windows)
    }

    /// Runs the binary with a watchdog (10s by default); stdout must fit a
    /// JSON payload. `environment` and `currentDirectory` default to the
    /// app's own; stdin is closed whenever an environment is given.
    static func run(
        binary: URL, args: [String],
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 10
    ) async throws -> Data {
        let cancellation = CLIRunCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let run = CLIProcessRun(
                    binary: binary,
                    args: args,
                    environment: environment,
                    currentDirectory: currentDirectory,
                    timeout: timeout,
                    continuation: continuation)
                cancellation.install(run)
                run.start()
            }
        }, onCancel: {
            cancellation.cancel()
        })
    }
}

private final class CLIRunCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var run: CLIProcessRun?
    private var cancelled = false

    func install(_ run: CLIProcessRun) {
        lock.lock()
        if cancelled {
            lock.unlock()
            run.cancel()
            return
        }
        self.run = run
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let run = self.run
        lock.unlock()
        run?.cancel()
    }
}

private final class CLIProcessRun: @unchecked Sendable {
    private static let maxOutputBytes = 1_048_576
    private static let readChunkBytes = 64 * 1024

    private let lock = NSLock()
    /// Serializes reads with pipe teardown; the reader can race termination.
    private let readLock = NSLock()
    private let binary: URL
    private let args: [String]
    private let environment: [String: String]?
    private let currentDirectory: URL?
    private let timeout: TimeInterval
    private var continuation: CheckedContinuation<Data, Error>?
    private var process: Process?
    private var stdout: Pipe?
    private var readHandle: FileHandle?
    private var readFD: Int32 = -1
    private var output = Data()
    private var watchdog: DispatchSourceTimer?
    private var finished = false

    init(
        binary: URL,
        args: [String],
        environment: [String: String]?,
        currentDirectory: URL?,
        timeout: TimeInterval,
        continuation: CheckedContinuation<Data, Error>
    ) {
        self.binary = binary
        self.args = args
        self.environment = environment
        self.currentDirectory = currentDirectory
        self.timeout = timeout
        self.continuation = continuation
    }

    func start() {
        let process = Process()
        let stdout = Pipe()
        let readHandle = stdout.fileHandleForReading
        let fd = readHandle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }

        lock.lock()
        guard !finished else {
            lock.unlock()
            readHandle.closeFile()
            stdout.fileHandleForWriting.closeFile()
            return
        }
        self.process = process
        self.stdout = stdout
        self.readHandle = readHandle
        self.readFD = fd
        process.executableURL = binary
        process.arguments = args
        if let environment {
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            self?.terminated(status: process.terminationStatus)
        }

        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            self?.timedOut()
        }
        watchdog = timer
        timer.resume()

        do {
            try process.run()
        } catch {
            stdout.fileHandleForWriting.closeFile()
            lock.unlock()
            closeReader()
            finish(error: ProviderError.notLoggedIn)
            return
        }
        // The child inherits its own stdout descriptor. Close the parent's
        // writer so EOF is observable once the process (and descendants) exit.
        stdout.fileHandleForWriting.closeFile()
        lock.unlock()
        // A plain thread, not a DispatchSourceRead: on Linux, libdispatch's
        // epoll backend intermittently crashed (SIGSEGV in its event loop)
        // with read sources on these short-lived pipes, even when the
        // descriptor was never closed. The thread owns the descriptor.
        Thread { self.readLoop() }.start()
    }

    func cancel() {
        finish(error: CancellationError())
    }

    private func timedOut() {
        finish(error: ProviderError.timedOut)
    }

    /// Polls with a short timeout so the loop notices `finish()` even while
    /// a descendant still holds the pipe's write end open.
    private func readLoop() {
        while true {
            lock.lock()
            let fd = finished ? -1 : readFD
            lock.unlock()
            guard fd >= 0 else { break }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            if poll(&descriptor, 1, 100) > 0, !readAvailable() { break }
        }
        closeReader()
    }

    /// Returns false once there is nothing more to read.
    @discardableResult
    private func readAvailable() -> Bool {
        readLock.lock()

        lock.lock()
        guard !finished, readFD >= 0 else {
            lock.unlock()
            readLock.unlock()
            return false
        }
        let fd = readFD
        lock.unlock()

        var buffer = [UInt8](repeating: 0, count: Self.readChunkBytes)
        var failure: Error?
        var reachedEOF = false
        while true {
            let count = buffer.withUnsafeMutableBytes {
                read(fd, $0.baseAddress, $0.count)
            }
            if count > 0 {
                lock.lock()
                if finished {
                    lock.unlock()
                    readLock.unlock()
                    return false
                }
                if output.count + count > Self.maxOutputBytes {
                    failure = ProviderError.badResponse(Localized.text("CLI output too large", "Utdata fra CLI er for store"))
                    lock.unlock()
                    break
                }
                output.append(contentsOf: buffer.prefix(count))
                lock.unlock()
            } else if count == 0 {
                reachedEOF = true
                break
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                failure = ProviderError.badResponse(Localized.text("CLI output read failed", "Kunne ikke lese utdata fra CLI"))
                break
            }
        }
        readLock.unlock()
        if let failure {
            finish(error: failure)
            return false
        }
        return !reachedEOF
    }

    private func terminated(status: Int32) {
        // Drain bytes already in the non-blocking pipe, but never wait for
        // EOF: a descendant may have inherited stdout from the CLI.
        readAvailable()
        lock.lock()
        let alreadyFinished = finished
        lock.unlock()
        guard !alreadyFinished else { return }
        if status == 0 {
            finish()
        } else {
            finish(error: ProviderError.serverError(Int(status)))
        }
    }

    private func finish(data: Data? = nil, error: Error? = nil) {
        lock.lock()
        guard !finished, let continuation else {
            lock.unlock()
            return
        }
        let resultData = data ?? output
        finished = true
        self.continuation = nil
        let process = self.process
        self.process = nil
        self.stdout = nil
        let watchdog = self.watchdog
        self.watchdog = nil
        lock.unlock()

        watchdog?.setEventHandler {}
        watchdog?.cancel()
        process?.terminationHandler = nil
        if let process, process.isRunning {
            process.terminate()
            #if os(Linux) || canImport(Darwin)
            _ = kill(process.processIdentifier, SIGKILL)
            #endif
        }

        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(returning: resultData)
        }
    }

    private func closeReader() {
        lock.lock()
        let readHandle = self.readHandle
        self.readHandle = nil
        self.readFD = -1
        lock.unlock()

        // Invalidate the descriptor, then wait out any read still using it.
        readLock.lock()
        readLock.unlock()
        readHandle?.closeFile()
    }
}

public enum CLIProviders {
    /// Field paths are best-effort: CLIs change their JSON shape and each
    /// window falls back to nil rather than failing the whole provider.
    public static func all(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [any UsageProvider] {
        let pathDirs = (environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        return [
            CLIProvider(spec: .init(
                id: "amp", displayName: "Amp",
                binary: "amp", args: ["usage", "--json"],
                dashboardURL: "https://ampcode.com/settings",
                windows: [
                    .init(label: "Month", kind: .consumption,
                          used: "$.used", limit: "$.limit",
                          resetsAt: "$.reset", resetsAtFormat: "epochSeconds"),
                ]),
                searchPath: pathDirs),
            CLIProvider(spec: .init(
                id: "kiro", displayName: "Kiro",
                binary: "kiro-cli", args: ["usage", "--json"],
                dashboardURL: "https://kiro.dev",
                windows: [
                    .init(label: "Month", kind: .requests,
                          used: "$.usage.used", limit: "$.usage.limit"),
                    .init(label: "Credits", kind: .credits,
                          remaining: "$.credits", unit: "credits"),
                ]),
                searchPath: pathDirs),
            CLIProvider(spec: .init(
                id: "augment", displayName: "Augment",
                binary: "auggie", args: ["quota", "--json"],
                dashboardURL: "https://app.augmentcode.com",
                windows: [
                    .init(label: "Month", kind: .consumption,
                          used: "$.used_percent", unit: "%"),
                ]),
                searchPath: pathDirs),
        ]
    }
}
