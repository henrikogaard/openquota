import Foundation
import XCTest
@testable import OpenQuotaCore

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class SubscriptionUsageTests: XCTestCase {
    func test_claudeCaptureRoundTripKeepsOnlySanitizedFields() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let input = Data(#"""
            {
              "session_id":"fixture-session",
              "cwd":"/private/project",
              "transcript":"do not keep",
              "rate_limits":{
                "five_hour":{"used_percentage":35.5,"resets_at":1800000000},
                "seven_day":{"used_percentage":72,"resets_at":1800600000}
              }
            }
            """#.utf8)
        let reading = try XCTUnwrap(ClaudeUsageReading.capture(input, now: now))
        let data = try JSONEncoder().encode(reading)
        let roundTrip = try JSONDecoder().decode(ClaudeUsageReading.self, from: data)

        XCTAssertEqual(roundTrip, reading)
        XCTAssertEqual(reading.recordedAt, now)
        XCTAssertEqual(reading.fiveHour?.usedPercentage, 35.5)
        let encoded = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-session"))
        XCTAssertFalse(encoded.contains("private/project"))
        XCTAssertFalse(encoded.contains("transcript"))
    }

    func test_claudeCaptureAllowsPartialWindowsAndNoLimits() throws {
        let partial = try XCTUnwrap(ClaudeUsageReading.capture(Data(
            #"{"rate_limits":{"seven_day":{"used_percentage":40}},"context":"ignored"}"#.utf8)))
        XCTAssertNil(partial.fiveHour)
        XCTAssertEqual(partial.sevenDay?.usedPercentage, 40)
        XCTAssertNil(try ClaudeUsageReading.capture(Data(#"{"rate_limits":{}}"#.utf8)))
        XCTAssertNil(try ClaudeUsageReading.capture(Data(#"{"other":"value"}"#.utf8)))
    }

    func test_claudeCaptureRejectsInvalidPercentAndReset() {
        for input in [
            #"{"rate_limits":{"five_hour":{"used_percentage":101}}}"#,
            #"{"rate_limits":{"five_hour":{"used_percentage":40,"resets_at":-1}}}"#,
        ] {
            XCTAssertThrowsError(try ClaudeUsageReading.capture(Data(input.utf8)))
        }
    }

    func test_claudeProviderKeepsOriginalTimestampAcrossRepeatedPolling() async throws {
        let directory = try makeDirectory()
        let config = try makeDirectory(inside: directory, name: "claude-config")
        let store = SubscriptionConnectionStore(url: directory.appendingPathComponent("connections.json"))
        let connection = try store.addClaude(label: "Work", configurationDirectory: config.path)
        let account = AccountIdentity(providerID: "claude", id: connection.accountID, label: "Work")
        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let reading = ClaudeUsageReading(
            recordedAt: recordedAt,
            fiveHour: .init(usedPercentage: 50, resetsAt: nil),
            sevenDay: nil)
        try JSONEncoder.openQuota.encode(reading).write(to: store.readingURL(for: connection.id))
        let provider = ClaudeStatusLineProvider(connections: [connection], store: store)
        let descriptors = try await provider.accounts()
        let descriptor = try XCTUnwrap(descriptors.first)

        let first = try await provider.refresh(account: descriptor)
        let second = try await provider.refresh(account: descriptor)
        XCTAssertEqual(first.fetchedAt, recordedAt)
        XCTAssertEqual(second.fetchedAt, recordedAt)
        XCTAssertTrue(first.isStale)
        XCTAssertTrue(second.isStale)
        XCTAssertEqual(first.account.id, account.id)
    }

    func test_connectionsHaveIndependentReadingsAndStableIdentity() async throws {
        let directory = try makeDirectory()
        let configA = try makeDirectory(inside: directory, name: "claude-a")
        let configB = try makeDirectory(inside: directory, name: "claude-b")
        let store = SubscriptionConnectionStore(url: directory.appendingPathComponent("connections.json"))
        let first = try store.addClaude(label: "Same label", configurationDirectory: configA.path)
        let second = try store.addClaude(label: "Same label", configurationDirectory: configB.path)
        var renamed = first
        renamed.label = "Renamed"
        XCTAssertNotEqual(first.accountID, second.accountID)
        XCTAssertEqual(first.accountID, renamed.accountID)

        let reading = ClaudeUsageReading(
            recordedAt: Date(timeIntervalSince1970: 1_700_000_000),
            fiveHour: .init(usedPercentage: 25, resetsAt: nil),
            sevenDay: nil)
        try JSONEncoder.openQuota.encode(reading).write(to: store.readingURL(for: first.id))
        let provider = ClaudeStatusLineProvider(connections: [first, second], store: store)
        let accounts = try await provider.accounts()
        XCTAssertEqual(accounts.map(\.account.id), [first.accountID, second.accountID])
        let available = try await provider.refresh(account: accounts[0])
        XCTAssertEqual(available.windows.first?.used, 25)
        do {
            _ = try await provider.refresh(account: accounts[1])
            XCTFail("Missing status-line reading must not be a zero-quota success")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .badResponse("Waiting for Claude Code status line"))
        }
    }

    func test_subscriptionStoreUsesPrivateDirectoriesAndRetainsCodexHomeOnRemoval() throws {
        let directory = try makeDirectory()
        let store = SubscriptionConnectionStore(url: directory.appendingPathComponent("connections.json"))
        let connection = try store.addCodex(label: "Work")
        let home = try store.codexHome(for: connection)
        let parentMode = try FileManager.default.attributesOfItem(atPath: home.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(parentMode?.intValue, 0o700)
        let storeMode = try FileManager.default.attributesOfItem(
            atPath: directory.appendingPathComponent("connections.json").path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(storeMode?.intValue, 0o600)
        let metadata = try String(
            contentsOf: directory.appendingPathComponent("connections.json"),
            encoding: .utf8)
        XCTAssertFalse(metadata.contains("auth.json"))
        XCTAssertFalse(metadata.contains("token"))

        let marker = home.appendingPathComponent("codex-owned-file")
        try Data("owned-by-codex".utf8).write(to: marker)
        try store.remove(id: connection.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertTrue(try store.connections().isEmpty)
    }

    func test_connectionStoreBoundsReadsAndRejectsDuplicateIDs() throws {
        let directory = try makeDirectory()
        let url = directory.appendingPathComponent("connections.json")
        let store = SubscriptionConnectionStore(url: url)
        try Data(repeating: 0x20, count: SubscriptionConnectionStore.maxFileBytes + 1)
            .write(to: url)
        XCTAssertThrowsError(try store.connections()) {
            XCTAssertEqual($0 as? SubscriptionConnectionStoreError, .fileTooLarge)
        }
        try Data("[]".utf8).write(to: url)
        let id = UUID()
        _ = try store.addCodex(id: id, label: "First")
        XCTAssertThrowsError(try store.addCodex(id: id, label: "Duplicate")) {
            XCTAssertEqual($0 as? SubscriptionConnectionStoreError, .duplicateConnectionID)
        }
    }

    func test_oldClaudeAndCodexProfilesRemainReadableWithoutTouchingCredentials() throws {
        let directory = try makeDirectory()
        let claudeSecret = directory.appendingPathComponent("claude-token")
        let codexSecret = directory.appendingPathComponent("codex-token")
        try Data("synthetic-claude-token".utf8).write(to: claudeSecret)
        try Data("synthetic-codex-token".utf8).write(to: codexSecret)
        let oldProfiles = [
            LocalAccountProfile(providerID: "claude", label: "Old Claude", credentialPath: claudeSecret.path),
            LocalAccountProfile(providerID: "codex", label: "Old Codex", credentialPath: codexSecret.path),
        ]
        let profilesURL = directory.appendingPathComponent("profiles.json")
        try JSONEncoder.openQuota.encode(oldProfiles).write(to: profilesURL)
        let beforeClaude = try Data(contentsOf: claudeSecret)
        let beforeCodex = try Data(contentsOf: codexSecret)

        let profiles = try LocalAccountProfileStore(url: profilesURL).profiles()

        XCTAssertEqual(profiles, oldProfiles)
        XCTAssertFalse(LocalAccountProfileStore.supportedProviderIDs.contains("claude"))
        XCTAssertFalse(LocalAccountProfileStore.supportedProviderIDs.contains("codex"))
        XCTAssertEqual(try Data(contentsOf: claudeSecret), beforeClaude)
        XCTAssertEqual(try Data(contentsOf: codexSecret), beforeCodex)
    }

    func test_codexMultiBucketMappingAndCreditsDoNotDoubleCount() throws {
        let json = #"""
            {
              "rateLimitsByLimitId":{
                "codex":{
                  "limitName":"Code",
                  "planType":"plus",
                  "primary":{"usedPercent":20,"windowDurationMins":300,"resetsAt":1800000000},
                  "secondary":{"usedPercent":40,"windowDurationMins":10080},
                  "credits":{"balance":"7.5"}
                },
                "cloud":{
                  "limitName":"Cloud",
                  "primary":{"usedPercent":30,"windowDurationMins":1440},
                  "credits":{"balance":"7.5"}
                }
              }
            }
            """#
        let account = AccountIdentity(providerID: "codex", id: "codex@test", label: "Work")
        let snapshot = try CodexUsageMapping.snapshot(result: Data(json.utf8), account: account)
        XCTAssertEqual(snapshot.account.plan, "plus")
        XCTAssertEqual(snapshot.creditsRemaining, 7.5)
        XCTAssertEqual(snapshot.windows.map(\.label), ["Cloud · 1d", "Code · 5h", "Code · 1w"])
        XCTAssertEqual(snapshot.windows.map(\.used), [30, 20, 40])
    }

    private func makeDirectory(inside parent: URL? = nil, name: String = UUID().uuidString) throws -> URL {
        let directory = (parent ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

final class SubscriptionClaudeStatusLineInstallerTests: XCTestCase {
    func test_installerPreservesSettingsQuotesHelperAndRestoresOriginalStatusLine() throws {
        let root = try makeDirectory()
        let config = try makeDirectory(inside: root, name: "claude config")
        let helperDirectory = try makeDirectory(inside: root, name: "helper's path")
        let helper = helperDirectory.appendingPathComponent("openquota-bridge")
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let original = #"""
            {"statusLine":{"type":"command","command":"printf before","padding":3,"refreshInterval":20},
             "unrelated":{"keep":true}}
            """#
        let settings = config.appendingPathComponent("settings.json")
        try Data(original.utf8).write(to: settings)
        let store = SubscriptionConnectionStore(url: root.appendingPathComponent("connections.json"))
        let installer = ClaudeStatusLineInstaller(store: store)

        let connection = try installer.install(
            label: "Work",
            configurationDirectory: config.path,
            helperExecutable: helper)
        let installed = try readSettings(settings)
        let statusLine = try XCTUnwrap(installed["statusLine"] as? [String: Any])
        let command = try XCTUnwrap(statusLine["command"] as? String)
        XCTAssertTrue(command.contains("helper'\\''s path"))
        XCTAssertEqual(statusLine["padding"] as? Int, 3)
        XCTAssertEqual(statusLine["refreshInterval"] as? Int, 20)
        XCTAssertEqual(installed["unrelated"] as? [String: Bool], ["keep": true])
        XCTAssertEqual(try store.connections(), [connection])

        XCTAssertTrue(try installer.disconnect(connection))
        let restored = try readSettings(settings)
        XCTAssertEqual(restored["unrelated"] as? [String: Bool], ["keep": true])
        let restoredStatus = try XCTUnwrap(restored["statusLine"] as? [String: Any])
        XCTAssertEqual(restoredStatus["command"] as? String, "printf before")
        XCTAssertEqual(restoredStatus["padding"] as? Int, 3)
        XCTAssertEqual(restoredStatus["refreshInterval"] as? Int, 20)
    }

    func test_disconnectPreservesLaterCommandAndUnrelatedUserEdits() throws {
        let root = try makeDirectory()
        let config = try makeDirectory(inside: root, name: "claude")
        let helper = try makeHelper(root)
        let settings = config.appendingPathComponent("settings.json")
        try Data(#"{"statusLine":{"type":"command","command":"echo before"},"keep":1}"#.utf8)
            .write(to: settings)
        let store = SubscriptionConnectionStore(url: root.appendingPathComponent("connections.json"))
        let installer = ClaudeStatusLineInstaller(store: store)
        let connection = try installer.install(
            label: "Work", configurationDirectory: config.path, helperExecutable: helper)
        var edited = try readSettings(settings)
        var statusLine = try XCTUnwrap(edited["statusLine"] as? [String: Any])
        statusLine["command"] = "user edited this"
        statusLine["padding"] = 9
        edited["statusLine"] = statusLine
        edited["newKey"] = "preserve me"
        try writeSettings(edited, to: settings)

        XCTAssertFalse(try installer.disconnect(connection))
        let after = try readSettings(settings)
        XCTAssertEqual((after["statusLine"] as? [String: Any])?["command"] as? String, "user edited this")
        XCTAssertEqual((after["statusLine"] as? [String: Any])?["padding"] as? Int, 9)
        XCTAssertEqual(after["newKey"] as? String, "preserve me")
    }

    func test_disconnectRestoresCommandWithoutOverwritingStatusLineEdits() throws {
        let root = try makeDirectory()
        let config = try makeDirectory(inside: root, name: "claude")
        let helper = try makeHelper(root)
        let settings = config.appendingPathComponent("settings.json")
        try Data(#"{"statusLine":{"type":"command","command":"echo before","padding":3}}"#.utf8)
            .write(to: settings)
        let store = SubscriptionConnectionStore(url: root.appendingPathComponent("connections.json"))
        let installer = ClaudeStatusLineInstaller(store: store)
        let connection = try installer.install(
            label: "Work", configurationDirectory: config.path, helperExecutable: helper)
        var edited = try readSettings(settings)
        var statusLine = try XCTUnwrap(edited["statusLine"] as? [String: Any])
        statusLine["padding"] = 9
        statusLine["userField"] = "keep"
        edited["statusLine"] = statusLine
        try writeSettings(edited, to: settings)

        XCTAssertTrue(try installer.disconnect(connection))
        let restored = try XCTUnwrap(try readSettings(settings)["statusLine"] as? [String: Any])
        XCTAssertEqual(restored["command"] as? String, "echo before")
        XCTAssertEqual(restored["padding"] as? Int, 9)
        XCTAssertEqual(restored["userField"] as? String, "keep")
    }

    func test_duplicateConfigurationAndUnsupportedStatusLineDoNotWrite() throws {
        let root = try makeDirectory()
        let config = try makeDirectory(inside: root, name: "claude")
        let helper = try makeHelper(root)
        let settings = config.appendingPathComponent("settings.json")
        let store = SubscriptionConnectionStore(url: root.appendingPathComponent("connections.json"))
        let installer = ClaudeStatusLineInstaller(store: store)
        let first = try installer.install(
            label: "First", configurationDirectory: config.path, helperExecutable: helper)
        let installedData = try Data(contentsOf: settings)
        XCTAssertThrowsError(try installer.install(
            label: "Duplicate", configurationDirectory: config.path, helperExecutable: helper))
        XCTAssertEqual(try Data(contentsOf: settings), installedData)

        try store.remove(id: first.id)
        try Data(#"{"statusLine":{"type":"unsupported","command":"echo"},"keep":true}"#.utf8)
            .write(to: settings)
        let unsupportedData = try Data(contentsOf: settings)
        XCTAssertThrowsError(try installer.install(
            label: "Other", configurationDirectory: config.path, helperExecutable: helper))
        XCTAssertEqual(try Data(contentsOf: settings), unsupportedData)

        let recursiveSettings = try JSONSerialization.data(withJSONObject: [
            "statusLine": ["type": "command", "command": "\(helper.path) --connection-directory /tmp"],
            "keep": true,
        ], options: [.sortedKeys])
        try recursiveSettings.write(to: settings)
        XCTAssertThrowsError(try installer.install(
            label: "Recursive", configurationDirectory: config.path, helperExecutable: helper))
        XCTAssertEqual(try Data(contentsOf: settings), recursiveSettings)

        let malformed = Data("{ not-json".utf8)
        try malformed.write(to: settings)
        XCTAssertThrowsError(try installer.install(
            label: "Malformed", configurationDirectory: config.path, helperExecutable: helper))
        XCTAssertEqual(try Data(contentsOf: settings), malformed)
        XCTAssertThrowsError(try installer.install(
            label: "Missing", configurationDirectory: root.appendingPathComponent("missing").path,
            helperExecutable: helper))
    }

    private func makeDirectory(inside parent: URL? = nil, name: String = UUID().uuidString) throws -> URL {
        let directory = (parent ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeHelper(_ root: URL) throws -> URL {
        let helper = root.appendingPathComponent("openquota-bridge")
        try Data("#!/bin/sh\n".utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        return helper
    }

    private func readSettings(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    private func writeSettings(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url)
    }
}

final class SubscriptionCodexAppServerTests: XCTestCase {
    func test_appServerHandshakeAccountReadAndGuidedLoginWithEarlyNotification() async throws {
        let directory = try makeDirectory()
        let home = try makeDirectory(inside: directory, name: "codex-home")
        let executable = try makeExecutable(in: directory, name: "codex", script: serverScript())
        let result = try await CodexAppServerClient.readAccount(executable: executable, codexHome: home)
        XCTAssertEqual(result.planType, "plus")
        XCTAssertTrue(String(decoding: result.rateLimits, as: UTF8.self).contains("rateLimits"))
        let observed = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Data(contentsOf: home.appendingPathComponent("observed.json"))) as? [String: Any])
        XCTAssertEqual(observed["cwd"] as? String, home.path)
        XCTAssertEqual(observed["args"] as? [String], [
            "app-server", "-c", #"cli_auth_credentials_store="file""#,
        ])
        XCTAssertEqual(observed["clientInfo"] as? [String: String], [
            "name": "openquota", "title": "OpenQuota", "version": "0.1.0",
        ])
        XCTAssertEqual(observed["hasAPIAuth"] as? Bool, false)

        let opened = LockedURL()
        let plan = try await CodexAppServerClient.login(
            executable: executable,
            codexHome: home,
            openAuthURL: { opened.set($0) })
        XCTAssertEqual(plan, "plus")
        XCTAssertEqual(opened.value?.host, "auth.openai.com")
    }

    func test_appServerRejectsAPIKeyOnlyAccountAndInvalidAuthHost() async throws {
        let directory = try makeDirectory()
        let home = try makeDirectory(inside: directory, name: "codex-home")
        let apiOnly = try makeExecutable(
            in: directory, name: "codex-api", script: serverScript(accountType: "apiKey"))
        do {
            _ = try await CodexAppServerClient.readAccount(executable: apiOnly, codexHome: home)
            XCTFail("API key auth is not a subscription connection")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .badResponse("Sign in with ChatGPT to use subscription limits"))
        }

        let wrongHost = try makeExecutable(
            in: directory, name: "codex-host", script: serverScript(authURL: "https://evil.example/login"))
        do {
            _ = try await CodexAppServerClient.login(
                executable: wrongHost, codexHome: home, openAuthURL: { _ in XCTFail("Must not open URL") })
            XCTFail("Untrusted sign-in host must be rejected")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .badResponse("Invalid Codex sign-in response"))
        }
    }

    func test_codexProviderUsesPersistedNonstandardExecutable() async throws {
        let directory = try makeDirectory()
        let store = SubscriptionConnectionStore(url: directory.appendingPathComponent("connections.json"))
        let connection = try store.addCodex(label: "Work")
        let executable = try makeExecutable(in: directory, name: "custom-codex", script: serverScript())
        try store.setCodexExecutable(executable, for: connection)
        let executableMetadata = try store.appOwnedDirectory(for: connection.id)
            .appendingPathComponent("codex-executable.json")
        let mode = try FileManager.default.attributesOfItem(atPath: executableMetadata.path)[.posixPermissions]
            as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o600)
        let storedConnections = try String(
            contentsOf: directory.appendingPathComponent("connections.json"),
            encoding: .utf8)
        XCTAssertFalse(storedConnections.contains(executable.path))
        let provider = CodexUsageProvider(
            connections: [connection],
            store: store,
            environment: ["PATH": "/no-standard-codex-here"])
        let descriptors = try await provider.accounts()
        let descriptor = try XCTUnwrap(descriptors.first)
        let snapshot = try await provider.refresh(account: descriptor)
        XCTAssertEqual(snapshot.account.plan, "plus")
        XCTAssertEqual(snapshot.windows.first?.used, 20)
    }

    func test_appServerBoundsMalformedOversizedEOFAndRequestTimeout() async throws {
        let directory = try makeDirectory()
        let home = try makeDirectory(inside: directory, name: "codex-home")
        for (name, mode, expected, requestTimeout) in [
            ("codex-malformed", "malformed", "Malformed Codex app-server response", 2.0),
            ("codex-oversized", "oversized", "Codex app-server output too large", 2.0),
            ("codex-eof", "eof", "Codex app-server closed early", 2.0),
            ("codex-timeout", "timeout", "timeout", 0.15),
        ] {
            let executable = try makeExecutable(in: directory, name: name, script: serverScript(mode: mode))
            do {
                _ = try await CodexAppServerClient.readAccount(
                    executable: executable,
                    codexHome: home,
                    timeout: 1,
                    requestTimeout: requestTimeout)
                XCTFail("\(mode) app-server should fail")
            } catch let error as ProviderError {
                if expected == "timeout" {
                    XCTAssertEqual(error, .timedOut)
                } else {
                    XCTAssertEqual(error, .badResponse(expected))
                }
            }
        }
    }

    func test_cancellationKillsAndReapsAppServer() async throws {
        let directory = try makeDirectory()
        let home = try makeDirectory(inside: directory, name: "codex-home")
        let executable = try makeExecutable(
            in: directory, name: "codex-cancel", script: serverScript(mode: "cancel"))
        let task = Task {
            try await CodexAppServerClient.readAccount(
                executable: executable, codexHome: home, timeout: 10, requestTimeout: 5)
        }
        let pidFile = home.appendingPathComponent("server.pid")
        let deadline = Date().addingTimeInterval(2)
        while !FileManager.default.fileExists(atPath: pidFile.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let pid = try XCTUnwrap(Int(String(contentsOf: pidFile, encoding: .utf8)))
        let cancelledAt = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled refresh should throw")
        } catch is CancellationError {
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
        XCTAssertEqual(kill(pid_t(pid), 0), -1)
    }

    private func serverScript(
        accountType: String = "chatgpt",
        authURL: String = "https://auth.openai.com/oauth/authorize",
        mode: String = "normal"
    ) -> String {
        """
        #!/usr/bin/env python3
        import json, os, sys, time
        MODE = "\(mode)"
        TYPE = "\(accountType)"
        AUTH_URL = "\(authURL)"
        def emit(message):
            sys.stdout.write(json.dumps(message) + chr(10))
            sys.stdout.flush()
        for raw in sys.stdin:
            message = json.loads(raw)
            method = message.get("method")
            if method == "initialize":
                with open(os.path.join(os.environ["CODEX_HOME"], "observed.json"), "w") as f:
                    f.write(json.dumps({
                      "cwd":os.getcwd(),
                      "args":sys.argv[1:],
                      "clientInfo":message.get("params",{}).get("clientInfo"),
                      "hasAPIAuth":any(k in os.environ for k in
                        ("OPENAI_API_KEY","CODEX_API_KEY","OPENAI_BASE_URL"))
                    }))
                emit({"jsonrpc":"2.0","id":message["id"],"result":{}})
            elif method == "initialized":
                pass
            elif method == "account/login/start":
                emit({"jsonrpc":"2.0","method":"account/login/completed",
                      "params":{"loginId":"login-1","success":True}})
                emit({"jsonrpc":"2.0","id":message["id"],
                      "result":{"loginId":"login-1","authUrl":AUTH_URL}})
            elif method == "account/read":
                if MODE == "malformed":
                    sys.stdout.write("not-json" + chr(10)); sys.stdout.flush(); break
                if MODE == "oversized":
                    sys.stdout.write("x" * 1048577 + chr(10)); sys.stdout.flush(); break
                if MODE == "eof":
                    break
                if MODE == "timeout":
                    time.sleep(5)
                    break
                if MODE == "cancel":
                    with open(os.path.join(os.environ["CODEX_HOME"], "server.pid"), "w") as f:
                        f.write(str(os.getpid()))
                    time.sleep(60)
                    break
                emit({"jsonrpc":"2.0","id":message["id"],
                      "result":{"account":{"type":TYPE},"planType":"plus"}})
            elif method == "account/rateLimits/read":
                emit({"jsonrpc":"2.0","id":message["id"],
                      "result":{"rateLimits":{"limitId":"codex","primary":
                        {"usedPercent":20,"windowDurationMins":300}}}})
        """
    }

    private func makeDirectory(inside parent: URL? = nil, name: String = UUID().uuidString) throws -> URL {
        let directory = (parent ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func makeExecutable(in directory: URL, name: String, script: String) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }
}

private final class LockedURL: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL?
    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
    func set(_ url: URL) {
        lock.lock()
        stored = url
        lock.unlock()
    }
}
