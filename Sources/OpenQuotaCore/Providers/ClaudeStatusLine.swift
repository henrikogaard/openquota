import Foundation

public struct ClaudeStatusLineProvider: UsageProvider {
    public let id = "claude"
    public let displayName = "Claude Code"
    public let dashboardURL = URL(string: "https://claude.ai/settings/usage")

    private let connections: [SubscriptionConnection]
    private let store: SubscriptionConnectionStore

    public init(connections: [SubscriptionConnection], store: SubscriptionConnectionStore) {
        self.connections = connections.filter { $0.kind == .claudeStatusLine }
        self.store = store
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
        let readingURL = try store.readingURL(for: connection.id)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: readingURL)
        } catch {
            throw ProviderError.awaitingReading
        }
        let data: Data
        do {
            data = try handle.read(upToCount: SubscriptionConnectionStore.maxFileBytes + 1) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw ProviderError.badResponse(Localized.text("Could not read Claude usage", "Kunne ikke lese bruk fra Claude"))
        }
        guard data.count <= SubscriptionConnectionStore.maxFileBytes else {
            throw ProviderError.badResponse(Localized.text("Claude reading is too large", "Claude-målingen er for stor"))
        }
        let reading: ClaudeUsageReading
        do {
            reading = try JSONDecoder.openQuota.decode(ClaudeUsageReading.self, from: data)
        } catch {
            throw ProviderError.badResponse(Localized.text("Invalid Claude usage reading", "Ugyldig måling fra Claude"))
        }
        do {
            return try reading.snapshot(account: account.account)
        } catch {
            throw ProviderError.badResponse(Localized.text("Invalid Claude usage reading", "Ugyldig måling fra Claude"))
        }
    }
}

public struct ClaudeBridgeMetadata: Codable, Sendable, Equatable {
    public let installedCommand: String
    public let originalStatusLine: Data?

    public init(installedCommand: String, originalStatusLine: Data?) {
        self.installedCommand = installedCommand
        self.originalStatusLine = originalStatusLine
    }

    public var originalCommand: String? {
        guard let originalStatusLine,
              let value = try? JSONSerialization.jsonObject(with: originalStatusLine) as? [String: Any],
              let command = value["command"] as? String else {
            return nil
        }
        return command
    }
}

public enum ClaudeStatusLineInstallError: Error, Equatable, Sendable {
    case invalidLabel
    case invalidConfigurationDirectory
    case configurationDirectoryNotFound
    case duplicateConfigurationDirectory
    case invalidHelper
    case recursiveBridge
    case malformedSettings
    case unsupportedStatusLine
    case settingsTooLarge
    case connectionLimitReached
}

public struct ClaudeStatusLineInstaller: Sendable {
    private static let settingsLimit = 1_048_576
    private static let metadataName = "bridge-metadata.json"

    private let store: SubscriptionConnectionStore

    public init(store: SubscriptionConnectionStore) {
        self.store = store
    }

    @discardableResult
    public func install(
        label: String,
        configurationDirectory: String,
        helperExecutable: URL
    ) throws -> SubscriptionConnection {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty, normalizedLabel.count <= 128 else {
            throw ClaudeStatusLineInstallError.invalidLabel
        }
        guard helperExecutable.isFileURL, helperExecutable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: helperExecutable.path) else {
            throw ClaudeStatusLineInstallError.invalidHelper
        }
        let configDirectory = try canonicalConfigurationDirectory(configurationDirectory)
        let appOwnedRoot = storeDirectoryRoot()
        guard !isWithin(configDirectory, root: appOwnedRoot) else {
            throw ClaudeStatusLineInstallError.recursiveBridge
        }
        let existing = try store.connections()
        guard !existing.contains(where: {
            $0.kind == .claudeStatusLine && $0.directory == configDirectory
        }) else {
            throw ClaudeStatusLineInstallError.duplicateConfigurationDirectory
        }
        guard existing.count < SubscriptionConnectionStore.maxConnections else {
            throw ClaudeStatusLineInstallError.connectionLimitReached
        }

        let settingsURL = URL(fileURLWithPath: configDirectory)
            .appendingPathComponent("settings.json")
        let originalData = try readSettings(settingsURL)
        var settings = try decodeSettings(originalData)
        let originalValue = settings["statusLine"]
        let originalStatusLine: Data?
        if let originalValue {
            guard let statusLine = originalValue as? [String: Any],
                  let type = statusLine["type"] as? String,
                  type == "command",
                  let command = statusLine["command"] as? String else {
                throw ClaudeStatusLineInstallError.unsupportedStatusLine
            }
            guard !isRecursive(command, helperPath: helperExecutable.path) else {
                throw ClaudeStatusLineInstallError.recursiveBridge
            }
            originalStatusLine = try JSONSerialization.data(
                withJSONObject: statusLine, options: [.sortedKeys])
        } else {
            originalStatusLine = nil
        }

        let id = UUID()
        let appOwnedDirectory: URL
        do {
            appOwnedDirectory = try store.appOwnedDirectory(for: id)
        } catch {
            throw ClaudeStatusLineInstallError.invalidConfigurationDirectory
        }
        let command = "\(Self.shellQuote(helperExecutable.path)) --connection-directory \(Self.shellQuote(appOwnedDirectory.path))"
        var statusLine = originalValue as? [String: Any] ?? ["type": "command"]
        statusLine["command"] = command
        settings["statusLine"] = statusLine

