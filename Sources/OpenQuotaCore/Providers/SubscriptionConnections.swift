import Foundation

public enum SubscriptionConnectionKind: String, Codable, Sendable {
    case claudeStatusLine
    case codexAppServer

    public var providerID: String {
        switch self {
        case .claudeStatusLine: "claude"
        case .codexAppServer: "codex"
        }
    }
}

public struct SubscriptionConnection: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let kind: SubscriptionConnectionKind
    public var label: String
    public let directory: String

    public init(
        id: UUID = UUID(),
        kind: SubscriptionConnectionKind,
        label: String,
        directory: String
    ) {
        self.id = id
        self.kind = kind
        self.label = label
        self.directory = directory
    }

    public var accountID: String {
        AccountIdentity.makeID(
            providerID: kind.providerID,
            identityKey: id.uuidString.lowercased())
    }
}

public enum SubscriptionConnectionStoreError: Error, Equatable, Sendable {
    case invalidLabel
    case invalidDirectory
    case directoryNotFound
    case directoryNotDirectory
    case duplicateDirectory
    case duplicateConnectionID
    case connectionLimitReached
    case connectionNotFound
    case invalidStoredConnection
    case invalidExecutable
    case fileTooLarge
}

public struct SubscriptionConnectionStore: Sendable {
    public static let maxConnections = 100
    public static let maxFileBytes = 1_048_576
    private static let maxLabelLength = 128

    private let url: URL

    public init(url: URL) {
        self.url = url.standardizedFileURL
    }

