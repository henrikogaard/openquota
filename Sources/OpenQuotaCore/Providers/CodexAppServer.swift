import Foundation
import CoreFoundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

public struct CodexAccountRead: Sendable {
    public let planType: String?
    public let rateLimits: Data
}

public enum CodexExecutableResolver {
    public static func resolve(
        preferredPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        if let preferredPath {
            guard preferredPath.hasPrefix("/") else { return nil }
            return FileManager.default.isExecutableFile(atPath: preferredPath)
                ? URL(fileURLWithPath: preferredPath).standardizedFileURL : nil
        }
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        // GUI apps inherit launchd's minimal PATH, so also try the usual
        // install locations for npm, bun, pnpm, Volta, nvm and Homebrew.
        let home = homeDirectory.path
        let fileManager = FileManager.default
        let nvmVersions = homeDirectory.appendingPathComponent(".nvm/versions/node").path
        let nvmBins = ((try? fileManager.contentsOfDirectory(atPath: nvmVersions)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvmVersions)/\($0)/bin" }
        let directories = pathDirectories + [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/Library/pnpm",
            "\(home)/.local/share/pnpm",
            "\(home)/.cargo/bin",
        ] + nvmBins + ["/usr/bin"]
        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("codex")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }
}

public struct CodexUsageProvider: UsageProvider {
    public let id = "codex"
    public let displayName = "Codex"
    public let dashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")

    private let connections: [SubscriptionConnection]
    private let store: SubscriptionConnectionStore
    private let executablePath: String?
    private let environment: [String: String]

    public init(
        connections: [SubscriptionConnection],
        store: SubscriptionConnectionStore,
        executablePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.connections = connections.filter { $0.kind == .codexAppServer }
        self.store = store
        self.executablePath = executablePath
        self.environment = environment
    }

    public func accounts() async throws -> [AccountDescriptor] {
        connections.map { connection in
            AccountDescriptor(
                account: AccountIdentity(
                    providerID: id,
                    id: connection.accountID,
                    label: connection.label),
                source: .configFile)
        }
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let connection = connections.first(where: {
            $0.accountID == account.account.id
        }) else {
            throw ProviderError.notLoggedIn
        }
        let storedExecutable = try store.codexExecutable(for: connection)
        guard let executable = CodexExecutableResolver.resolve(
            preferredPath: storedExecutable?.path ?? executablePath,
            environment: environment) else {
            throw ProviderError.badResponse("Codex CLI was not found")
        }
        let home = try store.codexHome(for: connection)
        let accountRead = try await CodexAppServerClient.readAccount(
            executable: executable,
            codexHome: home)
        var identity = account.account
        identity.plan = accountRead.planType
        return try CodexUsageMapping.snapshot(
            result: accountRead.rateLimits,
            account: identity)
    }
}

public enum CodexAppServerClient {
    public static func readAccount(
        executable: URL,
        codexHome: URL,
        timeout: TimeInterval = 30,
        requestTimeout: TimeInterval = 30
    ) async throws -> CodexAccountRead {
        try await run(
            executable: executable,
            codexHome: codexHome,
            timeout: min(timeout, 30),
            requestTimeout: min(requestTimeout, 30)) { session in
            try session.initialize()
            let account = try session.request(
                method: "account/read",
                params: ["refreshToken": false])
            let accountInfo = try chatGPTAccount(from: account)
            let limits = try session.request(
                method: "account/rateLimits/read",
                params: [:])
            let data = try JSONSerialization.data(withJSONObject: limits, options: [.sortedKeys])
            return CodexAccountRead(planType: accountInfo.planType, rateLimits: data)
        }
    }

    public static func login(
        executable: URL,
        codexHome: URL,
        timeout: TimeInterval = 180,
        requestTimeout: TimeInterval = 30,
        openAuthURL: @escaping @Sendable (URL) -> Void
    ) async throws -> String? {
        try await run(
            executable: executable,
            codexHome: codexHome,
            timeout: min(timeout, 180),
            requestTimeout: min(requestTimeout, 30)) { session in
            try session.initialize()
            let response = try session.request(
                method: "account/login/start",
                params: ["type": "chatgpt"])
            guard let object = response as? [String: Any],
                  let loginID = object["loginId"] as? String,
                  !loginID.isEmpty,
                  let rawURL = object["authUrl"] as? String,
                  let authURL = validatedAuthURL(rawURL) else {
                throw ProviderError.badResponse("Invalid Codex sign-in response")
            }
            session.setLoginID(loginID)
            openAuthURL(authURL)
            guard try session.waitForLoginCompletion(loginID: loginID) else {
                throw ProviderError.badResponse("ChatGPT sign-in was not completed")
            }
            let account = try session.request(
                method: "account/read",
                params: ["refreshToken": false])
            return try chatGPTAccount(from: account).planType
        }
    }

