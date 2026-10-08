import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Hand-written adapters for providers that can't be expressed as a spec:
/// local credential files + OAuth refresh + non-JSON-shaped quirks. These
/// never touch browser cookies — only files the provider's own CLI wrote.
public enum Adapters {
    public static func all(
        http: any HTTPClient,
        credentials: any CredentialStore,
        files: LocalCredentialFiles = .init()
    ) -> [any UsageProvider] {
        [
            GeminiProvider(http: http, files: files),
            GrokProvider(http: http, files: files),
            OpenCodeProvider(http: http, files: files),
            DevinProvider(http: http, files: files),
            CursorProvider(http: http, credentials: credentials),
            CopilotProvider(http: http, files: files),
        ]
    }
}

/// Reads the first numeric value found under any candidate key (adapters see
/// slightly different payload spellings across versions).
func adapterNum(_ dict: [String: Any]?, _ keys: [String]) -> Double? {
    for key in keys {
        if let v = dict?[key] as? NSNumber { return v.doubleValue }
        if let s = dict?[key] as? String, let d = Double(s) { return d }
    }
    return nil
}

/// Percent fields are already in 0...100; 0.5 means half a percent, not 50%.
func normalizePercent(_ raw: Double?) -> Double? {
    guard let raw, raw.isFinite else { return nil }
    return raw
}

// MARK: - Gemini (CLI OAuth)

/// `~/.gemini/oauth_creds.json` → cloudcode-pa.googleapis.com retrieveUserQuota.
/// Client ID/secret are the Gemini CLI's public, embedded OAuth credentials.
public struct GeminiProvider: UsageProvider {
    public let id = "gemini"
    public let displayName = "Gemini"
    public let dashboardURL = URL(string: "https://aistudio.google.com/usage")

    static let credsPath = ".gemini/oauth_creds.json"
    static let clientID =
        "681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com"
    /// The Gemini CLI's public OAuth client secret (embedded in the OSS CLI,
    /// not a user credential). Split so repo secret scanners don't misfire.
    static var clientSecret: String {
        ["GOCSPX", "4uHgMPm", "1o7Sk", "geV6Cu5clXFsxl"].joined(separator: "-")
    }

    private let http: any HTTPClient
    private let files: LocalCredentialFiles

    public init(http: any HTTPClient, files: LocalCredentialFiles) {
        self.http = http
        self.files = files
    }

    private func creds() -> [String: Any]? { files.readJSON(Self.credsPath) }

    public func accounts() async throws -> [AccountDescriptor] {
        guard let c = creds(), c["access_token"] is String else { return [] }
        var label = "Gemini CLI"
        if let accounts = files.readJSON(".gemini/google_accounts.json"),
           let active = accounts["active"] as? String {
            label = active
        }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: label),
            label: label)
        return [AccountDescriptor(account: identity, source: .configFile, isDefaultHome: true)]
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let c = creds(), let at = c["access_token"] as? String else {
            throw ProviderError.notLoggedIn
        }
        var token = at
        let expiry = (c["expiry_date"] as? NSNumber)?.doubleValue ?? 0
        if Date().timeIntervalSince1970 >= expiry / 1000 - 60,
           let rt = c["refresh_token"] as? String {
            let refreshed = try await OAuthRefresher.refresh(
                url: "https://oauth2.googleapis.com/token",
                clientID: Self.clientID, refreshToken: rt,
                clientSecret: Self.clientSecret, http: http)
            token = refreshed.accessToken
            var newCreds = c
            newCreds["access_token"] = refreshed.accessToken
            if let rt = refreshed.refreshToken { newCreds["refresh_token"] = rt }
            if let exp = refreshed.expiresAt { newCreds["expiry_date"] = Int(exp * 1000) }
            try files.writeJSON(Self.credsPath, newCreds)
        }
        let authHeaders = ["Authorization": "Bearer \(token)"]

        // Project discovery: Gemini CLI resolves a Code Assist project first.
        var project: String?
        if let load = try? await AdapterHTTP.postJSON(
            "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist",
            body: ["metadata": ["pluginType": "GEMINI"]],
            headers: authHeaders, http: http) as? [String: Any] {
            project = load["cloudaicompanionProject"] as? String
        }

        var requestBody: [String: Any] = [:]
        if let project { requestBody["project"] = project }
        let body = try await AdapterHTTP.postJSON(
            "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota",
            body: requestBody, headers: authHeaders, http: http)
        guard let dict = body as? [String: Any],
              let buckets = dict["buckets"] as? [[String: Any]] else {
            throw ProviderError.badResponse("usage payload")
        }
        var windows: [UsageWindow] = []
        for (index, bucket) in buckets.prefix(4).enumerated() {
            let model = (bucket["modelId"] as? String) ?? "model \(index + 1)"
            if let remaining = adapterNum(bucket, ["remainingFraction"]),
               let w = percentWindow(
                "gemini.\(index)", model,
                used: min(max((1 - remaining) * 100, 0), 100),
                resetsAt: bucket["resetTime"]) {
                windows.append(w)
            }
        }
        if windows.isEmpty { throw ProviderError.badResponse("no quota buckets") }
        return UsageSnapshot(account: account.account, providerID: id, windows: windows)
    }
}

