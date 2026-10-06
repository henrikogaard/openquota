import Foundation

/// Runs a `ProviderSpec` against a user-supplied API key. Each stored key is
/// one account — that's the multi-account story for key-based providers.
public struct GenericProvider: UsageProvider {
    public let spec: ProviderSpec
    public var id: String { spec.id }
    public var displayName: String { spec.displayName }
    public var dashboardURL: URL? { spec.dashboardURL.flatMap(URL.init(string:)) }

    private let http: any HTTPClient
    private let credentials: any CredentialStore
    private let manifestURL: URL

    public init(
        spec: ProviderSpec,
        http: any HTTPClient,
        credentials: any CredentialStore,
        manifestURL: URL? = nil
    ) {
        self.spec = spec
        self.http = http
        self.credentials = credentials
        self.manifestURL = manifestURL ?? Self.defaultManifestURL(specID: spec.id)
    }

    static func defaultManifestURL(specID: String) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config")
        return base
            .appendingPathComponent("openquota")
            .appendingPathComponent("\(specID)-keys.json")
    }

    public func accounts() async throws -> [AccountDescriptor] {
        // Accounts are stored under "spec.id/<recordId>" in the credential store;
        // the registry of configured keys lives in a JSON manifest next to secrets.
        try configuredKeys().map { entry in
            let account = AccountIdentity(
                providerID: spec.id,
                id: entry.id,
                label: entry.label
            )
            return AccountDescriptor(account: account, source: .userSuppliedKey)
        }
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let key = try credentials.secret(for: credentialKey(account.account.id)) else {
            throw ProviderError.unauthorized
        }
        let headers = authHeaders(key: key)
        let root = try await fetchJSON(url: spec.url, headers: headers)

        // Account label/plan come from the identity paths when configured.
        var identity = account.account
        if let label = JSONPath.string(root, at: spec.identityLabel) { identity.label = label }
        if let plan = JSONPath.string(root, at: spec.map.plan) { identity.plan = plan }

        var windows: [UsageWindow] = []
        if !spec.windows.isEmpty {
            for windowSpec in spec.windows {
                // A window may point at a separate endpoint; default = shared url.
                let body: Any?
                if let url = windowSpec.url {
                    body = try await fetchJSON(url: url, headers: headers)
                } else {
                    body = root
                }
                windows.append(UsageWindow(
                    id: "\(spec.id).\(windowSpec.label.lowercased())",
                    label: windowSpec.label,
                    kind: windowSpec.kind ?? .consumption,
                    used: JSONPath.double(body, at: windowSpec.used),
                    limit: JSONPath.double(body, at: windowSpec.limit),
                    remaining: JSONPath.double(body, at: windowSpec.remaining),
                    unit: windowSpec.unit,
                    resetsAt: JSONPath.date(body, at: windowSpec.resetsAt,
                                            format: windowSpec.resetsAtFormat)
                ))
            }
        } else {
            // Single-window shorthand via the top-level field map.
            windows.append(UsageWindow(
                id: spec.id, label: spec.displayName,
                used: JSONPath.double(root, at: spec.map.used),
                limit: JSONPath.double(root, at: spec.map.limit),
                remaining: JSONPath.double(root, at: spec.map.remaining),
                resetsAt: JSONPath.date(root, at: spec.map.resetsAt,
                                        format: spec.map.resetsAtFormat)
            ))
        }

        return UsageSnapshot(
            account: identity,
            providerID: spec.id,
            windows: windows,
            creditsRemaining: JSONPath.double(root, at: spec.map.creditsRemaining),
            creditsUnit: JSONPath.string(root, at: spec.map.creditsUnit)
        )
    }

    // MARK: - Key bookkeeping

    /// Credential-store key for an account's secret.
    public func credentialKey(_ accountID: String) -> String {
        "\(spec.id)/\(accountID)"
    }

    /// Register a user-supplied key: stores secret + manifest entry.
    public func addKey(_ secret: String, label: String?) throws -> AccountIdentity {
        let id = AccountIdentity.makeID(providerID: spec.id, identityKey: secret)
        try credentials.setSecret(secret, for: credentialKey(id))
        var entries = try configuredKeys()
        entries.removeAll { $0.id == id }
        entries.append(KeyEntry(id: id, label: label))
        try saveConfiguredKeys(entries)
        return AccountIdentity(providerID: spec.id, id: id, label: label)
    }

    public func removeKey(accountID: String) throws {
        try credentials.removeSecret(for: credentialKey(accountID))
        var entries = try configuredKeys()
        entries.removeAll { $0.id == accountID }
        try saveConfiguredKeys(entries)
    }

    struct KeyEntry: Codable, Equatable {
        var id: String
        var label: String?
    }

    // Key manifest lives beside the secret store; on macOS this is
    // Application Support/openquota/<spec>-keys.json.
    func configuredKeys() throws -> [KeyEntry] {
        guard let data = try? Data(contentsOf: manifestURL) else { return [] }
        return (try? JSONDecoder.openQuota.decode([KeyEntry].self, from: data)) ?? []
    }

    private func saveConfiguredKeys(_ entries: [KeyEntry]) throws {
        let data = try JSONEncoder.openQuota.encode(entries)
        try FileManager.default.createDirectory(
            at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: manifestURL, options: .atomic)
    }

    // MARK: - HTTP

    private func authHeaders(key: String) -> [String: String] {
        switch spec.auth {
        case .bearer: return ["Authorization": "Bearer \(key)"]
        case .apiKeyHeader: return ["x-api-key": key]
        }
    }

    private func fetchJSON(url: String, headers: [String: String]) async throws -> Any {
        guard let url = URL(string: url) else { throw ProviderError.badResponse("bad URL \(url)") }
        let response = try await http.send(HTTPRequest(url: url, headers: headers))
        let body = try requireOK(response)
        guard let json = try? JSONSerialization.jsonObject(with: body) else {
            throw ProviderError.badResponse("not JSON")
        }
        return json
    }
}