    private static func chatGPTAccount(from result: Any) throws -> (planType: String?, type: String) {
        guard let object = result as? [String: Any],
              let account = object["account"] as? [String: Any],
              let type = account["type"] as? String else {
            throw ProviderError.badResponse("Codex account information is unavailable")
        }
        guard type == "chatgpt" else {
            throw ProviderError.badResponse("Sign in with ChatGPT to use subscription limits")
        }
        return (account["planType"] as? String, type)
    }

    private static func validatedAuthURL(_ value: String) -> URL? {
        guard let components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              host == "auth.openai.com" || host == "chatgpt.com",
              components.user == nil, components.password == nil,
              let url = components.url else {
            return nil
        }
        return url
    }

    private static func run<T: Sendable>(
        executable: URL,
        codexHome: URL,
        timeout: TimeInterval,
        requestTimeout: TimeInterval,
        operation: @escaping @Sendable (CodexAppServerSession) throws -> T
    ) async throws -> T {
        let session = CodexAppServerSession(
            executable: executable,
            codexHome: codexHome,
            timeout: timeout,
            requestTimeout: requestTimeout)
        let cancellation = CodexSessionCancellation()
        return try await withTaskCancellationHandler {
            do {
                return try await Task.detached {
                    cancellation.install(session)
                    defer {
                        session.close()
                        cancellation.clear(session)
                    }
                    try session.start()
                    return try operation(session)
                }.value
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

private final class CodexSessionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var session: CodexAppServerSession?
    private var cancelled = false

    func install(_ session: CodexAppServerSession) {
        lock.lock()
        if cancelled {
            lock.unlock()
            session.cancel()
            return
        }
        self.session = session
        lock.unlock()
    }

    func clear(_ session: CodexAppServerSession) {
        lock.lock()
        if self.session === session { self.session = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let session = self.session
        lock.unlock()
        session?.cancel()
    }
}

private final class CodexAppServerSession: @unchecked Sendable {
    private static let maxBytes = 1_048_576
    private let lock = NSLock()
    private let writeLock = NSLock()
    private let terminationLock = NSLock()
    private let executable: URL
    private let codexHome: URL
    private let deadline: Date
    private let requestTimeout: TimeInterval
    private let process = Process()
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()
    private var inputFD: Int32 = -1
    private var outputFD: Int32 = -1
    private var processStarted = false
    private var closed = false
    private var cancelled = false
    private var closedHandles = Set<ObjectIdentifier>()
    private var loginID: String?
    private var nextID = 1
    private var totalOutput = 0
    private var lineBuffer = Data()
    private var earlyNotifications: [[String: Any]] = []

    init(
        executable: URL,
        codexHome: URL,
        timeout: TimeInterval,
        requestTimeout: TimeInterval
    ) {
        self.executable = executable
        self.codexHome = codexHome
        self.deadline = Date().addingTimeInterval(timeout)
        self.requestTimeout = requestTimeout
    }

    func start() throws {
        if isCancelled { throw CancellationError() }
        signal(SIGPIPE, SIG_IGN)
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "OPENAI_API_KEY")
        environment.removeValue(forKey: "CODEX_API_KEY")
        environment.removeValue(forKey: "OPENAI_BASE_URL")
        environment["CODEX_HOME"] = codexHome.path
        process.executableURL = executable
        process.arguments = ["app-server", "-c", "cli_auth_credentials_store=\"file\""]
        process.currentDirectoryURL = codexHome
        process.environment = environment
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            closePipes()
            throw ProviderError.badResponse("Could not start Codex app-server")
        }
        _ = setpgid(process.processIdentifier, process.processIdentifier)
        closeHandle(inputPipe.fileHandleForReading)
        closeHandle(outputPipe.fileHandleForWriting)
        inputFD = inputPipe.fileHandleForWriting.fileDescriptor
        outputFD = outputPipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(outputFD, F_GETFL)
        if flags >= 0 { _ = fcntl(outputFD, F_SETFL, flags | O_NONBLOCK) }
        lock.lock()
        processStarted = true
        lock.unlock()
        if isCancelled {
            terminate()
            throw CancellationError()
        }
    }

    func initialize() throws {
        _ = try request(
            method: "initialize",
            params: ["clientInfo": [
                "name": "openquota",
                "title": "OpenQuota",
                "version": "0.1.0",
            ]],
            id: 0)
        try send(["jsonrpc": "2.0", "method": "initialized"])
    }

    func request(method: String, params: [String: Any], id: Int? = nil) throws -> Any {
        let requestID: Int
        if let id {
            requestID = id
        } else {
            lock.lock()
            requestID = nextID
            nextID += 1
            lock.unlock()
        }
        let responseDeadline = min(deadline, Date().addingTimeInterval(requestTimeout))
        try send([
            "jsonrpc": "2.0",
            "id": requestID,
            "method": method,
            "params": params,
        ], timeout: requestTimeout)
        while true {
            let message = try readMessage(until: responseDeadline)
            if let method = message["method"] as? String {
                if method == "account/login/completed" {
                    try bufferNotification(message)
                } else if message["id"] != nil {
                    try rejectServerRequest(id: message["id"]!)
                }
                continue
            }
            guard numericID(message["id"]) == requestID else { continue }
            guard message["error"] == nil else {
                throw ProviderError.badResponse("Codex app-server request failed")
            }
            guard let result = message["result"] else {
                throw ProviderError.badResponse("Codex app-server response is incomplete")
            }
            return result
        }
    }

    func setLoginID(_ value: String) {
        lock.lock()
        loginID = value
        lock.unlock()
    }

    func waitForLoginCompletion(loginID: String) throws -> Bool {
        while true {
            if let notification = takeEarlyNotification(loginID: loginID) {
                return completionSuccess(notification)
            }
            let message = try readMessage(until: deadline)
            guard message["method"] as? String == "account/login/completed" else {
                if message["method"] as? String != nil, let id = message["id"] {
                    try rejectServerRequest(id: id)
                }
                continue
            }
            guard let params = message["params"] as? [String: Any],
                  let notifiedID = params["loginId"] as? String else {
                throw ProviderError.badResponse("Invalid Codex sign-in status")
            }
            if notifiedID == loginID { return completionSuccess(message) }
            try bufferNotification(message)
        }
    }

    func cancel() {
        lock.lock()
        guard !cancelled else {
            lock.unlock()
            return
        }
        cancelled = true
        let loginID = self.loginID
        let canSend = processStarted && !closed
        lock.unlock()
        if let loginID, canSend {
            try? send([
                "jsonrpc": "2.0",
                "id": -1,
                "method": "account/login/cancel",
                "params": ["loginId": loginID],
            ], allowCancelled: true, timeout: 0.25)
        }
        terminate()
    }

    func close() {
        lock.lock()
        let shouldTerminate = !closed
        closed = true
        lock.unlock()
        if shouldTerminate { terminate() }
        lock.lock()
        inputFD = -1
        outputFD = -1
        lock.unlock()
        closePipes()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func send(
        _ message: [String: Any],
        allowCancelled: Bool = false,
        timeout: TimeInterval? = nil
    ) throws {
        guard JSONSerialization.isValidJSONObject(message) else {
            throw ProviderError.badResponse("Invalid Codex app-server request")
        }
        var data = try JSONSerialization.data(withJSONObject: message, options: [.sortedKeys])
        guard data.count + 1 <= Self.maxBytes else {
            throw ProviderError.badResponse("Codex app-server request too large")
        }
        data.append(0x0A)
        let end = min(deadline, Date().addingTimeInterval(timeout ?? requestTimeout))
        writeLock.lock()
        defer { writeLock.unlock() }
        if isCancelled && !allowCancelled { throw CancellationError() }
        var offset = 0
        while offset < data.count {
            let remaining = end.timeIntervalSinceNow
            guard remaining > 0 else { throw ProviderError.timedOut }
            var descriptor = pollfd(fd: inputFD, events: Int16(POLLOUT | POLLERR | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, max(1, Int32(min(remaining * 1_000, Double(Int32.max)))))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, descriptor.revents & Int16(POLLOUT) != 0 else {
                throw ProviderError.badResponse("Codex app-server input closed")
            }
            let count = data.withUnsafeBytes { bytes -> Int in
                guard let base = bytes.baseAddress else { return 0 }
                return write(inputFD, base.advanced(by: offset), bytes.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0 && errno == EINTR {
                continue
            } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue
            } else {
                throw ProviderError.badResponse("Codex app-server input failed")
            }
        }
    }

    private func readMessage(until messageDeadline: Date) throws -> [String: Any] {
        while true {
            if isCancelled { throw CancellationError() }
            if let newline = lineBuffer.firstIndex(of: 0x0A) {
                var line = Data(lineBuffer[..<newline])
                lineBuffer.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                guard !line.isEmpty,
                      let value = try? JSONSerialization.jsonObject(with: line),
                      let message = value as? [String: Any] else {
                    throw ProviderError.badResponse("Malformed Codex app-server response")
                }
                return message
            }
            guard lineBuffer.count <= Self.maxBytes else {
                throw ProviderError.badResponse("Codex app-server line too large")
            }
            let remaining = messageDeadline.timeIntervalSinceNow
            guard remaining > 0 else { throw ProviderError.timedOut }
            var descriptor = pollfd(fd: outputFD, events: Int16(POLLIN | POLLERR | POLLHUP), revents: 0)
            let ready = poll(&descriptor, 1, max(1, Int32(min(remaining * 1_000, 100))))
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 { continue }
            guard ready > 0 else { throw ProviderError.badResponse("Codex app-server read failed") }
            var buffer = [UInt8](repeating: 0, count: 32 * 1024)
            let count = buffer.withUnsafeMutableBytes {
                read(outputFD, $0.baseAddress, $0.count)
            }
            if count == 0 { throw ProviderError.badResponse("Codex app-server closed early") }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                throw ProviderError.badResponse("Codex app-server read failed")
            }
            guard totalOutput + count <= Self.maxBytes,
                  lineBuffer.count + count <= Self.maxBytes else {
                throw ProviderError.badResponse("Codex app-server output too large")
            }
            totalOutput += count
            lineBuffer.append(contentsOf: buffer.prefix(count))
        }
    }

    private func bufferNotification(_ message: [String: Any]) throws {
        guard let params = message["params"] as? [String: Any],
              params["loginId"] as? String != nil else {
            throw ProviderError.badResponse("Invalid Codex sign-in status")
        }
        lock.lock()
        defer { lock.unlock() }
        guard earlyNotifications.count < 32 else {
            throw ProviderError.badResponse("Too many Codex app-server notifications")
        }
        earlyNotifications.append(message)
    }

    private func takeEarlyNotification(loginID: String) -> [String: Any]? {
        lock.lock()
        defer { lock.unlock() }
        guard let index = earlyNotifications.firstIndex(where: {
            (($0["params"] as? [String: Any])?["loginId"] as? String) == loginID
        }) else {
            return nil
        }
        return earlyNotifications.remove(at: index)
    }

    private func completionSuccess(_ message: [String: Any]) -> Bool {
        let params = message["params"] as? [String: Any]
        return params?["success"] as? Bool == true
    }

    private func rejectServerRequest(id: Any) throws {
        try send([
            "jsonrpc": "2.0",
            "id": id,
            "error": ["code": -32601, "message": "Unsupported request"],
        ])
    }

    private func terminate() {
        terminationLock.lock()
        defer { terminationLock.unlock() }
        lock.lock()
        guard processStarted else {
            lock.unlock()
            return
        }
        // Claim the process atomically: a second terminate() (cancel plus the
        // deferred close) must not group-kill a pid that may already be
        // reaped and reused.
        processStarted = false
        let process = self.process
        lock.unlock()
        let pid = process.processIdentifier
        if process.isRunning { process.terminate() }
        _ = kill(-pid, SIGKILL)
        if process.isRunning { _ = kill(pid, SIGKILL) }
        reap(pid: pid)
    }

    // NSConcreteTask.waitUntilExit() can spin a runloop forever on macOS when
    // the termination notification is delivered to a blocked thread; reap via
    // waitpid with a hard bound instead. ECHILD means Foundation's monitor
    // already reaped it — any other error stops the wait.
    private func reap(pid: pid_t) {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { return }
            if result == -1 {
                if errno == EINTR { continue }
                return
            }
            usleep(10_000)
        }
    }

    private func closePipes() {
        closeHandle(inputPipe.fileHandleForReading)
        closeHandle(inputPipe.fileHandleForWriting)
        closeHandle(outputPipe.fileHandleForReading)
        closeHandle(outputPipe.fileHandleForWriting)
    }

    private func closeHandle(_ handle: FileHandle) {
        lock.lock()
        let shouldClose = closedHandles.insert(ObjectIdentifier(handle)).inserted
        lock.unlock()
        if shouldClose { handle.closeFile() }
    }

    private func numericID(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        return number.intValue
    }
}