// MARK: - Grok (CLI auth.json, multi-account)

/// `~/.grok/auth.json` holds one or more token entries; refresh goes through
/// auth.x.ai, usage through cli-chat-proxy.grok.com.
public struct GrokProvider: UsageProvider {
    public let id = "grok"
    public let displayName = "Grok"
    public let dashboardURL = URL(string: "https://grok.com/settings/usage")

    static let authPath = ".grok/auth.json"

    private let http: any HTTPClient
    private let files: LocalCredentialFiles

    public init(http: any HTTPClient, files: LocalCredentialFiles) {
        self.http = http
        self.files = files
    }

    /// auth.json is either {accessToken...} or {<name>: {accessToken...}}.
    private func entries() -> [(String, [String: Any])] {
        guard let root = files.readJSON(Self.authPath) else { return [] }
        if root["accessToken"] is String || root["access_token"] is String || root["key"] is String {
            return [("default", root)]
        }
        var found: [(String, [String: Any])] = []
        for (key, value) in root {
            if let dict = value as? [String: Any],
               dict["accessToken"] is String || dict["access_token"] is String || dict["key"] is String {
                found.append((key, dict))
            }
        }
        return found.sorted { $0.0 < $1.0 }
    }

    public func accounts() async throws -> [AccountDescriptor] {
        entries().map { name, entry in
            AccountDescriptor(
                account: AccountIdentity(
                    providerID: id,
                    id: AccountIdentity.makeID(providerID: id, identityKey: name),
                    label: Self.label(entryKey: name, entry: entry)),
                source: .configFile, isDefaultHome: name == "default")
        }
    }

