import Foundation

/// Opt-in active check for a Claude connection. Runs the user's own Claude
/// Code CLI once in print mode against that connection's config folder and
/// reads the `rate_limit_event` it streams back. OpenQuota never sees a
/// token: the CLI signs in as usual. Each check is one tiny request (one
/// word from the smallest model) and counts against the subscription, so
/// checks run at most every 30 minutes, or when the user presses Refresh.
public enum ClaudeCLIUsageCheck {
    public static let minimumInterval: TimeInterval = 30 * 60
    /// Refresh presses closer together than this reuse the last check.
    public static let manualFloor: TimeInterval = 60
    /// Readings stay current until the next scheduled check is overdue.
    public static let staleAfter: TimeInterval = minimumInterval + 5 * 60
    static let timeout: TimeInterval = 45

    /// No tools, MCP servers, slash commands, user hooks or saved session.
    static let arguments = [
        "-p", "Reply with only: ok",
        "--model", "haiku",
        "--output-format", "stream-json", "--verbose",
        "--max-turns", "1",
        "--tools", "",
        "--strict-mcp-config",
        "--disable-slash-commands",
        "--setting-sources", "project",
        "--no-session-persistence",
    ]

    public static func run(
        configDirectory: String,
        workingDirectory: URL,
        executablePath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) async throws -> ClaudeUsageReading {
        guard let executable = resolveExecutable(
            preferredPath: executablePath, environment: environment, homeDirectory: homeDirectory) else {
            throw ProviderError.badResponse(Localized.text("Claude Code CLI was not found", "Fant ikke Claude Code CLI"))
        }
        let output: Data
        do {
            output = try await CLIProvider.run(
                binary: executable,
                args: arguments,
                environment: launchEnvironment(
                    executable: executable, configDirectory: configDirectory,
                    environment: environment, homeDirectory: homeDirectory),
                currentDirectory: workingDirectory,
                timeout: timeout)
        } catch ProviderError.serverError {
            // A failed run is almost always a missing or expired login.
            throw ProviderError.badResponse(Localized.text(
                "Claude CLI check failed. Sign in by running claude with this folder.",
                "Claude CLI-sjekken feilet. Logg inn ved å kjøre claude med denne mappen."))
        }
        return try parse(output)
    }

    static func resolveExecutable(
        preferredPath: String?, environment: [String: String], homeDirectory: URL
    ) -> URL? {
        if let preferredPath {
            guard preferredPath.hasPrefix("/"),
                  FileManager.default.isExecutableFile(atPath: preferredPath) else { return nil }
            return URL(fileURLWithPath: preferredPath).standardizedFileURL
        }
        let directories = CodexExecutableResolver.searchDirectories(
            environment: environment, homeDirectory: homeDirectory)
            + [homeDirectory.appendingPathComponent(".claude/local").path]
        for directory in directories {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("claude")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }

    /// Drops every Claude/Anthropic override so the CLI uses the
    /// subscription login stored for `configDirectory`. The default folder
    /// must run without CLAUDE_CONFIG_DIR: setting it, even to ~/.claude,
    /// makes the CLI look for a different Keychain item.
    static func launchEnvironment(
        executable: URL,
        configDirectory: String,
        environment: [String: String],
        homeDirectory: URL
    ) -> [String: String] {
        var result = environment.filter {
            !$0.key.hasPrefix("CLAUDE") && !$0.key.hasPrefix("ANTHROPIC_")
        }
        let directories = [executable.deletingLastPathComponent().path]
            + CodexExecutableResolver.searchDirectories(environment: environment, homeDirectory: homeDirectory)
        var seen = Set<String>()
        result["PATH"] = directories.filter { seen.insert($0).inserted }.joined(separator: ":")
        let defaultDirectory = homeDirectory.appendingPathComponent(".claude")
            .standardizedFileURL.resolvingSymlinksInPath().path
        let directory = URL(fileURLWithPath: configDirectory).standardizedFileURL.path
        if directory != defaultDirectory {
            result["CLAUDE_CONFIG_DIR"] = directory
        }
        return result
    }

    /// Reads the last `rate_limit_event` from the CLI's stream-json output.
    static func parse(_ output: Data, now: Date = Date()) throws -> ClaudeUsageReading {
        struct Line: Decodable {
            struct Info: Decodable {
                struct Window: Decodable {
                    let utilization: Double?
                    let resetsAt: Double?
                }
                let unifiedWindows: [String: Window]?
            }
            let type: String?
            let rate_limit_info: Info?
            let is_error: Bool?
        }
        var windows: [String: Line.Info.Window]?
        var failed = false
        for raw in output.split(separator: UInt8(ascii: "\n")) {
            guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw)) else { continue }
            if line.type == "rate_limit_event", let unified = line.rate_limit_info?.unifiedWindows {
                windows = unified
            } else if line.type == "result", line.is_error == true {
                failed = true
            }
        }
        func window(_ key: String) -> ClaudeUsageReading.Window? {
            guard let value = windows?[key], let utilization = value.utilization,
                  utilization.isFinite else { return nil }
            return .init(usedPercentage: min(max(utilization, 0), 1) * 100, resetsAt: value.resetsAt)
        }
        let reading = ClaudeUsageReading(
            recordedAt: now, fiveHour: window("five_hour"), sevenDay: window("seven_day"))
        guard reading.fiveHour != nil || reading.sevenDay != nil else {
            if failed { throw ProviderError.unauthorized }
            throw ProviderError.badResponse(Localized.text(
                "Claude CLI reported no subscription limits", "Claude CLI rapporterte ingen abonnementsgrenser"))
        }
        return reading
    }
}