        let metadata = ClaudeBridgeMetadata(
            installedCommand: command,
            originalStatusLine: originalStatusLine)
        let metadataURL = appOwnedDirectory.appendingPathComponent(Self.metadataName)
        do {
            try Self.writePrivate(
                JSONEncoder.openQuota.encode(metadata),
                to: metadataURL)
            try writeSettings(settings, to: settingsURL)
        } catch {
            try? FileManager.default.removeItem(at: metadataURL)
            throw ClaudeStatusLineInstallError.malformedSettings
        }

        do {
            return try store.addClaude(
                id: id,
                label: normalizedLabel,
                configurationDirectory: configDirectory)
        } catch {
            _ = try? disconnect(
                configurationDirectory: configDirectory,
                appOwnedDirectory: appOwnedDirectory)
            throw error
        }
    }

    @discardableResult
    public func disconnect(_ connection: SubscriptionConnection) throws -> Bool {
        guard connection.kind == .claudeStatusLine else { return false }
        let appOwnedDirectory = try store.appOwnedDirectory(for: connection.id)
        return try disconnect(
            configurationDirectory: connection.directory,
            appOwnedDirectory: appOwnedDirectory)
    }

    @discardableResult
    public func disconnect(connectionID: UUID, configurationDirectory: String) throws -> Bool {
        let appOwnedDirectory = try store.appOwnedDirectory(for: connectionID)
        return try disconnect(
            configurationDirectory: configurationDirectory,
            appOwnedDirectory: appOwnedDirectory)
    }

    private func disconnect(
        configurationDirectory: String,
        appOwnedDirectory: URL
    ) throws -> Bool {
        let metadataURL = appOwnedDirectory.appendingPathComponent(Self.metadataName)
        let metadataData = try Self.readBounded(metadataURL, limit: Self.settingsLimit)
        let metadata = try JSONDecoder.openQuota.decode(ClaudeBridgeMetadata.self, from: metadataData)
        let configDirectory = try canonicalConfigurationDirectory(configurationDirectory)
        let settingsURL = URL(fileURLWithPath: configDirectory)
            .appendingPathComponent("settings.json")
        guard let currentData = try readSettings(settingsURL, allowMissing: true) else { return false }
        var settings = try decodeSettings(currentData)
        guard let statusLine = settings["statusLine"] as? [String: Any],
              statusLine["command"] as? String == metadata.installedCommand else {
            return false
        }
        let original: [String: Any]?
        if let originalData = metadata.originalStatusLine {
            original = try JSONSerialization.jsonObject(with: originalData) as? [String: Any]
        } else {
            original = nil
        }
        let baseline = original ?? ["type": "command"]
        var restored = baseline
        for key in Set(baseline.keys).union(statusLine.keys) where key != "command" {
            guard !Self.jsonValuesEqual(baseline[key], statusLine[key]) else { continue }
            if let value = statusLine[key] {
                restored[key] = value
            } else {
                restored.removeValue(forKey: key)
            }
        }
        if let original {
            restored["command"] = original["command"]
            settings["statusLine"] = restored
        } else if restored.contains(where: { $0.key != "type" })
                    || restored["type"] as? String != "command" {
            settings["statusLine"] = restored
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        try writeSettings(settings, to: settingsURL)
        try? FileManager.default.removeItem(at: metadataURL)
        return true
    }

    private func readSettings(_ url: URL, allowMissing: Bool = false) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return allowMissing ? nil : Data("{}".utf8)
        }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ClaudeStatusLineInstallError.malformedSettings
        }
        do {
            return try Self.readBounded(url, limit: Self.settingsLimit)
        } catch SubscriptionConnectionStoreError.fileTooLarge {
            throw ClaudeStatusLineInstallError.settingsTooLarge
        } catch {
            throw ClaudeStatusLineInstallError.malformedSettings
        }
    }

    private func decodeSettings(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let settings = value as? [String: Any] else {
            throw ClaudeStatusLineInstallError.malformedSettings
        }
        return settings
    }

    private func writeSettings(_ settings: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(settings) else {
            throw ClaudeStatusLineInstallError.malformedSettings
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber ?? NSNumber(value: 0o600)
        try Self.atomicWrite(data, to: url, permissions: permissions)
    }

    private func canonicalConfigurationDirectory(_ path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw ClaudeStatusLineInstallError.invalidConfigurationDirectory
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw ClaudeStatusLineInstallError.configurationDirectoryNotFound
        }
        guard isDirectory.boolValue else {
            throw ClaudeStatusLineInstallError.invalidConfigurationDirectory
        }
        return directory.path
    }

    private func storeDirectoryRoot() -> URL {
        store.appOwnedConnectionsDirectory
    }

    private func isWithin(_ directory: String, root: URL) -> Bool {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = URL(fileURLWithPath: directory).standardizedFileURL.path
        return path == normalizedRoot || path.hasPrefix(normalizedRoot + "/")
    }

    private func isRecursive(_ command: String, helperPath: String) -> Bool {
        command.contains(helperPath) || command.range(
            of: #"(?:^|[\s/])openquota-bridge(?:\s|$)"#,
            options: .regularExpression) != nil
    }

    private static func jsonValuesEqual(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            guard let left = try? JSONSerialization.data(
                      withJSONObject: [lhs], options: [.sortedKeys]),
                  let right = try? JSONSerialization.data(
                      withJSONObject: [rhs], options: [.sortedKeys]) else {
                return false
            }
            return left == right
        default:
            return false
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func readBounded(_ url: URL, limit: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw SubscriptionConnectionStoreError.fileTooLarge
        }
        return data
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try atomicWrite(data, to: url, permissions: NSNumber(value: 0o600))
    }

    private static func atomicWrite(_ data: Data, to url: URL, permissions: NSNumber) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: permissions], ofItemAtPath: url.path)
    }
}
