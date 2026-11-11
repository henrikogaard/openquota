import Foundation

/// OpenCode Console sign-in: workspaces, Go limits and spend budgets.
///
/// Uses the device sign-in the OpenCode CLI itself uses (`opencode-cli`) and
/// the same console routes it calls. None of them is a documented public API.
/// OpenQuota keeps its own session, separate from the CLI's, so refreshing it
/// never signs the CLI out.
///
/// 1. `POST /console/auth/device/code`, then `POST /console/auth/device/token`
///    until the user approves the code in the browser.
/// 2. `GET /console/api/user` and `/console/api/orgs`: email and workspaces.
/// 3. Per workspace: `GET /zen/go/v1/usage` (Go limits; 403 = no Go) and
///    `GET /console/api/policies/current-budgets` (403 = none).
public struct OpenCodeConsoleProvider: UsageProvider {
    public let id = "opencode-console"
    public let displayName = "OpenCode"
    public let dashboardURL = URL(string: "https://opencode.ai/console")

    static let server = "https://opencode.ai/console"
    static let host = "opencode.ai"
    static let goUsageURL = "https://opencode.ai/zen/go/v1/usage"
    static let clientID = "opencode-cli"
    static let userAgent = "OpenQuota"

    struct Workspace: Codable, Equatable, Sendable {
        var id: String
        var name: String
        /// A name the user gave this card in Settings.
        var label: String?
    }

    /// One sign-in, saved as JSON in the credential store.
    struct Session: Codable, Equatable, Sendable {
        var access: String
        var refresh: String
        /// Epoch seconds.
        var expiresAt: TimeInterval
        var userID: String
        var email: String
        /// The workspace the sign-in was limited to, when OpenCode limited it.
        var scopedWorkspaceID: String?
        var workspaces: [Workspace]
    }

    /// A started sign-in: the code to show and the page to open.
    public struct DeviceLogin: Sendable, Equatable {
        public let userCode: String
        public let verificationURL: URL
        let deviceCode: String
        let interval: TimeInterval
        let expiresAt: Date
    }

    private let http: any HTTPClient
    private let credentials: any CredentialStore
    private let storage: GenericProvider
    private let gate = SessionGate()
    /// Held around every read-then-write of a saved session, never across a
    /// network call, so a rename, removal or new sign-in cannot undo a
    /// renewed token and a renewal cannot bring back a removed session.
    private let sessionLock = NSLock()

    public init(http: any HTTPClient, credentials: any CredentialStore, manifestURL: URL? = nil) {
        self.http = http
        self.credentials = credentials
        self.storage = GenericProvider(
            spec: ProviderSpec(id: "opencode-console", displayName: "OpenCode", url: Self.server),
            http: http, credentials: credentials, manifestURL: manifestURL)
    }

    // MARK: Accounts

    /// One card per workspace of each saved sign-in. Local only.
    public func accounts() async throws -> [AccountDescriptor] {
        try storage.configuredKeys().flatMap { entry -> [AccountDescriptor] in
            guard let session = try storedSession(entry.id) else {
                // A saved sign-in that can no longer be read still gets a
                // card, so it can be seen and removed.
                return [AccountDescriptor(
                    account: AccountIdentity(providerID: id, id: Self.accountID(entry.id, ""), label: entry.label),
                    source: .userSuppliedKey)]
            }
            return session.workspaces.map { workspace in
                AccountDescriptor(
                    account: AccountIdentity(
                        providerID: id, id: Self.accountID(entry.id, workspace.id),
                        label: workspace.label ?? workspace.name, email: session.email),
                    source: .userSuppliedKey)
            }
        }
    }

    /// Removes one workspace card; the sign-in goes with its last workspace.
    public func remove(accountID: String) throws {
        guard let (entryID, workspaceID) = Self.split(accountID) else { return }
        try sessionLock.withLock {
            var session = try storedSession(entryID)
            session?.workspaces.removeAll { $0.id == workspaceID }
            if let session, !session.workspaces.isEmpty {
                try save(session, entryID: entryID)
            } else {
                try storage.removeKey(accountID: entryID)
            }
        }
    }

    /// An empty name goes back to the workspace's own name.
    public func rename(accountID: String, label: String?) throws {
        guard let (entryID, workspaceID) = Self.split(accountID) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        try sessionLock.withLock {
            guard var session = try storedSession(entryID),
                  let index = session.workspaces.firstIndex(where: { $0.id == workspaceID }) else { return }
            session.workspaces[index].label = trimmed?.isEmpty == false ? trimmed : nil
            try save(session, entryID: entryID)
        }
    }

