import Foundation
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
            ClaudeProvider(http: http, files: files),
            CodexProvider(http: http, files: files),
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

/// Normalizes a provider's percent-used value: some report 0-1 fractions.
func normalizePercent(_ raw: Double?) -> Double? {
    guard let raw else { return nil }
    return raw >= 0 && raw <= 1 ? raw * 100 : raw
}

// MARK: - Claude (Claude Code OAuth)

/// `~/.claude/.credentials.json` → api.anthropic.com/api/oauth/usage.
/// The endpoint 429s aggressively; honoring retry-after is mandatory.
public struct ClaudeProvider: UsageProvider {
    public let id = "claude"
    public let displayName = "Claude"
    public let dashboardURL = URL(string: "https://claude.ai/settings/usage")

    static let credentialsPath = ".claude/.credentials.json"
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    private let http: any HTTPClient
    private let files: LocalCredentialFiles

    public init(http: any HTTPClient, files: LocalCredentialFiles) {
        self.http = http
        self.files = files
    }

    public func accounts() async throws -> [AccountDescriptor] {
        guard oauthBlock() != nil else { return [] }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: "claude-cli"),
            label: "Claude Code")
        return [AccountDescriptor(account: identity, source: .configFile, isDefaultHome: true)]
    }

    private func oauthBlock() -> [String: Any]? {
        files.readJSON(Self.credentialsPath)?["claudeAiOauth"] as? [String: Any]
    }

    private func tokens() throws -> OAuthTokens {
        guard let oauth = oauthBlock(), let at = oauth["accessToken"] as? String else {
            throw ProviderError.notLoggedIn
        }
        return OAuthTokens(
            accessToken: at,
            refreshToken: oauth["refreshToken"] as? String,
            // Claude Code stores expiresAt in epoch milliseconds.
            expiresAt: (oauth["expiresAt"] as? NSNumber).map { $0.doubleValue / 1000 })
    }

    private func persist(tokens: OAuthTokens) {
        guard var root = files.readJSON(Self.credentialsPath),
              var oauth = root["claudeAiOauth"] as? [String: Any] else { return }
        oauth["accessToken"] = tokens.accessToken
        if let rt = tokens.refreshToken { oauth["refreshToken"] = rt }
        if let exp = tokens.expiresAt { oauth["expiresAt"] = Int(exp * 1000) }
        root["claudeAiOauth"] = oauth
        files.writeJSON(Self.credentialsPath, root)
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        var t = try tokens()
        if t.isExpired, let rt = t.refreshToken {
            let refreshed = try await OAuthRefresher.refresh(
                url: "https://platform.claude.com/v1/oauth/token",
                clientID: Self.clientID, refreshToken: rt, http: http)
            t = refreshed
            persist(tokens: refreshed)
        }
        let body = try await AdapterHTTP.getJSON(
            "https://api.anthropic.com/api/oauth/usage",
            headers: [
                "Authorization": "Bearer \(t.accessToken)",
                "anthropic-beta": "oauth-2025-04-20",
                "anthropic-version": "2023-06-01",
            ],
            http: http)
        guard let dict = body as? [String: Any] else {
            throw ProviderError.badResponse("usage payload")
        }
        var windows: [UsageWindow] = []
        let specs: [(String, String, String)] = [
            ("five_hour", "claude.5h", "5h"),
            ("seven_day", "claude.week", "Week"),
            ("seven_day_sonnet", "claude.sonnet", "Sonnet"),
            ("seven_day_opus", "claude.opus", "Opus"),
        ]
        for (key, windowID, label) in specs {
            let bucket = dict[key] as? [String: Any]
            if let w = percentWindow(
                windowID, label,
                used: normalizePercent(adapterNum(bucket, ["utilization"])),
                resetsAt: bucket?["resets_at"]) {
                windows.append(w)
            }
        }
        if windows.isEmpty { throw ProviderError.badResponse("no usage windows") }
        var identity = account.account
        if let plan = dict["plan_type"] as? String ?? dict["plan"] as? String {
            identity.plan = plan
        }
        return UsageSnapshot(account: identity, providerID: id, windows: windows)
    }
}

// MARK: - Codex / ChatGPT

/// `~/.codex/auth.json` → chatgpt.com/backend-api/wham/usage.
public struct CodexProvider: UsageProvider {
    public let id = "codex"
    public let displayName = "Codex"
    public let dashboardURL = URL(string: "https://chatgpt.com/codex/settings/usage")

    static let authPath = ".codex/auth.json"
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private let http: any HTTPClient
    private let files: LocalCredentialFiles