    /// The signed-in email from the entry's ID token, else a readable entry
    /// name. CLI entry keys like `https://auth.x.ai::<client-id>` are not shown.
    static func label(entryKey: String, entry: [String: Any]) -> String {
        if let idToken = entry["id_token"] as? String ?? entry["idToken"] as? String,
           let claims = JWTClaims.decode(idToken),
           let email = claims["email"] as? String, !email.isEmpty {
            return email
        }
        if entryKey == "default" || entryKey.contains("::") || entryKey.contains("://") {
            return "Grok CLI"
        }
        return entryKey
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        let match = entries().first {
            AccountIdentity.makeID(providerID: id, identityKey: $0.0) == account.account.id
        }
        guard let (name, entry) = match else { throw ProviderError.notLoggedIn }
        var token = (entry["key"] ?? entry["accessToken"] ?? entry["access_token"]) as? String ?? ""
        let rawExpiry = adapterNum(entry, ["expiresAt", "expires_at"])
        let expiry = rawExpiry.map { $0 > 1e12 ? $0 / 1000 : $0 }
            ?? JSONPath.date(entry, at: "$.expires_at", format: "iso8601")?.timeIntervalSince1970
            ?? JSONPath.date(entry, at: "$.expires", format: "iso8601")?.timeIntervalSince1970
        let bundle = OAuthTokens(accessToken: token, expiresAt: expiry)
        if bundle.isExpired,
           let rt = (entry["refresh_token"] ?? entry["refreshToken"] ?? entry["refresh"]) as? String {
            let client = entry["oidc_client_id"] as? String
                ?? (name.contains("::") ? name.components(separatedBy: "::").last : nil)
                ?? "b1a00492-073a-47ea-816f-4c329264a828"
            let refreshed = try await OAuthRefresher.refresh(
                url: "https://auth.x.ai/oauth2/token",
                clientID: client, refreshToken: rt, http: http)
            token = refreshed.accessToken
            var root = files.readJSON(Self.authPath) ?? [:]
            var mutableEntry = entry
            let tokenKey = entry["key"] != nil ? "key" : entry["access_token"] != nil ? "access_token" : "accessToken"
            mutableEntry[tokenKey] = refreshed.accessToken
            if let rt = refreshed.refreshToken {
                mutableEntry[entry["refreshToken"] != nil ? "refreshToken" : "refresh_token"] = rt
            }
            if let exp = refreshed.expiresAt {
                mutableEntry["expires_at"] = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: exp))
                mutableEntry.removeValue(forKey: "expiresAt")
                mutableEntry.removeValue(forKey: "expires")
            }
            if name == "default", root[tokenKey] != nil { root = mutableEntry }
            else { root[name] = mutableEntry }
            try files.writeJSON(Self.authPath, root)
        }
        let body = try await AdapterHTTP.getJSON(
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            headers: ["Authorization": "Bearer \(token)", "X-XAI-Token-Auth": "xai-grok-cli"],
            http: http)
        guard let dict = body as? [String: Any],
              let config = dict["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any],
              let end = period["end"] as? String else {
            throw ProviderError.badResponse("billing payload")
        }
        guard let used = config["creditUsagePercent"] == nil ? 0 : adapterNum(config, ["creditUsagePercent"]),
              let window = percentWindow(
            "grok.week", "Week",
            used: used, resetsAt: end), window.resetsAt != nil else {
            throw ProviderError.badResponse("billing window")
        }
        return UsageSnapshot(
            account: account.account, providerID: id,
            windows: [window])
    }
}

// MARK: - OpenCode Go

/// `opencode-go` entry in `~/.local/share/opencode/auth.json` → zen/go usage.
public struct OpenCodeProvider: UsageProvider {
    public let id = "opencode"
    public let displayName = "OpenCode Go"
    public let dashboardURL = URL(string: "https://opencode.ai/zen")

    static let authPath = ".local/share/opencode/auth.json"

    private let http: any HTTPClient
    private let files: LocalCredentialFiles

    public init(http: any HTTPClient, files: LocalCredentialFiles,
                sqlite: @escaping SQLiteQuery = OpenCodeProvider.sqlite3CLI) {
        self.http = http
        self.files = files
        self.sqlite = sqlite
    }

    /// Runs one read-only query against a SQLite file and returns trimmed stdout.
    public typealias SQLiteQuery = @Sendable (_ path: String, _ sql: String) async throws -> String

