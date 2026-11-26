import Foundation

// MARK: - Antigravity CLI status line (documented, ToS-clean)

/// Reads sanitized Antigravity subscription quota snapshots captured by
/// `openquota-bridge` through Antigravity CLI's documented `statusLine`
/// customization hook (`~/.gemini/antigravity-cli/settings.json`).
/// Makes no network requests and reads no credentials or OAuth tokens.
/// Reference: https://antigravity.google/docs/cli/statusline
public struct AntigravityStatusLineProvider: UsageProvider {
    public let id = "antigravity"
    public let displayName = "Antigravity"
    public let dashboardURL = URL(string: "https://one.google.com/ai/credits")

    private let connections: [SubscriptionConnection]
    private let store: SubscriptionConnectionStore

    public init(
        connections: [SubscriptionConnection],
        store: SubscriptionConnectionStore
    ) {
        self.connections = connections.filter { $0.kind == .antigravityStatusLine }
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
        guard let connection = connections.first(where: { $0.accountID == account.account.id }) else {
            throw ProviderError.notLoggedIn
        }
        let reading = try readReading(at: store.readingURL(for: connection.id))
        do {
            return try reading.snapshot(account: account.account)
        } catch {
            throw ProviderError.badResponse(Localized.text(
                "Invalid Antigravity usage reading",
                "Ugyldig måling fra Antigravity"))
        }
    }

    private func readReading(at url: URL) throws -> AntigravityUsageReading {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ProviderError.awaitingReading
        }
        let data: Data
        do {
            data = try handle.read(upToCount: SubscriptionConnectionStore.maxFileBytes + 1) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw ProviderError.badResponse(Localized.text(
                "Could not read Antigravity usage",
                "Kunne ikke lese bruk fra Antigravity"))
        }
        guard data.count <= SubscriptionConnectionStore.maxFileBytes else {
            throw ProviderError.badResponse(Localized.text(
                "Antigravity reading is too large",
                "Antigravity-målingen er for stor"))
        }
        do {
            return try JSONDecoder.openQuota.decode(AntigravityUsageReading.self, from: data)
        } catch {
            throw ProviderError.badResponse(Localized.text(
                "Invalid Antigravity usage reading",
                "Ugyldig måling fra Antigravity"))
        }
    }
}

public struct AntigravityBridgeMetadata: Codable, Sendable, Equatable {
    public let installedCommand: String
    public let originalStatusLine: Data?
    public let addedStackWithDefault: Bool

    public init(
        installedCommand: String,
        originalStatusLine: Data?,
        addedStackWithDefault: Bool = false
    ) {
        self.installedCommand = installedCommand
        self.originalStatusLine = originalStatusLine
        self.addedStackWithDefault = addedStackWithDefault
    }

    public var originalCommand: String? {
        guard let originalStatusLine,
              let value = try? JSONSerialization.jsonObject(with: originalStatusLine) as? [String: Any],
              value["enabled"] as? Bool != false,
              let command = value["command"] as? String else {
            return nil
        }
        return command
    }
}

public enum AntigravityStatusLineInstallError: Error, Equatable, Sendable {
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

/// Installs and reversibly removes OpenQuota's status-line bridge in
/// Antigravity CLI's `settings.json` (`~/.gemini/antigravity-cli/settings.json`).
public struct AntigravityStatusLineInstaller: Sendable {
    public static let defaultRelativeDirectory = ".gemini/antigravity-cli"
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
        helperExecutable: URL,
        createDirectoryIfMissing: Bool = false
    ) throws -> SubscriptionConnection {
        let normalizedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedLabel.isEmpty, normalizedLabel.count <= 128 else {
            throw AntigravityStatusLineInstallError.invalidLabel
        }
        guard helperExecutable.isFileURL, helperExecutable.path.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: helperExecutable.path) else {
            throw AntigravityStatusLineInstallError.invalidHelper
        }
        let configDirectory = try canonicalConfigurationDirectory(
            configurationDirectory, createIfMissing: createDirectoryIfMissing)
        let appOwnedRoot = store.appOwnedConnectionsDirectory
        guard !isWithin(configDirectory, root: appOwnedRoot) else {
            throw AntigravityStatusLineInstallError.recursiveBridge
        }
        let existing = try store.connections()
        guard !existing.contains(where: {
            $0.kind == .antigravityStatusLine && $0.directory == configDirectory
        }) else {
            throw AntigravityStatusLineInstallError.duplicateConfigurationDirectory
        }
        guard existing.count < SubscriptionConnectionStore.maxConnections else {
            throw AntigravityStatusLineInstallError.connectionLimitReached
        }

