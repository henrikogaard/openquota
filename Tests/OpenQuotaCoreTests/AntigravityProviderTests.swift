import Foundation
import XCTest
@testable import OpenQuotaCore

final class AntigravityStatusLineTests: XCTestCase {
    func test_captureRoundTripKeepsOnlySanitizedQuotaAndAccountFields() throws {
        let now = Date(timeIntervalSince1970: 1_783_324_232)
        let input = Data(#"""
            {
              "cwd": "/private/secret-project",
              "session_id": "12345678-abcd-ef01-2345-6789abcdef01",
              "conversation_id": "12345678-abcd-ef01-2345-6789abcdef01",
              "conversation_title": "Top secret task",
              "transcript_path": "/Users/test/.gemini/antigravity/brain/secret/transcript.jsonl",
              "workspace": {"current_dir": "/private/secret-project", "project_dir": "/private/secret-project"},
              "model": {"id": "Gemini 4 Argon (Medium)", "display_name": "Gemini 4 Argon (Medium)", "effort": "medium"},
              "product": "antigravity",
              "plan_tier": "Pro",
              "email": "developer@example.com",
              "cost": {"total_usd": 0.4213, "subagent_usd": 0, "estimated": false},
              "quota": {
                "gemini-weekly": {
                  "remaining_fraction": 0.9378,
                  "reset_time": "2026-07-06T07:50:32Z",
                  "reset_in_seconds": 560580
                },
                "claude-gpt-5h": {
                  "remaining_fraction": 0.25,
                  "reset_in_seconds": 3600
                },
                "ai-credits": {
                  "remaining_amount": 42
                },
                "disabled-bucket": {
                  "remaining_fraction": 0.1,
                  "disabled": true
                }
              }
            }
            """#.utf8)

        let reading = try XCTUnwrap(AntigravityUsageReading.capture(input, now: now))
        let encodedData = try JSONEncoder.openQuota.encode(reading)
        let roundTrip = try JSONDecoder.openQuota.decode(AntigravityUsageReading.self, from: encodedData)
        XCTAssertEqual(roundTrip, reading)
        XCTAssertEqual(reading.recordedAt, now)
        XCTAssertEqual(reading.planTier, "Pro")
        XCTAssertEqual(reading.email, "developer@example.com")
        XCTAssertEqual(reading.buckets.map(\.id), ["ai-credits", "claude-gpt-5h", "gemini-weekly"])

        let encoded = String(decoding: encodedData, as: UTF8.self)
        for forbidden in ["secret-project", "12345678-abcd", "Top secret task", "transcript.jsonl", "0.4213", "disabled-bucket"] {
            XCTAssertFalse(encoded.contains(forbidden), "Must not persist \(forbidden)")
        }

        let account = AccountIdentity(providerID: "antigravity", id: "antigravity@test", label: "Antigravity")
        let snapshot = try reading.snapshot(account: account, now: now.addingTimeInterval(60))
        XCTAssertFalse(snapshot.isStale)
        XCTAssertEqual(snapshot.account.plan, "Pro")
        XCTAssertEqual(snapshot.account.email, "developer@example.com")
        XCTAssertEqual(snapshot.windows.map(\.label), ["AI Credits", "Claude GPT · 5h", "Gemini · Week"])
        XCTAssertEqual(snapshot.windows[0].kind, .credits)
        XCTAssertEqual(snapshot.windows[0].remaining, 42)
        XCTAssertNil(snapshot.windows[0].percentRemaining)
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[1].used), 75, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[1].resetsAt, now.addingTimeInterval(3600))
        XCTAssertEqual(try XCTUnwrap(snapshot.windows[2].used), 6.22, accuracy: 0.001)
        XCTAssertEqual(snapshot.windows[2].resetsAt, ISO8601DateFormatter().date(from: "2026-07-06T07:50:32Z"))
    }

    func test_captureHandlesOmittedZeroFractionAndEmptyQuota() throws {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let exhausted = try XCTUnwrap(AntigravityUsageReading.capture(Data(#"""
            {"quota":{"gemini-5h":{"reset_time":"2026-11-26T12:00:00.500Z"}}}
            """#.utf8), now: now))
        XCTAssertEqual(exhausted.buckets.count, 1)
        XCTAssertEqual(exhausted.buckets[0].remainingFraction, 0)
        XCTAssertNotNil(exhausted.buckets[0].resetsAt)

        let account = AccountIdentity(providerID: "antigravity", id: "antigravity@test", label: "Antigravity")
        let snapshot = try exhausted.snapshot(account: account, now: now)
        XCTAssertEqual(snapshot.windows[0].used, 100)

        XCTAssertNil(try AntigravityUsageReading.capture(Data(#"{"quota":{}}"#.utf8), now: now))
        XCTAssertNil(try AntigravityUsageReading.capture(Data(#"{"product":"antigravity"}"#.utf8), now: now))
        XCTAssertNil(try AntigravityUsageReading.capture(Data(#"{"quota":{"x":{"disabled":true,"remaining_fraction":0.5}}}"#.utf8), now: now))
    }

    func test_captureRejectsInvalidValuesAndFutureTimestamps() {
        for invalid in [
            #"{"quota":{"g":{"remaining_fraction":1.5}}}"#,
            #"{"quota":{"g":{"remaining_fraction":-0.1}}}"#,
            #"{"quota":{"g":{"remaining_amount":-5}}}"#,
            #"{"quota":{"g":{"remaining_fraction":0.5,"reset_in_seconds":-1}}}"#,
        ] {
            XCTAssertThrowsError(try AntigravityUsageReading.capture(Data(invalid.utf8)), invalid)
        }

        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let future = AntigravityUsageReading(
            recordedAt: now.addingTimeInterval(120),
            buckets: [.init(id: "gemini-weekly", remainingFraction: 0.5)])
        let account = AccountIdentity(providerID: "antigravity", id: "antigravity@test", label: "Antigravity")
        XCTAssertThrowsError(try future.snapshot(account: account, now: now))
    }

    func test_displayLabelsFormatDocumentedBucketIDs() {
        XCTAssertEqual(AntigravityUsageReading.displayLabel(for: "gemini-weekly"), "Gemini · Week")
        XCTAssertEqual(AntigravityUsageReading.displayLabel(for: "gemini-5h"), "Gemini · 5h")
        XCTAssertEqual(AntigravityUsageReading.displayLabel(for: "claude-gpt-weekly"), "Claude GPT · Week")
        XCTAssertEqual(AntigravityUsageReading.displayLabel(for: "ai-credits"), "AI Credits")
        XCTAssertEqual(AntigravityUsageReading.displayLabel(for: "weekly"), "Week")
        XCTAssertEqual(AntigravityUsageReading.displayLabel(for: "5h"), "5h")
    }

    func test_providerReadsStoredReadingAndAwaitsFirstCapture() async throws {
        let directory = try makeDirectory()
        let configA = try makeDirectory(inside: directory, name: "agy-a")
        let configB = try makeDirectory(inside: directory, name: "agy-b")
        let store = SubscriptionConnectionStore(url: directory.appendingPathComponent("connections.json"))
        let first = try store.addAntigravity(label: "Personal", configurationDirectory: configA.path)
        let second = try store.addAntigravity(label: "Work", configurationDirectory: configB.path)

        let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let reading = AntigravityUsageReading(
            recordedAt: recordedAt,
            planTier: "Ultra",
            email: "user@example.com",
            buckets: [.init(id: "gemini-weekly", remainingFraction: 0.8)])
        try JSONEncoder.openQuota.encode(reading).write(to: store.readingURL(for: first.id))

        let provider = AntigravityStatusLineProvider(connections: [first, second], store: store)
        let accounts = try await provider.accounts()
        XCTAssertEqual(accounts.map(\.account.id), [first.accountID, second.accountID])

        let snapshot = try await provider.refresh(account: accounts[0])
        XCTAssertEqual(snapshot.fetchedAt, recordedAt)
        XCTAssertTrue(snapshot.isStale)
        XCTAssertEqual(snapshot.account.plan, "Ultra")
        XCTAssertEqual(snapshot.account.email, "user@example.com")
        XCTAssertEqual(try XCTUnwrap(snapshot.windows.first?.used), 20, accuracy: 0.001)

        do {
            _ = try await provider.refresh(account: accounts[1])
            XCTFail("Missing reading must await first capture")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .awaitingReading)
        }
    }

    func test_installerCreatesDefaultSettingsAndRemovesStatusLineCleanlyOnDisconnect() throws {
        let root = try makeDirectory()
        let config = root.appendingPathComponent(".gemini/antigravity-cli")
        let helper = try makeHelper(root)
        let store = SubscriptionConnectionStore(url: root.appendingPathComponent("connections.json"))
        let installer = AntigravityStatusLineInstaller(store: store)

        XCTAssertThrowsError(try installer.install(
            label: "Antigravity", configurationDirectory: config.path, helperExecutable: helper)) {
            XCTAssertEqual($0 as? AntigravityStatusLineInstallError, .configurationDirectoryNotFound)
        }

        let connection = try installer.install(
            label: "Antigravity",
            configurationDirectory: config.path,
            helperExecutable: helper,
            createDirectoryIfMissing: true)
        let settingsURL = config.appendingPathComponent("settings.json")
        let installed = try readSettings(settingsURL)
        let statusLine = try XCTUnwrap(installed["statusLine"] as? [String: Any])
        XCTAssertEqual(statusLine["type"] as? String, "command")
        XCTAssertEqual(statusLine["stack_with_default"] as? Bool, true)
        let command = try XCTUnwrap(statusLine["command"] as? String)
        XCTAssertTrue(command.contains("--provider antigravity"))
        XCTAssertTrue(command.contains("--connection-directory"))

        XCTAssertTrue(try installer.disconnect(connection))
        let after = try readSettings(settingsURL)
        XCTAssertNil(after["statusLine"])
    }

    func test_installerPreservesExistingStatusLineAndRestoresItOnDisconnect() throws {
        let root = try makeDirectory()
        let config = try makeDirectory(inside: root, name: "antigravity cli")
        let helperDirectory = try makeDirectory(inside: root, name: "helper's dir")
        let helper = try makeHelper(helperDirectory)
        let settingsURL = config.appendingPathComponent("settings.json")
        let original = #"""
            {
              "statusLine": {
                "type": "command",
                "command": "~/.gemini/antigravity-cli/statusline.sh",
                "padding": 2,
                "enabled": false
              },
              "useG1Credits": true
            }
            """#
        try Data(original.utf8).write(to: settingsURL)

        let store = SubscriptionConnectionStore(url: root.appendingPathComponent("connections.json"))
        let installer = AntigravityStatusLineInstaller(store: store)
        let connection = try installer.install(
            label: "Pro", configurationDirectory: config.path, helperExecutable: helper)

        let installed = try readSettings(settingsURL)
        XCTAssertEqual(installed["useG1Credits"] as? Bool, true)
        let statusLine = try XCTUnwrap(installed["statusLine"] as? [String: Any])
        XCTAssertTrue((statusLine["command"] as? String)?.contains("helper'\\''s dir") == true)
        XCTAssertEqual(statusLine["padding"] as? Int, 2)
        XCTAssertEqual(statusLine["enabled"] as? Bool, true)
        XCTAssertNil(statusLine["stack_with_default"])

        XCTAssertTrue(try installer.disconnect(connection))
        let restored = try readSettings(settingsURL)
        XCTAssertEqual(restored["useG1Credits"] as? Bool, true)
        let restoredStatus = try XCTUnwrap(restored["statusLine"] as? [String: Any])
        XCTAssertEqual(restoredStatus["command"] as? String, "~/.gemini/antigravity-cli/statusline.sh")
        XCTAssertEqual(restoredStatus["padding"] as? Int, 2)
        XCTAssertEqual(restoredStatus["enabled"] as? Bool, false)
    }

    func test_disconnectKeepsLaterUserCommandAndRejectsUnsupportedOrMalformedSettings() throws {
        let root = try makeDirectory()
        let config = try makeDirectory(inside: root, name: "agy")
        let helper = try makeHelper(root)
        let settingsURL = config.appendingPathComponent("settings.json")
        try Data(#"{"statusLine":{"command":"echo old"},"showTips":false}"#.utf8).write(to: settingsURL)

        let store = SubscriptionConnectionStore(url: root.appendingPathComponent("connections.json"))
        let installer = AntigravityStatusLineInstaller(store: store)
        let connection = try installer.install(
            label: "Main", configurationDirectory: config.path, helperExecutable: helper)

        var edited = try readSettings(settingsURL)
        var statusLine = try XCTUnwrap(edited["statusLine"] as? [String: Any])
        statusLine["command"] = "echo custom"
        edited["statusLine"] = statusLine
        try JSONSerialization.data(withJSONObject: edited, options: [.sortedKeys]).write(to: settingsURL)

        XCTAssertFalse(try installer.disconnect(connection))
        let kept = try XCTUnwrap(try readSettings(settingsURL)["statusLine"] as? [String: Any])
        XCTAssertEqual(kept["command"] as? String, "echo custom")

        try store.remove(id: connection.id)
        for bad in [
            #"{"statusLine":false}"#,
            #"{"statusLine":{"type":"unsupported","command":"echo"}}"#,
            #"{ not-json"#,
        ] {
            let badData = Data(bad.utf8)
            try badData.write(to: settingsURL)
            XCTAssertThrowsError(try installer.install(
                label: "Bad", configurationDirectory: config.path, helperExecutable: helper))
            XCTAssertEqual(try Data(contentsOf: settingsURL), badData)
        }
    }

    func test_cliStatusDetectsAgyBinaryAndConfigFolder() throws {
        let home = try makeDirectory()
        let bin = try makeDirectory(inside: home, name: ".local/bin")
        let agy = bin.appendingPathComponent("agy")
        try Data("#!/bin/sh\n".utf8).write(to: agy)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agy.path)

        let before = AntigravityCLIStatus.check(
            configurationDirectory: "~/.gemini/antigravity-cli",
            environment: ["PATH": "/nonexistent"],
            homeDirectory: home)
        XCTAssertEqual(before.executablePath, agy.standardizedFileURL.path)
        XCTAssertFalse(before.folderExists)
        XCTAssertFalse(before.settingsExists)

        let config = try makeDirectory(inside: home, name: ".gemini/antigravity-cli")
        try Data("{}".utf8).write(to: config.appendingPathComponent("settings.json"))
        let after = AntigravityCLIStatus.check(
            configurationDirectory: "~/.gemini/antigravity-cli",
            environment: ["PATH": "/nonexistent"],
            homeDirectory: home)
        XCTAssertTrue(after.folderExists)
        XCTAssertTrue(after.settingsExists)
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
}
