import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - Antigravity (local language server, experimental)

/// Google Antigravity's desktop app runs a language server on this Mac and
/// records how to reach it in `~/.gemini/antigravity/daemon/hub_<port>.json`
/// (`pid`, `httpPort`, `csrfToken`). Its Connect `GetUserStatus` call returns
/// the signed-in account's per-model quota, shared by the app and the `agy`
/// CLI. Nothing here is documented, so it can break without notice. Requests
/// go to 127.0.0.1 only and the CSRF token never leaves this Mac.
public struct AntigravityProvider: UsageProvider {
    public let id = "antigravity"
    public let displayName = "Antigravity"
    public let dashboardURL: URL? = nil

    static let daemonPath = ".gemini/antigravity/daemon"
    static let statusPath = "/exa.language_server_pb.LanguageServerService/GetUserStatus"
    /// Hub files from crashed or closed sessions are left behind. Only the
    /// newest few whose process still runs are tried, each with a short timeout.
    static let maxHubFiles = 4

    struct Hub: Equatable {
        var pid: Int32
        var port: Int
        var csrfToken: String
    }

    private let http: any HTTPClient
    private let files: LocalCredentialFiles
    private let isRunning: @Sendable (Int32) -> Bool

    public init(http: any HTTPClient, files: LocalCredentialFiles) {
        self.init(http: http, files: files, isRunning: Self.processIsRunning)
    }

    init(http: any HTTPClient, files: LocalCredentialFiles, isRunning: @escaping @Sendable (Int32) -> Bool) {
        self.http = http
        self.files = files
        self.isRunning = isRunning
    }