        let settingsURL = URL(fileURLWithPath: configDirectory)
            .appendingPathComponent("settings.json")
        let originalData = try readSettings(settingsURL)
        var settings = try decodeSettings(originalData)
        let originalValue = settings["statusLine"]
        let originalStatusLine: Data?
        var hadActiveOriginalCommand = false
        if let originalValue {
            guard let statusLine = originalValue as? [String: Any] else {
                throw AntigravityStatusLineInstallError.unsupportedStatusLine
            }
            if let type = statusLine["type"] {
                guard let typeString = type as? String, typeString == "command" else {
                    throw AntigravityStatusLineInstallError.unsupportedStatusLine
                }
            }
            let wasDisabled = statusLine["enabled"] as? Bool == false
            if let commandValue = statusLine["command"] {
                guard let command = commandValue as? String else {
                    throw AntigravityStatusLineInstallError.unsupportedStatusLine
                }
                guard !isRecursive(command, helperPath: helperExecutable.path) else {
                    throw AntigravityStatusLineInstallError.recursiveBridge
                }
                hadActiveOriginalCommand = !wasDisabled
                    && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
            throw AntigravityStatusLineInstallError.invalidConfigurationDirectory
        }
        let command = "\(Self.shellQuote(helperExecutable.path)) --provider antigravity --connection-directory \(Self.shellQuote(appOwnedDirectory.path))"
        var statusLine = originalValue as? [String: Any] ?? [:]
        statusLine["type"] = "command"
        statusLine["command"] = command
        if statusLine["enabled"] as? Bool == false {
            statusLine["enabled"] = true
        }
        let addedStackWithDefault: Bool
        if !hadActiveOriginalCommand, statusLine["stack_with_default"] as? Bool != true {
            statusLine["stack_with_default"] = true
            addedStackWithDefault = true
        } else {
            addedStackWithDefault = false
        }
        settings["statusLine"] = statusLine

        let metadata = AntigravityBridgeMetadata(
            installedCommand: command,
            originalStatusLine: originalStatusLine,
            addedStackWithDefault: addedStackWithDefault)
        let metadataURL = appOwnedDirectory.appendingPathComponent(Self.metadataName)
        do {
            try Self.writePrivate(
                JSONEncoder.openQuota.encode(metadata),
                to: metadataURL)
            try writeSettings(settings, to: settingsURL)
        } catch {
            try? FileManager.default.removeItem(at: metadataURL)
            throw AntigravityStatusLineInstallError.malformedSettings
        }

        do {
            return try store.addAntigravity(
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
        guard connection.kind == .antigravityStatusLine else { return false }
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
        let metadata = try JSONDecoder.openQuota.decode(AntigravityBridgeMetadata.self, from: metadataData)
        let configDirectory = try canonicalConfigurationDirectory(configurationDirectory, createIfMissing: false)
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

        // Rebuild the state we wrote at install time so any later user edits
        // to other keys (e.g. padding) are preserved.
        var installed = original ?? ["type": "command"]
        installed["type"] = "command"
        installed["command"] = metadata.installedCommand
        if installed["enabled"] as? Bool == false {
            installed["enabled"] = true
        }
        if metadata.addedStackWithDefault {
            installed["stack_with_default"] = true
        }

        var restored = original ?? [:]
        for key in Set(installed.keys).union(statusLine.keys) where key != "command" {
            guard !Self.jsonValuesEqual(installed[key], statusLine[key]) else { continue }
            if let value = statusLine[key] {
                restored[key] = value
            } else {
                restored.removeValue(forKey: key)
            }
        }
        if let original {
            if let originalCommand = original["command"] {
                restored["command"] = originalCommand
            }
            settings["statusLine"] = restored
        } else if !restored.isEmpty {
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
            throw AntigravityStatusLineInstallError.malformedSettings
        }
        do {
            return try Self.readBounded(url, limit: Self.settingsLimit)
        } catch SubscriptionConnectionStoreError.fileTooLarge {
            throw AntigravityStatusLineInstallError.settingsTooLarge
        } catch {
            throw AntigravityStatusLineInstallError.malformedSettings
        }
    }

    private func decodeSettings(_ data: Data?) throws -> [String: Any] {
        guard let data else { return [:] }
        guard let value = try? JSONSerialization.jsonObject(with: data),
              let settings = value as? [String: Any] else {
            throw AntigravityStatusLineInstallError.malformedSettings
        }
        return settings
    }

    private func writeSettings(_ settings: [String: Any], to url: URL) throws {
        guard JSONSerialization.isValidJSONObject(settings) else {
            throw AntigravityStatusLineInstallError.malformedSettings
        }
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber ?? NSNumber(value: 0o600)
        try Self.atomicWrite(data, to: url, permissions: permissions)
    }

    private func canonicalConfigurationDirectory(_ path: String, createIfMissing: Bool) throws -> String {
        guard path.hasPrefix("/") else {
            throw AntigravityStatusLineInstallError.invalidConfigurationDirectory
        }
        let candidate = URL(fileURLWithPath: path).standardizedFileURL
        var isDirectory: ObjCBool = false
        if !FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory) {
            guard createIfMissing else {
                throw AntigravityStatusLineInstallError.configurationDirectoryNotFound
            }
            do {
                try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: true)
                try FileManager.default.setAttributes(
                    [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: candidate.path)
            } catch {
                throw AntigravityStatusLineInstallError.invalidConfigurationDirectory
            }
            isDirectory = true
        }
        guard isDirectory.boolValue else {
            throw AntigravityStatusLineInstallError.invalidConfigurationDirectory
        }
        return candidate.resolvingSymlinksInPath().path
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

/// Local readiness check for the Antigravity CLI setup form. Reads no tokens
/// or credentials — only checks whether `agy` and the settings folder exist.
public struct AntigravityCLIStatus: Equatable, Sendable {
    public let executablePath: String?
    public let folderExists: Bool
    public let settingsExists: Bool

    public static func check(
        configurationDirectory: String,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Self {
        let executable = resolveExecutable(environment: environment, homeDirectory: homeDirectory)?.path
        let expanded = ClaudeProfileStatus.expanded(configurationDirectory, homeDirectory: homeDirectory)
        var isDirectory: ObjCBool = false
        let folderExists = FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory)
            && isDirectory.boolValue
        let settingsPath = URL(fileURLWithPath: expanded).appendingPathComponent("settings.json").path
        let settingsExists = folderExists && FileManager.default.fileExists(atPath: settingsPath)
        return Self(
            executablePath: executable,
            folderExists: folderExists,
            settingsExists: settingsExists)
    }

    public static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL? {
        let directories = CodexExecutableResolver.searchDirectories(
            environment: environment, homeDirectory: homeDirectory)
            + [homeDirectory.appendingPathComponent(".local/bin").path]
        var seen = Set<String>()
        for directory in directories where seen.insert(directory).inserted {
            let candidate = URL(fileURLWithPath: directory).appendingPathComponent("agy")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate.standardizedFileURL
            }
        }
        return nil
    }
}
