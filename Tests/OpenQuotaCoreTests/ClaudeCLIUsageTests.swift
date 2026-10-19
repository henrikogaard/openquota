import Foundation
import XCTest
@testable import OpenQuotaCore

final class ClaudeCLIUsageTests: XCTestCase {
    func test_parseReadsLastRateLimitEvent() throws {
        let output = Data("""
        {"type":"system","subtype":"init","session_id":"fixture-session"}
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.01,"resetsAt":1792444800}}}}
        not json
        {"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.04,"resetsAt":1792444800},"seven_day":{"utilization":1.2,"resetsAt":1792605600}}}}
        {"type":"result","subtype":"success","is_error":false}
        """.utf8)
        let now = Date(timeIntervalSince1970: 1_792_400_000)
        let reading = try ClaudeCLIUsageCheck.parse(output, now: now)
        XCTAssertEqual(reading.recordedAt, now)
        XCTAssertEqual(try XCTUnwrap(reading.fiveHour?.usedPercentage), 4, accuracy: 0.0001)
        XCTAssertEqual(reading.fiveHour?.resetsAt, 1_792_444_800)
        XCTAssertEqual(reading.sevenDay?.usedPercentage, 100)
    }

    func test_parseWithoutLimitsFails() {
        let failed = Data(#"{"type":"result","is_error":true,"result":"Not logged in"}"#.utf8)
        XCTAssertThrowsError(try ClaudeCLIUsageCheck.parse(failed)) {
            XCTAssertEqual($0 as? ProviderError, .unauthorized)
        }
        let apiKey = Data(#"{"type":"result","is_error":false}"#.utf8)
        XCTAssertThrowsError(try ClaudeCLIUsageCheck.parse(apiKey))
    }

    func test_launchEnvironmentDropsOverridesAndSetsConfigOnlyForNonDefaultFolder() throws {
        let home = URL(fileURLWithPath: "/Users/fixture")
        let executable = URL(fileURLWithPath: "/opt/claude/bin/claude")
        let inherited = [
            "PATH": "/usr/bin", "HOME": "/Users/fixture",
            "ANTHROPIC_API_KEY": "fixture-key", "ANTHROPIC_BASE_URL": "https://example.com",
            "CLAUDE_CONFIG_DIR": "/elsewhere", "CLAUDECODE": "1", "CLAUDE_CODE_ENTRYPOINT": "claude-desktop",
        ]
        let defaultEnv = ClaudeCLIUsageCheck.launchEnvironment(
            executable: executable, configDirectory: "/Users/fixture/.claude",
            environment: inherited, homeDirectory: home)
        XCTAssertNil(defaultEnv["CLAUDE_CONFIG_DIR"])
        XCTAssertFalse(defaultEnv.keys.contains { $0.hasPrefix("CLAUDE") || $0.hasPrefix("ANTHROPIC_") })
        XCTAssertEqual(defaultEnv["HOME"], "/Users/fixture")
        XCTAssertTrue(try XCTUnwrap(defaultEnv["PATH"]).hasPrefix("/opt/claude/bin:"))

        let work = ClaudeCLIUsageCheck.launchEnvironment(
            executable: executable, configDirectory: "/Users/fixture/.claude-work",
            environment: inherited, homeDirectory: home)
        XCTAssertEqual(work["CLAUDE_CONFIG_DIR"], "/Users/fixture/.claude-work")
    }

    func test_checkRunsAtMostEvery30MinutesUnlessRefreshPressed() async throws {
        let directory = try makeDirectory()
        let config = directory.appendingPathComponent("claude-config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let store = SubscriptionConnectionStore(url: directory.appendingPathComponent("connections.json"))
        let added = try store.addClaude(label: "Work", configurationDirectory: config.path)
        try store.setCLIUsageCheck(true, for: added.id)
        let connection = try XCTUnwrap(try store.connections().first)
        XCTAssertEqual(connection.cliUsageCheck, true)

        let counter = CheckCounter()
        let requests = ClaudeCLIRefreshRequests()
        let provider = ClaudeStatusLineProvider(
            connections: [connection], store: store, refreshRequests: requests,
            cliCheck: { configDirectory, workingDirectory in
                XCTAssertEqual(configDirectory, connection.directory)
                XCTAssertEqual(workingDirectory, try store.appOwnedDirectory(for: connection.id))
                let used = Double(counter.increment() * 10)
                return ClaudeUsageReading(
                    recordedAt: Date(), fiveHour: .init(usedPercentage: used, resetsAt: nil), sevenDay: nil)
            })
        let accounts = try await provider.accounts()
        let account = try XCTUnwrap(accounts.first)

        let first = try await provider.refresh(account: account)
        XCTAssertEqual(first.windows.first?.used, 10)
        XCTAssertFalse(first.isStale)
        let second = try await provider.refresh(account: account)
        XCTAssertEqual(counter.value, 1, "A fresh check is reused")
        XCTAssertEqual(second.windows.first?.used, 10)

        // A Refresh press within a minute of the last check reuses it too.
        requests.request()
        _ = try await provider.refresh(account: account)
        XCTAssertEqual(counter.value, 1)

        // Once the last check is past the manual floor, that press runs one.
        let checkURL = try store.cliReadingURL(for: connection.id)
        let aged = ClaudeUsageReading(
            recordedAt: Date().addingTimeInterval(-120),
            fiveHour: .init(usedPercentage: 10, resetsAt: nil), sevenDay: nil)
        try JSONEncoder.openQuota.encode(aged).write(to: checkURL)
        let pressed = try await provider.refresh(account: account)
        XCTAssertEqual(counter.value, 2)
        XCTAssertEqual(pressed.windows.first?.used, 20)
        _ = try await provider.refresh(account: account)
        XCTAssertEqual(counter.value, 2, "A press is used once")

        // Past 30 minutes a check runs without a press.
        let old = ClaudeUsageReading(
            recordedAt: Date().addingTimeInterval(-ClaudeCLIUsageCheck.minimumInterval - 1),
            fiveHour: .init(usedPercentage: 10, resetsAt: nil), sevenDay: nil)
        try JSONEncoder.openQuota.encode(old).write(to: checkURL)
        _ = try await provider.refresh(account: account)
        XCTAssertEqual(counter.value, 3)
    }

    func test_newerStatusLineReadingSkipsCheckAndDisabledNeverChecks() async throws {
        let directory = try makeDirectory()
        let config = directory.appendingPathComponent("claude-config")
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let store = SubscriptionConnectionStore(url: directory.appendingPathComponent("connections.json"))
        let added = try store.addClaude(label: "Work", configurationDirectory: config.path)
        try JSONEncoder.openQuota.encode(ClaudeUsageReading(
            recordedAt: Date(), fiveHour: .init(usedPercentage: 42, resetsAt: nil), sevenDay: nil))
            .write(to: store.readingURL(for: added.id))
        let counter = CheckCounter()
        let check: ClaudeStatusLineProvider.CLICheck = { _, _ in
            _ = counter.increment()
            throw ProviderError.timedOut
        }

        let disabled = ClaudeStatusLineProvider(connections: [added], store: store, cliCheck: check)
        let disabledAccounts = try await disabled.accounts()
        let plain = try await disabled.refresh(account: XCTUnwrap(disabledAccounts.first))
        XCTAssertEqual(plain.windows.first?.used, 42)

        try store.setCLIUsageCheck(true, for: added.id)
        let enabled = ClaudeStatusLineProvider(
            connections: try store.connections(), store: store, cliCheck: check)
        let enabledAccounts = try await enabled.accounts()
        let viaStatusLine = try await enabled.refresh(account: XCTUnwrap(enabledAccounts.first))
        XCTAssertEqual(viaStatusLine.windows.first?.used, 42)
        XCTAssertEqual(counter.value, 0)

        try store.setCLIUsageCheck(false, for: added.id)
        XCTAssertNil(try store.connections().first?.cliUsageCheck)
    }

    func test_connectionsWithoutFlagStillDecode() throws {
        let json = #"[{"label":"Claude","directory":"/tmp","id":"A268A6D6-B5D3-4785-B601-5F3FB87B72EC","kind":"claudeStatusLine"}]"#
        let values = try JSONDecoder.openQuota.decode([SubscriptionConnection].self, from: Data(json.utf8))
        XCTAssertNil(values.first?.cliUsageCheck)
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openquota-cli-\(UUID().uuidString)")
            .standardizedFileURL.resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

private final class CheckCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class ClaudeProfileStatusTests: XCTestCase {
    func test_statusFollowsFolderAndOauthAccount() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("openquota-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }

        XCTAssertEqual(ClaudeProfileStatus.check(configDirectory: "~/.claude-work", homeDirectory: home), .folderMissing)
        let work = home.appendingPathComponent(".claude-work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        XCTAssertEqual(ClaudeProfileStatus.check(configDirectory: "~/.claude-work", homeDirectory: home), .signedOut)
        try Data(#"{"oauthAccount":{"emailAddress":"work@example.com","accountUuid":"x"}}"#.utf8)
            .write(to: work.appendingPathComponent(".claude.json"))
        XCTAssertEqual(ClaudeProfileStatus.check(configDirectory: work.path, homeDirectory: home),
                       .signedIn(email: "work@example.com"))

        // The default folder reads ~/.claude.json, not ~/.claude/.claude.json.
        let main = home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        try Data(#"{"oauthAccount":{"emailAddress":"wrong@example.com"}}"#.utf8)
            .write(to: main.appendingPathComponent(".claude.json"))
        XCTAssertEqual(ClaudeProfileStatus.check(configDirectory: "~/.claude", homeDirectory: home), .signedOut)
        try Data(#"{"oauthAccount":{"emailAddress":"me@example.com"}}"#.utf8)
            .write(to: home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(ClaudeProfileStatus.check(configDirectory: "~/.claude", homeDirectory: home),
                       .signedIn(email: "me@example.com"))
    }

    func test_signInCommand() {
        let home = URL(fileURLWithPath: "/Users/fixture")
        XCTAssertEqual(ClaudeProfileStatus.signInCommand(configDirectory: "~/.claude", homeDirectory: home), "claude")
        XCTAssertEqual(ClaudeProfileStatus.signInCommand(configDirectory: "/Users/fixture/.claude/", homeDirectory: home), "claude")
        XCTAssertEqual(ClaudeProfileStatus.signInCommand(configDirectory: "~/.claude-work", homeDirectory: home),
                       #"CLAUDE_CONFIG_DIR="$HOME/.claude-work" claude"#)
        XCTAssertEqual(ClaudeProfileStatus.signInCommand(configDirectory: "/Volumes/it's here", homeDirectory: home),
                       #"CLAUDE_CONFIG_DIR='/Volumes/it'\''s here' claude"#)
    }
}