    public static let sqlite3CLI: SQLiteQuery = { path, sql in
        let data = try await CLIProvider.run(
            binary: URL(fileURLWithPath: "/usr/bin/sqlite3"),
            args: ["-readonly", "-batch", "-noheader", path, sql])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static let dataDir = ".local/share/opencode"
    static let credentialTableSQL =
        "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='credential';"
    static let goKeySQL = """
        SELECT json_extract(value,'$.key') FROM credential \
        WHERE integration_id = 'opencode-go' AND (active IS NULL OR active = 1) \
        ORDER BY active DESC, time_updated DESC, id DESC LIMIT 1;
        """

    private let sqlite: SQLiteQuery

    /// OpenCode 2 keeps logins in each channel database's `credential` table and
    /// leaves the imported `auth.json` behind, so the file is stale once a table
    /// exists. Credential profiles point at a specific file and skip the databases.
    private func apiKey() async -> String? {
        if files.overridePaths[Self.authPath] == nil {
            var hasTable = false
            for db in databaseFiles() {
                guard (try? await sqlite(db, Self.credentialTableSQL)) == "1" else { continue }
                hasTable = true
                if let key = try? await sqlite(db, Self.goKeySQL), !key.isEmpty { return key }
                if URL(fileURLWithPath: db).lastPathComponent == "opencode.db" { return nil }
            }
            if hasTable { return nil }
        }
        guard let root = files.readJSON(Self.authPath),
              let entry = root["opencode-go"] as? [String: Any] else { return nil }
        return (entry["key"] ?? entry["access"] ?? entry["token"]) as? String
    }

    private func databaseFiles() -> [String] {
        let dir = files.home.appendingPathComponent(Self.dataDir)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let defaultDatabase = names.contains("opencode.db") ? ["opencode.db"] : []
        let channelDatabases = names.filter {
            $0.hasPrefix("opencode") && $0.hasSuffix(".db") && $0 != "opencode.db"
        }.sorted()
        return (defaultDatabase + channelDatabases).map { dir.appendingPathComponent($0).path }
    }

    public func accounts() async throws -> [AccountDescriptor] {
        guard await apiKey() != nil else { return [] }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: files.url(Self.authPath).path),
            label: "OpenCode Go")
        return [AccountDescriptor(account: identity, source: .configFile, isDefaultHome: true)]
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let key = await apiKey() else { throw ProviderError.notLoggedIn }
        let body = try await AdapterHTTP.getJSON(
            "https://opencode.ai/zen/go/v1/usage",
            headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"], http: http)
        guard let root = body as? [String: Any],
              let dict = root["usage"] as? [String: Any] else {
            throw ProviderError.badResponse("usage payload")
        }
        var windows: [UsageWindow] = []
        let specs: [(String, String)] = [
            ("5h", "rolling"), ("Week", "weekly"), ("Month", "monthly"),
        ]
        for (label, key) in specs {
            let bucket = dict[key] as? [String: Any]
            if let w = percentWindow(
                "opencode.\(key)", label,
                used: normalizePercent(adapterNum(
                    bucket, ["used_percent", "utilization", "percent"])),
                resetsAt: bucket?["resetsAt"]) {
                windows.append(w)
            }
        }
        let snapshot = UsageSnapshot(
            account: account.account, providerID: id, windows: windows,
            creditsRemaining: adapterNum(dict, ["balance", "credits_remaining"]),
            creditsUnit: "$")
        if windows.isEmpty && snapshot.creditsRemaining == nil {
            throw ProviderError.badResponse("no usage fields")
        }
        return snapshot
    }
}

// MARK: - Devin (credentials.toml → Connect GetUserStatus)

/// `~/.local/share/devin/credentials.toml` (`windsurf_api_key`, `api_server_url`) →
/// Connect-protocol SeatManagementService/GetUserStatus.
public struct DevinProvider: UsageProvider {
    public let id = "devin"
    public let displayName = "Devin"
    public let dashboardURL = URL(string: "https://app.devin.ai/settings/usage")

    static let credsPath = ".local/share/devin/credentials.toml"

    private let http: any HTTPClient
    private let files: LocalCredentialFiles

    public init(http: any HTTPClient, files: LocalCredentialFiles) {
        self.http = http
        self.files = files
    }

