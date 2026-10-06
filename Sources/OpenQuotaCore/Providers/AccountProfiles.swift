import Foundation

public struct LocalAccountProfile: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var providerID: String
    public var label: String
    public var credentialPath: String

    public init(
        id: String = UUID().uuidString.lowercased(),
        providerID: String,
        label: String,
        credentialPath: String
    ) {
        self.id = id
        self.providerID = providerID
        self.label = label
        self.credentialPath = credentialPath
    }
}

public enum LocalAccountProfileError: Error, Equatable, Sendable {
    case invalidProvider
    case invalidLabel
    case invalidCredentialPath
    case credentialNotFound
    case credentialNotRegularFile
    case credentialFileTooLarge
    case profileLimitReached
    case profileNotFound
}

public struct LocalAccountProfileStore: Sendable {
    public static let maxProfiles = 100
    public static let maxCredentialFileBytes: UInt64 = 1_048_576
    public static let supportedProviderIDs: Set<String> = [
        "claude", "codex", "grok", "opencode", "devin",
    ]

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func profiles() throws -> [LocalAccountProfile] {
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > 1_048_576 { throw LocalAccountProfileError.profileLimitReached }
        guard let data = try? Data(contentsOf: url) else { return [] }
        let profiles = try JSONDecoder.openQuota.decode([LocalAccountProfile].self, from: data)
        guard profiles.count <= Self.maxProfiles else {
            throw LocalAccountProfileError.profileLimitReached
        }
        return profiles
    }

    @discardableResult
    public func add(
        providerID: String,
        label: String,
        credentialPath: String
    ) throws -> LocalAccountProfile {
        guard Self.supportedProviderIDs.contains(providerID) else {
            throw LocalAccountProfileError.invalidProvider
        }
        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLabel.isEmpty else {
            throw LocalAccountProfileError.invalidLabel
        }
        let path = try Self.validatedCredentialPath(credentialPath)
        var current = try profiles()
        if let index = current.firstIndex(where: {
            $0.providerID == providerID && $0.credentialPath == path
        }) {
            current[index].label = trimmedLabel
            try save(current)
            return current[index]
        }
        guard current.count < Self.maxProfiles else {
            throw LocalAccountProfileError.profileLimitReached
        }
        let profile = LocalAccountProfile(
            providerID: providerID,
            label: trimmedLabel,
            credentialPath: path)
        current.append(profile)
        try save(current)
        return profile
    }

    public func remove(id: String) throws {
        var current = try profiles()
        guard let index = current.firstIndex(where: { $0.id == id }) else {
            throw LocalAccountProfileError.profileNotFound
        }
        current.remove(at: index)
        try save(current)
    }

    private func save(_ profiles: [LocalAccountProfile]) throws {
        let data = try JSONEncoder.openQuota.encode(profiles)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private static func validatedCredentialPath(_ path: String) throws -> String {
        guard path.hasPrefix("/") else {
            throw LocalAccountProfileError.invalidCredentialPath
        }
        let fileURL = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory) else {
            throw LocalAccountProfileError.credentialNotFound
        }
        guard !isDirectory.boolValue,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw LocalAccountProfileError.credentialNotRegularFile
        }
        guard let size = attributes[.size] as? NSNumber,
              size.uint64Value <= maxCredentialFileBytes else {
            throw LocalAccountProfileError.credentialFileTooLarge
        }
        return fileURL.path
    }
}

public struct ProfiledProvider: UsageProvider {
    public let profile: LocalAccountProfile
    private let base: any UsageProvider

    public var id: String { profile.providerID }
    public var displayName: String { base.displayName }
    public var dashboardURL: URL? { base.dashboardURL }

    public init(profile: LocalAccountProfile, base: any UsageProvider) {
        self.profile = profile
        self.base = base
    }

    public func accounts() async throws -> [AccountDescriptor] {
        let underlying = try await base.accounts()
        if underlying.isEmpty {
            return [.init(account: .init(providerID: id, id: "\(id)@\(profile.id)", label: profile.label),
                          source: .configFile)]
        }
        return underlying.map { descriptor in
            wrap(descriptor, hasMultipleAccounts: underlying.count > 1)
        }
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        let underlying = try await base.accounts()
        guard let descriptor = underlying.first(where: {
            wrappedID(for: $0.account.id) == account.account.id
        }) else {
            throw ProviderError.notLoggedIn
        }
        let snapshot = try await base.refresh(account: descriptor)
        var identity = snapshot.account
        identity.providerID = profile.providerID
        identity.id = account.account.id
        identity.label = account.account.label
        var rewritten = snapshot
        rewritten.account = identity
        rewritten.providerID = profile.providerID
        return rewritten
    }

    private func wrap(
        _ descriptor: AccountDescriptor,
        hasMultipleAccounts: Bool
    ) -> AccountDescriptor {
        var identity = descriptor.account
        identity.id = wrappedID(for: descriptor.account.id)
        if hasMultipleAccounts, let originalLabel = descriptor.account.label {
            identity.label = "\(profile.label) · \(originalLabel)"
        } else {
            identity.label = profile.label
        }
        return AccountDescriptor(
            account: identity,
            source: descriptor.source,
            isDefaultHome: false)
    }

    private func wrappedID(for originalID: String) -> String {
        AccountIdentity.makeID(
            providerID: profile.providerID,
            identityKey: "\(profile.id)/\(originalID)")
    }
}
