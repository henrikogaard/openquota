import Foundation

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

    /// Runs the binary with a 10s watchdog; stdout must fit a JSON payload.
    static func run(binary: URL, args: [String]) async throws -> Data {
        final class ResumeGuard: @unchecked Sendable {
            private let lock = NSLock()
            private var resumed = false
            /// Returns true exactly once — the caller resumes the continuation.
            func claim() -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if resumed { return false }
                resumed = true
                return true
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let stdout = Pipe()
            let guard_ = ResumeGuard()
            process.executableURL = binary
            process.arguments = args
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                guard guard_.claim() else { return }
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                if proc.terminationStatus == 0 {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: ProviderError.serverError(
                        Int(proc.terminationStatus)))
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                if process.isRunning, guard_.claim() {
                    process.terminate()
                    continuation.resume(throwing: ProviderError.timedOut)
                }
            }
            do {
                try process.run()
            } catch {
                if guard_.claim() {
                    continuation.resume(throwing: ProviderError.notLoggedIn)
                }
            }
        }
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