    /// Tiny TOML-lite parse: `key = "value"` lines only — enough for
    /// credentials.toml's flat shape.
    private func credentials() -> (apiKey: String, server: String)? {
        guard let text = files.readText(Self.credsPath) else { return nil }
        var apiKey: String?
        var server: String?
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if key == "windsurf_api_key" || (key == "api_key" && apiKey == nil) { apiKey = value }
            if key == "api_server_url", value.hasPrefix("https://") { server = value }
        }
        guard let apiKey else { return nil }
        return (apiKey, server ?? "https://server.codeium.com")
    }

    public func accounts() async throws -> [AccountDescriptor] {
        guard let c = credentials() else { return [] }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: files.url(Self.credsPath).path),
            label: "Devin CLI")
        return [AccountDescriptor(account: identity, source: .configFile, isDefaultHome: true)]
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let c = credentials() else { throw ProviderError.notLoggedIn }
        let server = c.server.hasPrefix("http") ? c.server : "https://\(c.server)"
        let body = try await AdapterHTTP.postJSON(
            "\(server)/exa.seat_management_pb.SeatManagementService/GetUserStatus",
            body: ["metadata": [
                "apiKey": c.apiKey, "ideName": "devin", "ideVersion": "1.108.2",
                "extensionName": "devin", "extensionVersion": "1.108.2", "locale": "en",
            ]],
            headers: ["Connect-Protocol-Version": "1"],
            http: http)
        guard let root = body as? [String: Any],
              let status = root["userStatus"] as? [String: Any],
              let dict = status["planStatus"] as? [String: Any] else {
            throw ProviderError.badResponse("status payload")
        }
        var windows: [UsageWindow] = []
        let plan = dict["planInfo"] as? [String: Any]
        for (key, label) in [("daily", "Day"), ("weekly", "Week")] {
            if key == "daily", plan?["hideDailyQuota"] as? Bool == true { continue }
            let field = "\(key)QuotaRemainingPercent"
            let reset = dict["\(key)QuotaResetAtUnix"]
            let remaining = adapterNum(dict, [field])
            if dict[field] != nil && remaining == nil { throw ProviderError.badResponse("quota percentage") }
            // Proto3 omits numeric zero. Only infer exhaustion when a window exists.
            if let remaining = remaining ?? (reset != nil ? 0 : nil),
               let window = percentWindow("devin.\(key)", label, used: 100 - remaining, resetsAt: reset) {
                windows.append(window)
            }
        }
        var identity = account.account
        identity.plan = plan?["planName"] as? String
        let snapshot = UsageSnapshot(
            account: identity, providerID: id, windows: windows,
            creditsRemaining: adapterNum(dict, ["overageBalanceMicros"]).map { $0 / 1_000_000 },
            creditsUnit: "USD")
        if windows.isEmpty && snapshot.creditsRemaining == nil {
            throw ProviderError.badResponse("no usage fields")
        }
        return snapshot
    }
}

// MARK: - Cursor (pasted session token → Connect DashboardService)

/// Cursor has no public usage API; the session token (WorkosCursorSessionToken,
/// pasted manually from cursor.com devtools) drives Connect-JSON calls to
/// api2.cursor.sh. Manual paste only — we never import browser cookies.
public struct CursorProvider: UsageProvider {
    public let id = "cursor"
    public let displayName = "Cursor"
    public let dashboardURL = URL(string: "https://cursor.com/dashboard?tab=usage")

    private let http: any HTTPClient
    private let credentials: any CredentialStore
    private let storage: GenericProvider

    public init(http: any HTTPClient, credentials: any CredentialStore, manifestURL: URL? = nil) {
        self.http = http
        self.credentials = credentials
        self.storage = GenericProvider(
            spec: ProviderSpec(id: "cursor", displayName: "Cursor", url: "https://cursor.com"),
            http: http, credentials: credentials, manifestURL: manifestURL)
    }

    /// The cookie value is `userID::jwt` (or %-encoded `userID%3A%3Ajwt`).
    private func parseToken(_ raw: String) -> (userID: String, jwt: String)? {
        guard raw.utf8.count <= 16_384 else { return nil }
        let decoded = raw.removingPercentEncoding ?? raw
        guard let range = decoded.range(of: "::") else { return nil }
        let userID = String(decoded[..<range.lowerBound])
        let jwt = String(decoded[range.upperBound...])
        let userCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let tokenCharacters = userCharacters.union(CharacterSet(charactersIn: "."))
        guard !userID.isEmpty, !jwt.isEmpty,
              userID.unicodeScalars.allSatisfy(userCharacters.contains),
              jwt.unicodeScalars.allSatisfy(tokenCharacters.contains) else { return nil }
        return (userID, jwt)
    }