    static func accountID(_ entryID: String, _ workspaceID: String) -> String { "\(entryID)#\(workspaceID)" }

    static func split(_ accountID: String) -> (entryID: String, workspaceID: String)? {
        guard let mark = accountID.firstIndex(of: "#") else { return nil }
        return (String(accountID[..<mark]), String(accountID[accountID.index(after: mark)...]))
    }

    // MARK: Sign-in

    /// Asks OpenCode for a sign-in code. Nothing is saved yet.
    public func beginSignIn(now: Date = Date()) async throws -> DeviceLogin {
        let json = try await postJSON(
            "\(Self.server)/auth/device/code",
            ["client_id": Self.clientID, "supports_org_scope": true])
        guard let deviceCode = json["device_code"] as? String, !deviceCode.isEmpty,
              let userCode = json["user_code"] as? String, !userCode.isEmpty,
              let page = json["verification_uri_complete"] as? String,
              let url = URL(string: page, relativeTo: URL(string: Self.server + "/"))?.absoluteURL,
              url.scheme == "https", url.host == Self.host, url.port == nil, url.user == nil else {
            throw ProviderError.badResponse("sign-in code")
        }
        let interval = min(max(adapterNum(json, ["interval"]) ?? 5, 1), 30)
        let lifetime = min(max(adapterNum(json, ["expires_in"]) ?? 600, 30), 1800)
        return DeviceLogin(
            userCode: userCode, verificationURL: url, deviceCode: deviceCode,
            interval: interval, expiresAt: now.addingTimeInterval(lifetime))
    }