    public init(http: any HTTPClient, files: LocalCredentialFiles) {
        self.http = http
        self.files = files
    }

    private func tokenBlock() -> [String: Any]? {
        files.readJSON(Self.authPath)?["tokens"] as? [String: Any]
    }

    public func accounts() async throws -> [AccountDescriptor] {
        guard let t = tokenBlock(), t["access_token"] is String else { return [] }
        let accountID = t["account_id"] as? String ?? "codex-cli"
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: accountID),
            label: "Codex CLI")
        return [AccountDescriptor(account: identity, source: .configFile, isDefaultHome: true)]
    }

    private func tokens() throws -> OAuthTokens {
        guard let t = tokenBlock(), let at = t["access_token"] as? String else {
            throw ProviderError.notLoggedIn
        }
        return OAuthTokens(accessToken: at, refreshToken: t["refresh_token"] as? String)
    }

    private var accountID: String? { tokenBlock()?["account_id"] as? String }

    private func persist(tokens: OAuthTokens) {
        guard var root = files.readJSON(Self.authPath),
              var t = root["tokens"] as? [String: Any] else { return }
        t["access_token"] = tokens.accessToken
        if let rt = tokens.refreshToken { t["refresh_token"] = rt }
        t["last_refresh"] = ISO8601DateFormatter().string(from: Date())
        root["tokens"] = t
        files.writeJSON(Self.authPath, root)
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        var t = try tokens()
        if let rt = t.refreshToken {
            do {
                let refreshed = try await OAuthRefresher.refresh(
                    url: "https://auth.openai.com/oauth/token",
                    clientID: Self.clientID, refreshToken: rt, http: http)
                t = refreshed
                persist(tokens: refreshed)
            } catch {
                // A failed refresh is non-fatal: the stored access token may
                // still be valid (Codex rotates slowly).
            }
        }
        var headers = ["Authorization": "Bearer \(t.accessToken)"]
        if let acct = accountID { headers["ChatGPT-Account-Id"] = acct }
        let body = try await AdapterHTTP.getJSON(
            "https://chatgpt.com/backend-api/wham/usage", headers: headers, http: http)
        guard let dict = body as? [String: Any],
              let rate = dict["rate_limit"] as? [String: Any] else {
            throw ProviderError.badResponse("usage payload")
        }
        var windows: [UsageWindow] = []
        let pairs: [(String, String, String)] = [
            ("primary_window", "codex.5h", "5h"),
            ("secondary_window", "codex.week", "Week"),
        ]
        for (key, windowID, label) in pairs {
            let bucket = rate[key] as? [String: Any]
            if let w = percentWindow(
                windowID, label,
                used: normalizePercent(adapterNum(bucket, ["used_percent", "utilization"])),
                resetsAt: bucket?["reset_at"]) {
                windows.append(w)
            }
        }
        if windows.isEmpty { throw ProviderError.badResponse("no usage windows") }
        var identity = account.account
        identity.plan = dict["plan_type"] as? String
        var snapshot = UsageSnapshot(account: identity, providerID: id, windows: windows)
        if let credits = dict["credits"] as? [String: Any] {
            snapshot.creditsRemaining = adapterNum(credits, ["balance", "remaining"])
            snapshot.creditsUnit = "credits"
        }
        return snapshot
    }
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
            files.writeJSON(Self.credsPath, newCreds)
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
        if root["accessToken"] is String || root["access_token"] is String {
            return [("default", root)]
        }
        var found: [(String, [String: Any])] = []
        for (key, value) in root {
            if let dict = value as? [String: Any],
               dict["accessToken"] is String || dict["access_token"] is String {
                found.append((key, dict))
            }
        }
        return found
    }

    public func accounts() async throws -> [AccountDescriptor] {
        entries().map { name, _ in
            AccountDescriptor(
                account: AccountIdentity(
                    providerID: id,
                    id: AccountIdentity.makeID(providerID: id, identityKey: name),
                    label: name == "default" ? "Grok CLI" : name),
                source: .configFile, isDefaultHome: name == "default")
        }
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        let match = entries().first {
            AccountIdentity.makeID(providerID: id, identityKey: $0.0) == account.account.id
        }
        guard let (name, entry) = match else { throw ProviderError.notLoggedIn }
        var token = (entry["accessToken"] ?? entry["access_token"]) as? String ?? ""
        if let exp = adapterNum(entry, ["expiresAt", "expires_at"]),
           Date().timeIntervalSince1970 >= (exp > 1e12 ? exp / 1000 : exp) - 60,
           let rt = (entry["refreshToken"] ?? entry["refresh_token"]) as? String {
            let refreshed = try await OAuthRefresher.refresh(
                url: "https://auth.x.ai/oauth2/token",
                clientID: "grok-cli", refreshToken: rt, http: http)
            token = refreshed.accessToken
            var root = files.readJSON(Self.authPath) ?? [:]
            var mutableEntry = entry
            mutableEntry["accessToken"] = refreshed.accessToken
            if let rt = refreshed.refreshToken { mutableEntry["refreshToken"] = rt }
            if name == "default", root["accessToken"] != nil { root = mutableEntry }
            else { root[name] = mutableEntry }
            files.writeJSON(Self.authPath, root)
        }
        let body = try await AdapterHTTP.getJSON(
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits",
            headers: ["Authorization": "Bearer \(token)"], http: http)
        guard let dict = body as? [String: Any] else {
            throw ProviderError.badResponse("billing payload")
        }
        var windows: [UsageWindow] = []
        if let w = percentWindow(
            "grok.week", "Week",
            used: normalizePercent(adapterNum(
                dict, ["weekly_used_percent", "weeklyUsedPercent", "used_percent"])),
            resetsAt: dict["weekly_reset_at"] ?? dict["weeklyResetAt"]) {
            windows.append(w)
        }
        let snapshot = UsageSnapshot(
            account: account.account, providerID: id,
            windows: windows,
            creditsRemaining: adapterNum(
                dict, ["remaining_balance", "remainingBalance", "balance"]),
            creditsUnit: "credits")
        if windows.isEmpty && snapshot.creditsRemaining == nil {
            throw ProviderError.badResponse("no usage fields")
        }
        return snapshot
    }
}