/// Records Refresh presses so the next Claude check may run before its
/// 30-minute interval. Shared between the app and the provider.
public final class ClaudeCLIRefreshRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedAt: Date?

    public init() {}

    public func request(now: Date = Date()) {
        lock.lock()
        requestedAt = now
        lock.unlock()
    }

    public var latest: Date? {
        lock.lock()
        defer { lock.unlock() }
        return requestedAt
    }
}

/// What the setup wizard can see about a Claude config folder without
/// touching a token: whether it exists, and which account Claude Code says
/// is signed in there, from Claude Code's own `.claude.json`.
public enum ClaudeProfileStatus: Equatable, Sendable {
    case folderMissing
    case signedOut
    case signedIn(email: String?)

    public static func check(
        configDirectory: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        let directory = expanded(configDirectory, homeDirectory: homeDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory),
              isDirectory.boolValue else { return .folderMissing }
        // The default folder keeps its config beside it, in ~/.claude.json.
        let configFile = isDefault(directory, homeDirectory: homeDirectory)
            ? homeDirectory.appendingPathComponent(".claude.json")
            : URL(fileURLWithPath: directory).appendingPathComponent(".claude.json")
        guard let handle = try? FileHandle(forReadingFrom: configFile) else { return .signedOut }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16 * 1_048_576),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any] else { return .signedOut }
        return .signedIn(email: account["emailAddress"] as? String)
    }

    public static func isDefault(
        _ configDirectory: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = URL(fileURLWithPath: expanded(configDirectory, homeDirectory: homeDirectory))
            .standardizedFileURL.path
        return path == homeDirectory.appendingPathComponent(".claude").standardizedFileURL.path
    }

    /// The Terminal command that signs in to `configDirectory`.
    public static func signInCommand(
        configDirectory: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        if isDefault(configDirectory, homeDirectory: homeDirectory) { return "claude" }
        let path = URL(fileURLWithPath: expanded(configDirectory, homeDirectory: homeDirectory))
            .standardizedFileURL.path
        let home = homeDirectory.standardizedFileURL.path + "/"
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        if path.hasPrefix(home), path.unicodeScalars.allSatisfy(safe.contains) {
            return "CLAUDE_CONFIG_DIR=\"$HOME/\(path.dropFirst(home.count))\" claude"
        }
        let quoted = "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "CLAUDE_CONFIG_DIR=\(quoted) claude"
    }

    static func expanded(_ path: String, homeDirectory: URL) -> String {
        if path == "~" { return homeDirectory.path }
        if path.hasPrefix("~/") { return homeDirectory.appendingPathComponent(String(path.dropFirst(2))).path }
        return path
    }
}
