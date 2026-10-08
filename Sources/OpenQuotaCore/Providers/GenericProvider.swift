import Foundation

/// Runs a `ProviderSpec` against a user-supplied API key. Each stored key is
/// one account — that's the multi-account story for key-based providers.
public struct GenericProvider: UsageProvider {
    public let spec: ProviderSpec
    public var id: String { spec.id }
    public var displayName: String { spec.displayName }
    public var dashboardURL: URL? { spec.dashboardURL.flatMap(URL.init(string:)) }
    /// True when the spec's endpoint/field mapping hasn't been verified
    /// against a live account — Settings shows an "unverified" hint.
    public var unverified: Bool { spec.unverified }

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
        let root = try await fetchJSON(
            url: spec.url, method: spec.method, body: spec.body, headers: headers)

        // Account label/plan come from the identity paths when configured.
        var identity = account.account
        if identity.label == nil, let label = JSONPath.string(root, at: spec.identityLabel) { identity.label = label }
        if let plan = JSONPath.string(root, at: spec.map.plan) { identity.plan = plan }

        var windows: [UsageWindow] = []
        if !spec.windows.isEmpty {
            for windowSpec in spec.windows {
                // A window may point at a separate endpoint; default = shared url.
                let body: Any?
                if let url = windowSpec.url {
                    var windowHeaders = headers
                    windowSpec.headers?.forEach { windowHeaders[$0] = $1 }
                    body = try await fetchJSON(
                        url: url, method: windowSpec.method, body: windowSpec.body,
                        headers: windowHeaders)
                } else {
                    body = root
                }
                windows.append(UsageWindow(
                    id: "\(spec.id).\(windowSpec.label.lowercased())",
                    label: windowSpec.label,
                    kind: windowSpec.kind ?? .consumption,
                    used: numeric(body, at: windowSpec.used),
                    limit: numeric(body, at: windowSpec.limit) ?? (windowSpec.unit == "%" ? 100 : nil),
                    remaining: numeric(body, at: windowSpec.remaining),
                    unit: windowSpec.unit,
                    resetsAt: JSONPath.date(body, at: windowSpec.resetsAt,
                                            format: windowSpec.resetsAtFormat)
                ))
            }
        } else {
            // Single-window shorthand via the top-level field map.
            windows.append(UsageWindow(
                id: spec.id, label: spec.displayName,
                used: numeric(root, at: spec.map.used),
                limit: numeric(root, at: spec.map.limit),
                remaining: numeric(root, at: spec.map.remaining),
                resetsAt: JSONPath.date(root, at: spec.map.resetsAt,
                                        format: spec.map.resetsAtFormat)
            ))
        }