    public func connections() throws -> [SubscriptionConnection] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: url)
        let data: Data
        do {
            data = try handle.read(upToCount: Self.maxFileBytes + 1) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard data.count <= Self.maxFileBytes else {
            throw SubscriptionConnectionStoreError.fileTooLarge
        }
        let values = try JSONDecoder.openQuota.decode([SubscriptionConnection].self, from: data)
        guard values.count <= Self.maxConnections,
              Set(values.map(\.id)).count == values.count,
              values.allSatisfy(isValidStoredConnection) else {
            throw SubscriptionConnectionStoreError.invalidStoredConnection
        }
        return values
    }

    @discardableResult
    public func addClaude(
        id: UUID = UUID(),
        label: String,
        configurationDirectory: String
    ) throws -> SubscriptionConnection {
        guard let normalizedLabel = Self.validatedLabel(label) else {
            throw SubscriptionConnectionStoreError.invalidLabel
        }
        let directory = try Self.canonicalExistingDirectory(configurationDirectory)
        var values = try connections()
        guard !values.contains(where: { $0.id == id }) else {
            throw SubscriptionConnectionStoreError.duplicateConnectionID
        }
        guard !values.contains(where: {
            $0.kind == .claudeStatusLine && $0.directory == directory
        }) else {
            throw SubscriptionConnectionStoreError.duplicateDirectory
        }
        guard values.count < Self.maxConnections else {
            throw SubscriptionConnectionStoreError.connectionLimitReached
        }
        let connection = SubscriptionConnection(
            id: id,
            kind: .claudeStatusLine,
            label: normalizedLabel,
            directory: directory)
        _ = try appOwnedDirectory(for: connection.id)
        values.append(connection)
        try save(values)
        return connection
    }

    @discardableResult
    public func addCodex(id: UUID = UUID(), label: String) throws -> SubscriptionConnection {
        guard let normalizedLabel = Self.validatedLabel(label) else {
            throw SubscriptionConnectionStoreError.invalidLabel
        }
        var values = try connections()
        guard !values.contains(where: { $0.id == id }) else {
            throw SubscriptionConnectionStoreError.duplicateConnectionID
        }
        guard values.count < Self.maxConnections else {
            throw SubscriptionConnectionStoreError.connectionLimitReached
        }
        let home = try appOwnedDirectory(for: id)
            .appendingPathComponent("codex-home", isDirectory: true)
        try Self.createPrivateDirectory(at: home)
        let connection = SubscriptionConnection(
            id: id,
            kind: .codexAppServer,
            label: normalizedLabel,
            directory: home.path)
        values.append(connection)
        try save(values)
        return connection
    }

    public func remove(id: UUID) throws {
        var values = try connections()
        guard let index = values.firstIndex(where: { $0.id == id }) else {
            throw SubscriptionConnectionStoreError.connectionNotFound
        }
        values.remove(at: index)
        try save(values)
    }

    public func appOwnedDirectory(for id: UUID) throws -> URL {
        let connectionsRoot = appOwnedConnectionsDirectory
        try Self.createPrivateDirectory(at: connectionsRoot)
        let directory = connectionsRoot
            .appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        try Self.createPrivateDirectory(at: directory)
        guard directory.deletingLastPathComponent().resolvingSymlinksInPath()
            == connectionsRoot.resolvingSymlinksInPath() else {
            throw SubscriptionConnectionStoreError.invalidStoredConnection
        }
        return directory
    }

    public var appOwnedConnectionsDirectory: URL {
        url.deletingLastPathComponent()
            .appendingPathComponent("connections", isDirectory: true)
            .standardizedFileURL
    }

    public func readingURL(for id: UUID) throws -> URL {
        try appOwnedDirectory(for: id).appendingPathComponent("reading.json")
    }

    public func codexHome(for connection: SubscriptionConnection) throws -> URL {
        guard connection.kind == .codexAppServer else {
            throw SubscriptionConnectionStoreError.invalidStoredConnection
        }
        let expected = try appOwnedDirectory(for: connection.id)
            .appendingPathComponent("codex-home", isDirectory: true)
        guard URL(fileURLWithPath: connection.directory).standardizedFileURL == expected else {
            throw SubscriptionConnectionStoreError.invalidStoredConnection
        }
        try Self.createPrivateDirectory(at: expected)
        return expected
    }

    public func setCodexExecutable(_ executable: URL, for connection: SubscriptionConnection) throws {
        guard connection.kind == .codexAppServer,
              executable.isFileURL,
              executable.path.hasPrefix("/"),
              executable.path.utf8.count <= 4_096,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw SubscriptionConnectionStoreError.invalidExecutable
        }
        _ = try codexHome(for: connection)
        let resolved = executable.standardizedFileURL.resolvingSymlinksInPath()
        let data = try JSONEncoder.openQuota.encode(resolved.path)
        try Self.writePrivate(
            data,
            to: appOwnedDirectory(for: connection.id)
                .appendingPathComponent("codex-executable.json"))
    }

    public func codexExecutable(for connection: SubscriptionConnection) throws -> URL? {
        guard connection.kind == .codexAppServer else {
            throw SubscriptionConnectionStoreError.invalidStoredConnection
        }
        _ = try codexHome(for: connection)
        let executableURL = try appOwnedDirectory(for: connection.id)
            .appendingPathComponent("codex-executable.json")
        guard FileManager.default.fileExists(atPath: executableURL.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: executableURL)
        let data: Data
        do {
            data = try handle.read(upToCount: 4_097) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard data.count <= 4_096,
              let path = try? JSONDecoder.openQuota.decode(String.self, from: data),
              path.hasPrefix("/") else {
            throw SubscriptionConnectionStoreError.invalidStoredConnection
        }
        let pathURL = URL(fileURLWithPath: path).standardizedFileURL
        guard pathURL.path == path else {
            throw SubscriptionConnectionStoreError.invalidStoredConnection
        }
        return FileManager.default.isExecutableFile(atPath: path)
            ? pathURL : nil
    }

    private func save(_ connections: [SubscriptionConnection]) throws {
        let data = try JSONEncoder.openQuota.encode(connections)
        guard data.count <= Self.maxFileBytes else {
            throw SubscriptionConnectionStoreError.fileTooLarge
        }
        let parent = url.deletingLastPathComponent()
        try Self.createPrivateDirectory(at: parent)
        try Self.writePrivate(data, to: url)
    }

    private func isValidStoredConnection(_ connection: SubscriptionConnection) -> Bool {
        guard Self.validatedLabel(connection.label) != nil,
              URL(fileURLWithPath: connection.directory).path.hasPrefix("/") else {
            return false
        }
        let normalized = URL(fileURLWithPath: connection.directory).standardizedFileURL.path
        guard normalized == connection.directory else { return false }
        switch connection.kind {
        case .claudeStatusLine:
            return true
        case .codexAppServer:
            let expected = url.deletingLastPathComponent()
                .appendingPathComponent("connections", isDirectory: true)
                .appendingPathComponent(connection.id.uuidString.lowercased(), isDirectory: true)
                .appendingPathComponent("codex-home", isDirectory: true)
            return URL(fileURLWithPath: connection.directory).standardizedFileURL == expected
        }
    }

    private static func validatedLabel(_ label: String) -> String? {
        let value = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= maxLabelLength else { return nil }
        return value
    }

    private static func canonicalExistingDirectory(_ path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw SubscriptionConnectionStoreError.invalidDirectory
        }
        let directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            throw SubscriptionConnectionStoreError.directoryNotFound
        }
        guard isDirectory.boolValue else {
            throw SubscriptionConnectionStoreError.directoryNotDirectory
        }
        return directory.path
    }

    private static func createPrivateDirectory(at url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw SubscriptionConnectionStoreError.invalidStoredConnection
            }
        } else {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
    }

    private static func writePrivate(_ data: Data, to url: URL) throws {
        try createPrivateDirectory(at: url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)], ofItemAtPath: url.path)
    }
}
