import Foundation

/// Where user-supplied API keys live. On macOS this is the Keychain; elsewhere
/// a file under the config dir with 0600 perms (for the Linux CLI/tests).
public protocol CredentialStore: Sendable {
    /// Store or replace the secret for `key` (e.g. "openrouter@ab12cd34").
    func setSecret(_ secret: String, for key: String) throws
    func secret(for key: String) throws -> String?
    func removeSecret(for key: String) throws
}

#if os(macOS)
import Security

public struct KeychainCredentialStore: CredentialStore {
    private let service: String

    public init(service: String = "no.ogard.openquota") {
        self.service = service
    }

    public func setSecret(_ secret: String, for key: String) throws {
        let data = Data(secret.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let update = SecItemUpdate(query as CFDictionary, [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else {
            throw ProviderError.badResponse("keychain write failed: \(update)")
        }
        var attrs = query
        attrs[kSecValueData as String] = data
        // Never synced to iCloud Keychain and never restored onto another Mac.
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attrs[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw ProviderError.badResponse("keychain write failed: \(status)")
        }
    }

    public func secret(for key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw ProviderError.badResponse("keychain read failed: \(status)")
        }
        // Items saved by ≤0.1.4 used the syncable/migratable class; tighten in place.
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        _ = SecItemUpdate(base as CFDictionary, [
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as CFDictionary)
        return String(data: data, encoding: .utf8)
    }

    public func removeSecret(for key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ProviderError.badResponse("keychain delete failed: \(status)")
        }
    }
}
#endif

/// File-backed store used on Linux (and by tests). Secrets live in a
/// 0600 JSON file — acceptable for dev/CI; macOS always uses Keychain.
public struct FileCredentialStore: CredentialStore {
    private let url: URL

    public init(directory: URL) {
        self.url = directory.appendingPathComponent("secrets.json")
    }

    private func load() -> [String: String] {
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }

    private func save(_ dict: [String: String]) throws {
        try PrivateFile.write(try JSONEncoder().encode(dict), to: url)
    }

    public func setSecret(_ secret: String, for key: String) throws {
        var dict = load()
        dict[key] = secret
        try save(dict)
    }

    public func secret(for key: String) throws -> String? {
        load()[key]
    }

    public func removeSecret(for key: String) throws {
        var dict = load()
        dict.removeValue(forKey: key)
        try save(dict)
    }
}