        windows.removeAll { $0.used == nil && $0.remaining == nil }
        var credits = numeric(root, at: spec.map.creditsRemaining)
        if let path = spec.map.creditsUsed {
            if let purchased = credits, let used = numeric(root, at: path) { credits = purchased - used }
            else { credits = nil }
        }
        guard !windows.isEmpty || credits != nil else {
            throw ProviderError.badResponse("no recognized usage fields")
        }
        return UsageSnapshot(
            account: identity,
            providerID: spec.id,
            windows: windows,
            creditsRemaining: credits,
            creditsUnit: spec.map.creditsUnitLabel ?? JSONPath.string(root, at: spec.map.creditsUnit)
        )
    }

    // MARK: - Key bookkeeping

    /// Credential-store key for an account's secret.
    public func credentialKey(_ accountID: String) -> String {
        "\(spec.id)/\(accountID)"
    }

    /// Register a user-supplied key: stores secret + manifest entry.
    public func addKey(_ secret: String, label: String?) throws -> AccountIdentity {
        var entries = try configuredKeys()
        guard !secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderError.badResponse("empty credential")
        }
        let existing = try entries.first { try credentials.secret(for: credentialKey($0.id)) == secret }
        let id = existing?.id ?? "\(spec.id)@\(UUID().uuidString.lowercased())"
        guard existing != nil || entries.count < 100 else {
            throw ProviderError.badResponse("maximum 100 accounts per provider")
        }
        try credentials.setSecret(secret, for: credentialKey(id))
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

    public func replaceKey(_ secret: String, accountID: String, label: String? = nil) throws -> AccountIdentity {
        let secret = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else {
            throw ProviderError.badResponse(Localized.text("Enter a credential.", "Skriv inn en nøkkel."))
        }
        let entries = try configuredKeys()
        guard let entry = entries.first(where: { $0.id == accountID }) else {
            throw ProviderError.notLoggedIn
        }
        for other in entries where other.id != accountID {
            if try credentials.secret(for: credentialKey(other.id)) == secret {
                throw ProviderError.badResponse(Localized.text(
                    "This credential is already saved for another account.",
                    "Denne nøkkelen er allerede lagret for en annen konto."))
            }
        }
        try credentials.setSecret(secret, for: credentialKey(accountID))
        let resolvedLabel = label ?? entry.label
        try renameKey(accountID: accountID, label: resolvedLabel)
        return AccountIdentity(providerID: spec.id, id: accountID, label: resolvedLabel)
    }

    public func renameKey(accountID: String, label: String?) throws {
        var entries = try configuredKeys()
        guard let index = entries.firstIndex(where: { $0.id == accountID }) else { return }
        entries[index].label = label
        try saveConfiguredKeys(entries)
    }

    struct KeyEntry: Codable, Equatable {
        var id: String
        var label: String?
    }

    // Key manifest lives beside the secret store; on macOS this is
    // Application Support/openquota/<spec>-keys.json.
    func configuredKeys() throws -> [KeyEntry] {
        guard FileManager.default.fileExists(atPath: manifestURL.path) else { return [] }
        let size = try manifestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw ProviderError.badResponse("key manifest too large") }
        let entries = try JSONDecoder.openQuota.decode([KeyEntry].self, from: Data(contentsOf: manifestURL))
        guard entries.count <= 100 else { throw ProviderError.badResponse("too many saved keys") }
        return entries
    }

    private func saveConfiguredKeys(_ entries: [KeyEntry]) throws {
        let data = try JSONEncoder.openQuota.encode(entries)
        try PrivateFile.write(data, to: manifestURL)
    }

    // MARK: - HTTP

    private func authHeaders(key: String) -> [String: String] {
        var headers: [String: String]
        switch spec.auth {
        case .bearer:
            headers = ["Authorization": "Bearer \(key)"]
        case .apiKeyHeader:
            headers = ["x-api-key": key]
        case .header:
            let name = spec.authHeader ?? "Authorization"
            headers = [name: "\(spec.authPrefix ?? "")\(key)"]
        case .cookie:
            headers = ["Cookie": key]
        }
        spec.headers?.forEach { headers[$0] = $1 }
        return headers
    }

    /// A numeric path may be prefixed "sum:" to total wildcard-flattened
    /// leaves (e.g. "sum:$.data[*].results[*].amount.value").
    private func numeric(_ root: Any?, at path: String?) -> Double? {
        guard let path else { return nil }
        if path.hasPrefix("sum:") {
            return JSONPath.sum(root, at: String(path.dropFirst(4)))
        }
        return JSONPath.double(root, at: path)
    }

    /// Substitutes {now}, {today}, {d7}, {d30} epoch-seconds templates in URLs.
    private func resolveURL(_ template: String) -> String {
        let now = Date()
        var url = template
            .replacingOccurrences(of: "{now}", with: String(Int(now.timeIntervalSince1970)))
            .replacingOccurrences(of: "{d7}", with: String(Int(now.timeIntervalSince1970) - 7 * 86400))
            .replacingOccurrences(of: "{d30}", with: String(Int(now.timeIntervalSince1970) - 30 * 86400))
        if url.contains("{today}") {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let start = calendar.startOfDay(for: now)
            url = url.replacingOccurrences(
                of: "{today}", with: String(Int(start.timeIntervalSince1970)))
        }
        return url
    }

    private func fetchJSON(
        url template: String, method: String? = nil, body: String? = nil,
        headers: [String: String]
    ) async throws -> Any {
        guard let url = URL(string: resolveURL(template)) else {
            throw ProviderError.badResponse("bad URL \(template)")
        }
        var request = HTTPRequest(url: url, headers: headers)
        request.method = method ?? "GET"
        if let body { request.body = Data(body.utf8) }
        if request.method != "GET" && request.headers["Content-Type"] == nil {
            request.headers["Content-Type"] = "application/json"
        }
        let response = try await http.send(request)
        let data = try requireOK(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ProviderError.badResponse("not JSON")
        }
        return json
    }
}