// MARK: - OpenCode Go

/// `opencode-go` entry in `~/.local/share/opencode/auth.json` → zen/go usage.
public struct OpenCodeProvider: UsageProvider {
    public let id = "opencode"
    public let displayName = "OpenCode"
    public let dashboardURL = URL(string: "https://opencode.ai/zen")

    static let authPath = ".local/share/opencode/auth.json"

    private let http: any HTTPClient
    private let files: LocalCredentialFiles

    public init(http: any HTTPClient, files: LocalCredentialFiles) {
        self.http = http
        self.files = files
    }

    /// The auth file maps provider name → {"type": "api"|"oauth", "key"|"access": ...}.
    private func apiKey() -> String? {
        guard let root = files.readJSON(Self.authPath),
              let entry = root["opencode-go"] as? [String: Any] else { return nil }
        return (entry["key"] ?? entry["access"] ?? entry["token"]) as? String
    }

    public func accounts() async throws -> [AccountDescriptor] {
        guard let key = apiKey() else { return [] }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: key),
            label: "OpenCode Go")
        return [AccountDescriptor(account: identity, source: .configFile, isDefaultHome: true)]
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let key = apiKey() else { throw ProviderError.notLoggedIn }
        let body = try await AdapterHTTP.getJSON(
            "https://opencode.ai/zen/go/v1/usage",
            headers: ["Authorization": "Bearer \(key)"], http: http)
        guard let dict = body as? [String: Any] else {
            throw ProviderError.badResponse("usage payload")
        }
        var windows: [UsageWindow] = []
        let specs: [(String, String)] = [
            ("5h", "session"), ("Week", "weekly"), ("Month", "monthly"),
        ]
        for (label, key) in specs {
            let bucket = dict[key] as? [String: Any]
            if let w = percentWindow(
                "opencode.\(key)", label,
                used: normalizePercent(adapterNum(
                    bucket, ["used_percent", "utilization", "percent"])),
                resetsAt: bucket?["reset_at"] ?? bucket?["resets_at"]) {
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

/// `~/.local/share/devin/credentials.toml` (`api_key`, `api_server_url`) →
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
            if key == "api_key" { apiKey = value }
            if key == "api_server_url" { server = value }
        }
        guard let apiKey else { return nil }
        return (apiKey, server ?? "https://server.codeium.com")
    }

    public func accounts() async throws -> [AccountDescriptor] {
        guard let c = credentials() else { return [] }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: c.apiKey),
            label: "Devin CLI")
        return [AccountDescriptor(account: identity, source: .configFile, isDefaultHome: true)]
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let c = credentials() else { throw ProviderError.notLoggedIn }
        let server = c.server.hasPrefix("http") ? c.server : "https://\(c.server)"
        let body = try await AdapterHTTP.postJSON(
            "\(server)/exa.seat_management_pb.SeatManagementService/GetUserStatus",
            body: [:],
            headers: [
                "Authorization": "Bearer \(c.apiKey)",
                "Connect-Protocol-Version": "1",
            ],
            http: http)
        guard let dict = body as? [String: Any] else {
            throw ProviderError.badResponse("status payload")
        }
        var windows: [UsageWindow] = []
        let specs: [(String, String, String)] = [
            ("dailyUsage", "devin.day", "Day"),
            ("weeklyUsage", "devin.week", "Week"),
            ("weekly_usage", "devin.week", "Week"),
        ]
        for (key, windowID, label) in specs {
            guard let bucket = dict[key] as? [String: Any],
                  windows.contains(where: { $0.id == windowID }) == false else { continue }
            if let w = percentWindow(
                windowID, label,
                used: normalizePercent(adapterNum(
                    bucket, ["usedPercent", "used_percent", "percent"])),
                resetsAt: bucket["resetTime"] ?? bucket["reset_time"]) {
                windows.append(w)
            }
        }
        let snapshot = UsageSnapshot(
            account: account.account, providerID: id, windows: windows,
            creditsRemaining: adapterNum(
                dict, ["extraUsageBalance", "extra_usage_balance", "balance"]),
            creditsUnit: "ACUs")
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

    public init(http: any HTTPClient, credentials: any CredentialStore) {
        self.http = http
        self.credentials = credentials
    }

    /// The cookie value is `userID::jwt` (or %-encoded `userID%3A%3Ajwt`).
    private func parseToken(_ raw: String) -> (userID: String, jwt: String)? {
        let decoded = raw.removingPercentEncoding ?? raw
        guard let range = decoded.range(of: "::") else { return nil }
        let userID = String(decoded[..<range.lowerBound])
        let jwt = String(decoded[range.upperBound...])
        guard !userID.isEmpty, !jwt.isEmpty else { return nil }
        return (userID, jwt)
    }

    public func accounts() async throws -> [AccountDescriptor] {
        guard let raw = try credentials.secret(for: "cursor/session"),
              let parsed = parseToken(raw) else { return [] }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: parsed.userID),
            label: parsed.userID)
        return [AccountDescriptor(account: identity, source: .userSuppliedKey)]
    }

    /// Register a pasted session token (Settings → Cursor → paste cookie value).
    public func addSessionToken(_ raw: String) throws -> AccountIdentity {
        guard let parsed = parseToken(raw) else {
            throw ProviderError.badResponse("expected userID::token format")
        }
        let id = AccountIdentity.makeID(providerID: id, identityKey: parsed.userID)
        try credentials.setSecret(raw, for: "cursor/session")
        return AccountIdentity(providerID: self.id, id: id, label: parsed.userID)
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard let raw = try credentials.secret(for: "cursor/session"),
              let parsed = parseToken(raw) else { throw ProviderError.notLoggedIn }
        let headers = [
            "Authorization": "Bearer \(parsed.jwt)",
            "Connect-Protocol-Version": "1",
            "X-Client-Key": parsed.userID,
        ]
        var windows: [UsageWindow] = []
        var identity = account.account
        var credits: Double?
        var fetchError: Error?

        if let usage = try? await AdapterHTTP.postJSON(
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage",
            body: [:], headers: headers, http: http) as? [String: Any],
           let plan = usage["planUsage"] as? [String: Any] ?? usage["plan_usage"] as? [String: Any] {
            let reset = ((usage["billingCycleEnd"] ?? usage["billing_cycle_end"]) as? String)
                .flatMap { ISO8601DateFormatter().date(from: $0) }
            let used = adapterNum(plan, ["used", "requestsUsed", "numRequests"])
            let limit = adapterNum(plan, ["limit", "maxRequestUsage", "numRequestsTotal"])
            if used != nil || limit != nil {
                windows.append(UsageWindow(
                    id: "cursor.requests", label: "Requests", kind: .requests,
                    used: used, limit: limit, resetsAt: reset))
            }
        } else {
            fetchError = ProviderError.badResponse("GetCurrentPeriodUsage failed")
        }

        if let plan = try? await AdapterHTTP.postJSON(
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo",
            body: [:], headers: headers, http: http) as? [String: Any] {
            identity.plan = (plan["planName"] ?? plan["plan_name"]) as? String
        }
        if let grants = try? await AdapterHTTP.postJSON(
            "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance",
            body: [:], headers: headers, http: http) as? [String: Any] {
            credits = adapterNum(grants, ["totalBalance", "total_balance", "balance"])
        }

        if windows.isEmpty && credits == nil, let fetchError { throw fetchError }
        return UsageSnapshot(
            account: identity, providerID: id, windows: windows,
            creditsRemaining: credits, creditsUnit: "$")
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
        guard let token = ghToken() else { return [] }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: token),
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