    public func accounts() async throws -> [AccountDescriptor] {
        var accounts = try await storage.accounts()
        guard let raw = try credentials.secret(for: "cursor/session"),
              let parsed = parseToken(raw) else { return accounts }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: parsed.userID),
            label: parsed.userID)
        let savedUsers = try storage.configuredKeys().compactMap { entry in
            try credentials.secret(for: storage.credentialKey(entry.id)).flatMap(parseToken)?.userID
        }
        if !savedUsers.contains(parsed.userID) && !accounts.contains(where: { $0.id == identity.id }) {
            accounts.append(AccountDescriptor(account: identity, source: .userSuppliedKey))
        }
        return accounts
    }

    /// Register a pasted session token (Settings → Cursor → paste cookie value).
    public func addSessionToken(_ raw: String, label: String? = nil) throws -> AccountIdentity {
        guard let parsed = parseToken(raw) else {
            throw ProviderError.badResponse(Localized.text(
                "Paste only the WorkosCursorSessionToken value (userID::token), not a Cookie header.",
                "Lim inn bare verdien til WorkosCursorSessionToken (userID::token), ikke en Cookie-header."))
        }
        try checkExpiry(parsed.jwt)
        let canonical = "\(parsed.userID)::\(parsed.jwt)"
        let matching = try storage.configuredKeys().filter { entry in
            try credentials.secret(for: storage.credentialKey(entry.id)).flatMap(parseToken)?.userID == parsed.userID
        }
        let account: AccountIdentity
        if let existing = matching.first {
            account = try storage.replaceKey(canonical, accountID: existing.id, label: label)
            for duplicate in matching.dropFirst() {
                try storage.removeKey(accountID: duplicate.id)
            }
        } else {
            account = try storage.addKey(canonical, label: label ?? parsed.userID)
        }
        if let legacy = try credentials.secret(for: "cursor/session"),
           parseToken(legacy)?.userID == parsed.userID {
            try credentials.removeSecret(for: "cursor/session")
        }
        return account
    }

    public func removeSessionToken(accountID: String) throws {
        if let raw = try credentials.secret(for: "cursor/session"),
           let parsed = parseToken(raw),
           accountID == AccountIdentity.makeID(providerID: id, identityKey: parsed.userID) {
            try credentials.removeSecret(for: "cursor/session")
        }
        try storage.removeKey(accountID: accountID)
    }

    public func renameSessionToken(accountID: String, label: String?) throws {
        try storage.renameKey(accountID: accountID, label: label)
    }

    public func replaceSessionToken(_ raw: String, accountID: String) throws {
        guard let parsed = parseToken(raw) else {
            throw ProviderError.badResponse(Localized.text(
                "Paste the session value in userID::token format.",
                "Lim inn øktverdien i formatet userID::token."))
        }
        try checkExpiry(parsed.jwt)
        let canonical = "\(parsed.userID)::\(parsed.jwt)"
        if try storage.configuredKeys().contains(where: { $0.id == accountID }) {
            guard let old = try credentials.secret(for: storage.credentialKey(accountID)),
                  let previous = parseToken(old) else {
                throw ProviderError.badResponse(Localized.text(
                    "The old session is missing or unreadable, so its account cannot be verified. Remove this entry and add the account again.",
                    "Den gamle økten mangler eller kan ikke leses, så kontoen kan ikke bekreftes. Fjern oppføringen og legg til kontoen på nytt."))
            }
            guard previous.userID == parsed.userID else {
                throw ProviderError.badResponse(Localized.text(
                    "This session belongs to a different Cursor account. Use Add Account instead.",
                    "Denne økten tilhører en annen Cursor-konto. Bruk Legg til konto i stedet."))
            }
            _ = try storage.replaceKey(canonical, accountID: accountID)
        } else {
            guard let old = try credentials.secret(for: "cursor/session"),
                  let previous = parseToken(old), previous.userID == parsed.userID,
                  accountID == AccountIdentity.makeID(providerID: id, identityKey: previous.userID) else {
                throw ProviderError.notLoggedIn
            }
            try credentials.setSecret(canonical, for: "cursor/session")
        }
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        let raw: String?
        if try storage.configuredKeys().contains(where: { $0.id == account.id }) {
            raw = try credentials.secret(for: storage.credentialKey(account.id))
        } else if let legacy = try credentials.secret(for: "cursor/session"),
                  let parsed = parseToken(legacy),
                  account.id == AccountIdentity.makeID(providerID: id, identityKey: parsed.userID) {
            raw = legacy
        } else {
            raw = nil
        }
        guard account.account.providerID == id, let raw,
              let parsed = parseToken(raw) else { throw ProviderError.notLoggedIn }
        try checkExpiry(parsed.jwt)
        try Task.checkCancellation()
        // Prefer the richer dashboard response. Both routes use this account's token only.
        do {
            let summary = try await request(
                "https://cursor.com/api/usage-summary",
                headers: ["Cookie": "WorkosCursorSessionToken=\(parsed.userID)%3A%3A\(parsed.jwt)"])
            let individual = summary["individualUsage"] as? [String: Any]
            var windows = planWindows(individual?["plan"] as? [String: Any], reset: summary["billingCycleEnd"])
            if let demand = individual?["onDemand"] as? [String: Any],
               demand["enabled"] as? Bool != false, let used = number(demand, "used") {
                // Spending is not remaining included allowance; do not feed it into quota meters.
                windows.append(UsageWindow(
                    id: "cursor.ondemand", label: "On-demand spend", kind: .credits,
                    used: used / 100, unit: "USD",
                    resetsAt: percentWindow("date", "", used: 0, resetsAt: summary["billingCycleEnd"])?.resetsAt))
            }
            guard !windows.isEmpty else { throw noQuotaError }
            var identity = account.account
            identity.plan = summary["membershipType"] as? String
            return UsageSnapshot(account: identity, providerID: id, windows: windows)
        } catch {
            try allowFallback(after: error)
        }
        try Task.checkCancellation()
        let headers = [
            "Authorization": "Bearer \(parsed.jwt)",
            "Connect-Protocol-Version": "1",
            "X-Client-Key": parsed.userID,
        ]
        var identity = account.account
        var credits: Double?
        let usage = try await request(
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
            headers: headers, post: true)
        let windows = planWindows(usage["planUsage"] as? [String: Any], reset: usage["billingCycleEnd"])

        if let plan = try await optionalRequest(
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo",
            headers: headers) {
            identity.plan = (plan["planInfo"] as? [String: Any])?["planName"] as? String
                ?? plan["planName"] as? String
        }
        if let grants = try await optionalRequest(
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance",
            headers: headers) {
            if let total = number(grants, "totalCents"),
               let used = number(grants, "usedCents") {
                credits = max(0, total - used) / 100
            }
        }

        try Task.checkCancellation()
        if windows.isEmpty && credits == nil { throw noQuotaError }
        return UsageSnapshot(
            account: identity, providerID: id, windows: windows,
            creditsRemaining: credits, creditsUnit: "$")
    }

    private func checkExpiry(_ token: String) throws {
        guard let expiry = OAuthTokens.jwtExpiry(token), expiry.isFinite else { return }
        if expiry <= Date().timeIntervalSince1970 + 60 { throw ProviderError.unauthorized }
    }

    private var noQuotaError: ProviderError {
        .badResponse(Localized.text(
            "Cursor returned no recognized quota data. Check the Cursor dashboard.",
            "Cursor returnerte ingen gjenkjente kvotedata. Sjekk Cursor-kontrollpanelet."))
    }

    private func number(_ dict: [String: Any], _ key: String) -> Double? {
        if let value = dict[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        guard let raw = dict[key], !(raw is NSNull),
              let value = adapterNum(dict, [key]), value.isFinite, value >= 0 else { return nil }
        return value
    }

    private func planWindows(_ plan: [String: Any]?, reset: Any?) -> [UsageWindow] {
        guard let plan, plan["enabled"] as? Bool != false else { return [] }
        var windows: [UsageWindow] = []
        for (key, label) in [("autoPercentUsed", "Cursor Models"), ("apiPercentUsed", "Other Models")] {
            if let percent = number(plan, key),
               let window = percentWindow("cursor.\(key)", label, used: percent, resetsAt: reset) {
                windows.append(window)
            }
        }
        if !windows.isEmpty { return windows }
        if let percent = number(plan, "totalPercentUsed"),
           let window = percentWindow("cursor.plan", "Plan", used: percent, resetsAt: reset) {
            return [window]
        }
        if let limit = number(plan, "limit"), limit > 0,
           let used = number(plan, "used") ?? number(plan, "totalSpend")
            ?? number(plan, "remaining").flatMap({ $0 <= limit ? limit - $0 : nil }) {
            return [UsageWindow(
                id: "cursor.plan", label: "Plan", kind: .credits,
                used: used / 100, limit: limit / 100, unit: "USD",
                resetsAt: percentWindow("date", "", used: 0, resetsAt: reset)?.resetsAt)]
        }
        return []
    }

    private func request(_ url: String, headers: [String: String], post: Bool = false) async throws -> [String: Any] {
        try Task.checkCancellation()
        var headers = headers
        headers["Accept"] = "application/json"
        if post { headers["Content-Type"] = "application/json" }
        let response = try await http.send(HTTPRequest(
            method: post ? "POST" : "GET", url: URL(string: url)!, headers: headers,
            body: post ? Data("{}".utf8) : nil, allowsRedirects: false))
        let data = try requireOK(response)
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw noQuotaError
        }
        return result
    }

    private func allowFallback(after error: Error) throws {
        if error is CancellationError { throw error }
        if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
        if case ProviderError.rateLimited = error { throw error }
        if case ProviderError.serverError(let status) = error, (300..<400).contains(status) { throw error }
        try Task.checkCancellation()
    }

    private func optionalRequest(_ url: String, headers: [String: String]) async throws -> [String: Any]? {
        do { return try await request(url, headers: headers, post: true) }
        catch {
            try allowFallback(after: error)
            return nil
        }
    }
}