    /// Waits until the code is approved in the browser, then saves the sign-in
    /// and returns one account per workspace. Cancel the task to stop waiting.
    public func completeSignIn(
        _ login: DeviceLogin,
        now: @Sendable () -> Date = { Date() },
        sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    ) async throws -> [AccountIdentity] {
        var wait = login.interval
        while now() < login.expiresAt {
            try await sleep(wait)
            try Task.checkCancellation()
            let status: Int
            let json: [String: Any]
            do {
                (status, json) = try await post(
                    "\(Self.server)/auth/device/token",
                    ["grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                     "device_code": login.deviceCode, "client_id": Self.clientID])
            } catch let error as ProviderError {
                // A dropped connection mid-wait is not the end of the sign-in.
                guard case .network = error else { throw error }
                wait = min(wait + 5, 30)
                continue
            }
            if let token = Token(json) {
                return try await finishSignIn(token, now: now())
            }
            switch json["error"] as? String {
            case "authorization_pending": continue
            case "slow_down": wait = min(wait + 5, 30)
            case "access_denied":
                throw ProviderError.badResponse(Localized.text(
                    "The sign-in was declined in the browser.", "Påloggingen ble avvist i nettleseren."))
            case "expired_token": throw ProviderError.timedOut
            default:
                // Busy or briefly failing: keep waiting until the code expires.
                guard status == 429 || status >= 500 else { throw ProviderError.badResponse("sign-in") }
                wait = min(wait + 5, 30)
            }
        }
        throw ProviderError.timedOut
    }

    private func finishSignIn(_ token: Token, now: Date) async throws -> [AccountIdentity] {
        async let userJSON = get("\(Self.server)/api/user", token: token.access)
        async let orgsJSON = get("\(Self.server)/api/orgs", token: token.access)
        guard let user = try await userJSON as? [String: Any],
              let userID = user["id"] as? String, let email = user["email"] as? String,
              let orgs = try await orgsJSON as? [[String: Any]] else {
            throw ProviderError.badResponse("account")
        }
        var workspaces = orgs.compactMap { org -> Workspace? in
            guard let id = org["id"] as? String, !id.isEmpty, !id.contains("#") else { return nil }
            return Workspace(id: id, name: (org["name"] as? String) ?? id)
        }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        if let scoped = token.workspaceID { workspaces.removeAll { $0.id != scoped } }
        guard !workspaces.isEmpty else {
            throw ProviderError.badResponse(Localized.text(
                "This OpenCode account has no workspace to show.",
                "Denne OpenCode-kontoen har ingen arbeidsområder å vise."))
        }

        // The same account and scope signed in again replaces its session and
        // keeps the names given to its cards.
        let found = workspaces
        let (entryID, saved): (String, [Workspace]) = try sessionLock.withLock {
            var workspaces = found
            let previous = try storage.configuredKeys().first { entry in
                guard let old = try? storedSession(entry.id) else { return false }
                return old.userID == userID && old.scopedWorkspaceID == token.workspaceID
            }
            if let previous, let old = try storedSession(previous.id) {
                for index in workspaces.indices {
                    workspaces[index].label = old.workspaces.first { $0.id == workspaces[index].id }?.label
                }
            }
            let session = Session(
                access: token.access, refresh: token.refresh, expiresAt: now.timeIntervalSince1970 + token.lifetime,
                userID: userID, email: email, scopedWorkspaceID: token.workspaceID, workspaces: workspaces)
            if let previous {
                try save(session, entryID: previous.id)
                return (previous.id, workspaces)
            }
            return (try storage.addKey(try Self.encode(session), label: nil).id, workspaces)
        }
        workspaces = saved
        return workspaces.map {
            AccountIdentity(providerID: id, id: Self.accountID(entryID, $0.id), label: $0.label ?? $0.name, email: email)
        }
    }

    // MARK: Refresh

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard account.account.providerID == id, let (entryID, workspaceID) = Self.split(account.account.id) else {
            throw ProviderError.notLoggedIn
        }
        guard try storedSession(entryID) != nil else { throw ProviderError.unauthorized }
        let session = try await validSession(entryID)
        guard let workspace = session.workspaces.first(where: { $0.id == workspaceID }) else {
            throw ProviderError.notLoggedIn
        }
        async let goResult = goWindows(session, workspaceID: workspaceID)
        async let budgetResult = budgetWindows(session, workspaceID: workspaceID)
        let go = try await goResult
        let windows = try await go + budgetResult
        guard !windows.isEmpty else {
            throw ProviderError.badResponse(Localized.text(
                "No Go subscription or budget in this workspace.",
                "Ingen Go-abonnement eller budsjett i dette arbeidsområdet."))
        }
        var identity = account.account
        identity.label = workspace.label ?? workspace.name
        identity.email = session.email
        identity.plan = go.isEmpty ? nil : "Go"
        return UsageSnapshot(account: identity, providerID: id, windows: windows)
    }

    private func goWindows(_ session: Session, workspaceID: String) async throws -> [UsageWindow] {
        guard let root = try await get(
            Self.goUsageURL, token: session.access, headers: ["x-opencode-org-id": workspaceID],
            forbiddenIsEmpty: true) as? [String: Any],
            let usage = root["usage"] as? [String: Any] else { return [] }
        return [("5h", "rolling"), ("Week", "weekly"), ("Month", "monthly")].compactMap { label, key in
            let meter = usage[key] as? [String: Any]
            return percentWindow(
                "\(id).\(key)", label,
                used: normalizePercent(adapterNum(meter, ["percent"])), resetsAt: meter?["resetsAt"])
        }
    }

    /// Spend budgets that cover this member, in dollars as OpenCode reports
    /// them: spent against the limit. A row with a limit is drawn as a
    /// percentage, so the limit goes in its label ("Budget $50") to keep the
    /// dollar scale visible. Without a limit the row shows the amount spent.
    private func budgetWindows(_ session: Session, workspaceID: String) async throws -> [UsageWindow] {
        guard let budgets = try await get(
            "\(Self.server)/api/policies/current-budgets", token: session.access,
            headers: ["x-org-id": workspaceID], forbiddenIsEmpty: true) as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        let usable = budgets.filter {
            guard let rule = $0["ruleID"] as? String, !rule.isEmpty, adapterNum($0, ["spentDollars"]) != nil else {
                return false
            }
            return seen.insert(rule).inserted
        }
        func limit(_ budget: [String: Any]) -> Double? {
            adapterNum(budget, ["limitDollars"]).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        }
        let open = usable.filter { limit($0) == nil }.count
        var openIndex = 0
        return usable.map { budget in
            let limit = limit(budget)
            let reset = (budget["resetsAt"] as? String).flatMap(Self.date)
            let label: String
            if let limit {
                label = "Budget $" + String(format: limit == limit.rounded() ? "%.0f" : "%.2f", limit)
            } else {
                openIndex += 1
                label = open == 1 ? "Budget" : "Budget \(openIndex)"
            }
            return UsageWindow(
                id: "\(id).budget.\(budget["ruleID"] as? String ?? "")",
                label: label, kind: .credits,
                used: adapterNum(budget, ["spentDollars"]), limit: limit, unit: "$", resetsAt: reset)
        }
    }

    static func date(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    // MARK: Session

    private func storedSession(_ entryID: String) throws -> Session? {
        guard let raw = try credentials.secret(for: storage.credentialKey(entryID)) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: Data(raw.utf8))
    }

    private func save(_ session: Session, entryID: String) throws {
        try credentials.setSecret(try Self.encode(session), for: storage.credentialKey(entryID))
    }

    static func encode(_ session: Session) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(session), as: UTF8.self)
    }

    /// The saved session, with a fresh access token when the old one is about
    /// to expire. OpenCode rotates the refresh token, so concurrent refreshes
    /// of one sign-in share a single request.
    private func validSession(_ entryID: String, now: Date = Date()) async throws -> Session {
        try await gate.run(entryID) {
            guard let session = try storedSession(entryID) else { throw ProviderError.notLoggedIn }
            guard session.expiresAt - 60 <= now.timeIntervalSince1970 else { return session }
            let (status, json) = try await post(
                "\(Self.server)/auth/device/token",
                ["grant_type": "refresh_token", "refresh_token": session.refresh, "client_id": Self.clientID])
            guard let token = Token(json) else {
                switch status {
                case 400, 401, 403: throw ProviderError.unauthorized
                case 429: throw ProviderError.rateLimited(retryAfter: nil)
                default: throw status >= 500 ? ProviderError.serverError(status) : ProviderError.badResponse("token")
                }
            }
            return try sessionLock.withLock {
                // Read again: a card may have been renamed or removed, or the
                // account signed in again, while the request was out.
                guard var fresh = try storedSession(entryID) else { throw ProviderError.notLoggedIn }
                guard fresh.refresh == session.refresh else { return fresh }
                fresh.access = token.access
                fresh.refresh = token.refresh
                fresh.expiresAt = now.timeIntervalSince1970 + token.lifetime
                try save(fresh, entryID: entryID)
                return fresh
            }
        }
    }

    private struct Token {
        var access: String
        var refresh: String
        var lifetime: TimeInterval
        var workspaceID: String?

        init?(_ json: [String: Any]) {
            guard let access = json["access_token"] as? String, !access.isEmpty,
                  let refresh = json["refresh_token"] as? String, !refresh.isEmpty,
                  let lifetime = adapterNum(json, ["expires_in"]), lifetime.isFinite, lifetime > 0 else { return nil }
            self.access = access
            self.refresh = refresh
            self.lifetime = lifetime
            self.workspaceID = json["org_id"] as? String
        }
    }

    // MARK: HTTP

    /// All requests go to opencode.ai over HTTPS and never follow redirects.
    private func send(_ method: String, _ urlString: String, headers: [String: String], body: Data? = nil) async throws -> HTTPResponse {
        try Task.checkCancellation()
        let url = try OAuthRefresher.validatedURL(urlString)
        guard url.host == Self.host else { throw ProviderError.badResponse("host") }
        var all = headers
        all["Accept"] = "application/json"
        all["User-Agent"] = Self.userAgent
        return try await http.send(HTTPRequest(
            method: method, url: url, headers: all, body: body, allowsRedirects: false))
    }

    /// POST a JSON body; returns the status with the JSON object, `[:]` when
    /// the body is not one.
    private func post(_ url: String, _ body: [String: Any]) async throws -> (status: Int, json: [String: Any]) {
        let response = try await send(
            "POST", url, headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body))
        return (response.status, (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:])
    }

    private func postJSON(_ url: String, _ body: [String: Any]) async throws -> [String: Any] {
        let (status, json) = try await post(url, body)
        switch status {
        case 200..<300: return json
        case 429: throw ProviderError.rateLimited(retryAfter: nil)
        default: throw ProviderError.serverError(status)
        }
    }

    /// GET JSON as the signed-in member. With `forbiddenIsEmpty`, 403 returns
    /// nil: OpenCode's answer for a workspace without Go, or without budgets.
    private func get(
        _ url: String, token: String, headers: [String: String] = [:], forbiddenIsEmpty: Bool = false
    ) async throws -> Any? {
        var all = headers
        all["Authorization"] = "Bearer \(token)"
        let response = try await send("GET", url, headers: all)
        switch response.status {
        case 200..<300:
            guard let json = try? JSONSerialization.jsonObject(with: response.body) else {
                throw ProviderError.badResponse("not JSON")
            }
            return json
        case 403 where forbiddenIsEmpty: return nil
        case 300..<400, 401, 403: throw ProviderError.unauthorized
        case 429: throw ProviderError.rateLimited(retryAfter: response.retryAfter)
        default: throw ProviderError.serverError(response.status)
        }
    }
}

/// Runs one operation per key at a time; callers that arrive while it runs
/// get its result.
private actor SessionGate {
    private var running: [String: Task<OpenCodeConsoleProvider.Session, Error>] = [:]

    func run(
        _ key: String, _ operation: @escaping @Sendable () async throws -> OpenCodeConsoleProvider.Session
    ) async throws -> OpenCodeConsoleProvider.Session {
        if let task = running[key] { return try await task.value }
        let task = Task { try await operation() }
        running[key] = task
        defer { running[key] = nil }
        return try await task.value
    }
}