    static func processIsRunning(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Hub files, newest first.
    private func hubFiles() -> [URL] {
        let directory = files.url(Self.daemonPath)
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let hubs = entries.filter {
            $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json"
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return hubs.sorted { modified($0) > modified($1) }
    }

    static func hub(from dict: [String: Any]) -> Hub? {
        guard let pid = (dict["pid"] as? NSNumber)?.int32Value, pid > 0,
              let port = (dict["httpPort"] as? NSNumber)?.intValue, (1...65_535).contains(port),
              let token = dict["csrfToken"] as? String, (8...256).contains(token.utf8.count) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        guard token.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return Hub(pid: pid, port: port, csrfToken: token)
    }

    public func accounts() async throws -> [AccountDescriptor] {
        guard !hubFiles().isEmpty else { return [] }
        let identity = AccountIdentity(
            providerID: id,
            id: AccountIdentity.makeID(providerID: id, identityKey: files.url(Self.daemonPath).path),
            label: "Antigravity")
        return [AccountDescriptor(account: identity, source: .configFile, isDefaultHome: true)]
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        let hubs = hubFiles().compactMap { url -> Hub? in
            let path = Self.daemonPath + "/" + url.lastPathComponent
            return files.readJSON(path).flatMap(Self.hub(from:))
        }.filter { isRunning($0.pid) }.prefix(Self.maxHubFiles)
        guard !hubs.isEmpty else {
            throw ProviderError.badResponse(Localized.text(
                "Open the Antigravity app to read its quota",
                "Åpne Antigravity-appen for å lese kvoten"))
        }
        var lastError: Error = ProviderError.notLoggedIn
        for hub in hubs {
            try Task.checkCancellation()
            do {
                let root = try await status(hub)
                return try snapshot(from: root, account: account)
            } catch let error as ProviderError where error.triesNextHub {
                // A stale hub file whose port now belongs to someone else, a
                // server still starting, or an odd answer: try the next one.
                lastError = error
            }
        }
        throw lastError
    }

    private func status(_ hub: Hub) async throws -> [String: Any] {
        guard let url = URL(string: "http://127.0.0.1:\(hub.port)\(Self.statusPath)") else {
            throw ProviderError.badResponse("bad port")
        }
        let body = try JSONSerialization.data(withJSONObject: ["metadata": [
            "ideName": "antigravity", "extensionName": "antigravity", "locale": "en",
        ]])
        let response = try await http.send(HTTPRequest(
            method: "POST", url: url,
            headers: [
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1",
                "X-Codeium-Csrf-Token": hub.csrfToken,
            ],
            body: body, timeout: 5, allowsRedirects: false))
        switch response.status {
        case 200..<300:
            guard let root = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                throw ProviderError.badResponse("status payload")
            }
            return root
        case 401, 403: throw ProviderError.unauthorized
        default: throw ProviderError.serverError(response.status)
        }
    }

    func snapshot(from root: [String: Any], account: AccountDescriptor) throws -> UsageSnapshot {
        guard let status = root["userStatus"] as? [String: Any] else {
            throw ProviderError.badResponse("status payload")
        }
        let config = status["cascadeModelConfigData"] as? [String: Any]
        let models = config?["clientModelConfigs"] as? [[String: Any]] ?? []
        let groups = (config?["groupedModels"] as? [String: Any] ?? [:]).compactMapValues {
            ($0 as? [String: Any])?["displayName"] as? String
        }
        let windows = Self.windows(models: models, groups: groups)
        if windows.isEmpty { throw ProviderError.badResponse("no quota fields") }

        var identity = account.account
        let tier = status["userTier"] as? [String: Any]
        let planInfo = (status["planStatus"] as? [String: Any])?["planInfo"] as? [String: Any]
        identity.plan = (tier?["description"] as? String) ?? (planInfo?["planName"] as? String)
        if let email = status["email"] as? String, email.contains("@") { identity.email = email }
        return UsageSnapshot(account: identity, providerID: id, windows: windows)
    }

    /// One row per model family. Variants such as "(Low)" and "(High)" share
    /// a family; the most-used variant decides the row.
    static func windows(models: [[String: Any]], groups: [String: String]) -> [UsageWindow] {
        struct Family { var name: String; var used: Double; var reset: Any? }
        var order: [String] = []
        var families: [String: Family] = [:]
        let keys = groups.keys.sorted { $0.count > $1.count }
        for model in models {
            guard let quota = model["quotaInfo"] as? [String: Any] else { continue }
            let reset: Any? = quota["resetTime"] as? String ?? quota["resetTime"] as? NSNumber
            // Proto3 omits a zero fraction: a quota with a reset time but no
            // fraction is used up. Without either there is nothing to show.
            let remaining = adapterNum(quota, ["remainingFraction"]) ?? (reset != nil ? 0 : nil)
            guard let remaining, remaining.isFinite else { continue }
            let used = min(max((1 - remaining) * 100, 0), 100)
            let modelID = model["modelId"] as? String ?? ""
            let label = model["label"] as? String ?? modelID
            let name = keys.first { modelID == $0 || modelID.hasPrefix($0 + "-") }.flatMap { groups[$0] }
                ?? familyName(label)
            guard !name.isEmpty else { continue }
            if var family = families[name] {
                if used > family.used { family.used = used; family.reset = reset }
                families[name] = family
            } else {
                order.append(name)
                families[name] = Family(name: name, used: used, reset: reset)
            }
        }
        return order.compactMap { name in
            families[name].flatMap { percentWindow("antigravity.\(slug(name))", name, used: $0.used, resetsAt: $0.reset) }
        }
    }

    /// "GPT-OSS 120B (Medium)" → "GPT-OSS 120B".
    static func familyName(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return trimmed }
        return trimmed[..<open].trimmingCharacters(in: .whitespaces)
    }

    static func slug(_ name: String) -> String {
        name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
    }
}

private extension ProviderError {
    /// A closed or reused port, or a server still starting up.
    var triesNextHub: Bool {
        switch self {
        case .network, .timedOut, .unauthorized, .serverError, .badResponse: true
        default: false
        }
    }
}