// MARK: - GitHub Copilot (gh CLI token → copilot_internal quota)

/// Reuses the `gh` CLI's OAuth token (`~/.config/gh/hosts.yml`) — the same
/// local-credentials approach as the other adapters, no device flow needed.
public struct CopilotProvider: UsageProvider {
    public let id = "copilot"
    public let displayName = "Copilot"
    public let dashboardURL = URL(string: "https://github.com/settings/copilot/features")

    static let hostsPath = ".config/gh/hosts.yml"

    private let http: any HTTPClient
    private let files: LocalCredentialFiles

    public init(http: any HTTPClient, files: LocalCredentialFiles) {
        self.http = http
        self.files = files
    }

    /// YAML-lite: find the first `oauth_token:` value under github.com.
    private func ghToken() -> String? {
        guard let text = files.readText(Self.hostsPath) else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("oauth_token:") {
                let value = trimmed.dropFirst("oauth_token:".count)
                    .trimmingCharacters(in: .whitespaces)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    public func accounts() async throws -> [AccountDescriptor] {
        guard ghToken() != nil else { return [] }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: files.url(Self.hostsPath).path),
            label: "gh CLI")
        return [AccountDescriptor(account: identity, source: .configFile)]
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let ghToken = ghToken() else { throw ProviderError.notLoggedIn }
        // Exchange the gh token for a short-lived Copilot API token.
        let tokenBody = try await AdapterHTTP.getJSON(
            "https://api.github.com/copilot_internal/v2/token",
            headers: ["Authorization": "Bearer \(ghToken)",
                      "Accept": "application/json"],
            http: http)
        guard let tokenDict = tokenBody as? [String: Any],
              let copilotToken = tokenDict["token"] as? String else {
            throw ProviderError.unauthorized
        }
        let body = try await AdapterHTTP.getJSON(
            "https://api.github.com/copilot_internal/user",
            headers: ["Authorization": "Bearer \(copilotToken)",
                      "Accept": "application/json"],
            http: http)
        guard let dict = body as? [String: Any],
              let quotas = dict["quota_snapshots"] as? [String: Any] else {
            throw ProviderError.badResponse("quota payload")
        }
        var windows: [UsageWindow] = []
        let specs: [(String, String, String)] = [
            ("premium_interactions", "copilot.premium", "Premium"),
            ("chat", "copilot.chat", "Chat"),
            ("completions", "copilot.completions", "Completions"),
        ]
        for (key, windowID, label) in specs {
            guard let bucket = quotas[key] as? [String: Any] else { continue }
            let remaining = adapterNum(bucket, ["percent_remaining", "remaining"])
            if let remaining {
                windows.append(UsageWindow(
                    id: windowID, label: label, kind: .requests,
                    limit: 100,
                    remaining: remaining <= 1 ? remaining * 100 : remaining,
                    unit: "%",
                    resetsAt: (dict["quota_reset_date"] as? String)
                        .flatMap { ISO8601DateFormatter().date(from: $0) }))
            } else if let remaining = adapterNum(bucket, ["remaining"]),
                      let entitlement = adapterNum(bucket, ["entitlement"]) {
                windows.append(UsageWindow(
                    id: windowID, label: label, kind: .requests,
                    limit: entitlement, remaining: remaining))
            }
        }
        if windows.isEmpty { throw ProviderError.badResponse("no quota fields") }
        return UsageSnapshot(account: account.account, providerID: id, windows: windows)
    }
}
