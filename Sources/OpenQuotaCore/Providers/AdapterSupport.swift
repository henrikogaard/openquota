import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Reads provider credential files written by their own CLIs
/// (~/.claude/.credentials.json, ~/.codex/auth.json, …). File access is the
/// whole point of this tier: no browser cookies, no keychain scraping — only
/// files the user already produced by logging in with the provider's CLI.
public struct LocalCredentialFiles: Sendable {
    public var home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    public func fileExists(_ relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent(relativePath).path)
    }

    public func readJSON(_ relativePath: String) -> [String: Any]? {
        let url = home.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else { return nil }
        return dict
    }

    public func writeJSON(_ relativePath: String, _ dict: [String: Any]) {
        let url = home.appendingPathComponent(relativePath)
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600],
                                               ofItemAtPath: url.path)
    }

    public func readText(_ relativePath: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(relativePath), encoding: .utf8)
    }
}

/// A refreshable OAuth token bundle read from a provider's credential file.
/// `refresh` rewrites the file the CLI owns so the CLI keeps working too.
public struct OAuthTokens: Sendable {
    public var accessToken: String
    public var refreshToken: String?
    /// Epoch seconds at which the access token expires (nil = unknown/forever).
    public var expiresAt: TimeInterval?

    public var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date().timeIntervalSince1970 >= expiresAt - 60
    }
}

/// Minimal refresh-token exchange; every provider here uses the same shape.
enum OAuthRefresher {
    static func refresh(
        url: String,
        clientID: String,
        refreshToken: String,
        clientSecret: String? = nil,
        http: any HTTPClient
    ) async throws -> OAuthTokens {
        var pairs = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ]
        if let clientSecret { pairs["client_secret"] = clientSecret }
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = pairs.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }
        let body = Data(encoded.joined(separator: "&").utf8)
        let req = HTTPRequest(
            method: "POST",
            url: try validatedURL(url),
            headers: ["Content-Type": "application/x-www-form-urlencoded"],
            body: body,
            timeout: 15
        )
        let resp = try await http.send(req)
        guard resp.status == 200,
              let json = try? JSONSerialization.jsonObject(with: resp.body) as? [String: Any],
              let access = json["access_token"] as? String else {
            throw ProviderError.serverError(resp.status)
        }
        return OAuthTokens(
            accessToken: access,
            refreshToken: json["refresh_token"] as? String ?? refreshToken,
            expiresAt: (json["expires_in"] as? Double).map { Date().timeIntervalSince1970 + $0 }
        )
    }

    static func validatedURL(_ s: String) throws -> URL {
        guard let url = URL(string: s), url.scheme == "https" else {
            throw ProviderError.badResponse("bad URL \(s)")
        }
        return url
    }
}

/// Common GET-JSON flow for hand-written adapters with consistent error
/// mapping (401 → invalidKey, 429 → rateLimited, else unavailable).
enum AdapterHTTP {
    static func getJSON(
        _ url: String,
        headers: [String: String] = [:],
        http: any HTTPClient
    ) async throws -> Any {
        try await request(.init(method: "GET", url: url, headers: headers), http: http)
    }

    static func postJSON(
        _ url: String,
        body: [String: Any],
        headers: [String: String] = [:],
        http: any HTTPClient
    ) async throws -> Any {
        let data = try JSONSerialization.data(withJSONObject: body)
        var h = headers
        h["Content-Type"] = h["Content-Type"] ?? "application/json"
        return try await request(.init(method: "POST", url: url, headers: h, body: data), http: http)
    }

    struct Call: Sendable {
        var method: String
        var url: String
        var headers: [String: String] = [:]
        var body: Data? = nil
    }

    static func request(_ call: Call, http: any HTTPClient) async throws -> Any {
        let req = HTTPRequest(
            method: call.method,
            url: try OAuthRefresher.validatedURL(call.url),
            headers: call.headers,
            body: call.body,
            timeout: 15
        )
        let resp = try await http.send(req)
        switch resp.status {
        case 200..<300:
            return (try? JSONSerialization.jsonObject(with: resp.body)) ?? [:]
        case 401, 403:
            throw ProviderError.unauthorized
        case 429:
            throw ProviderError.rateLimited(retryAfter: resp.retryAfter)
        default:
            throw ProviderError.serverError(resp.status)
        }
    }
}

/// Convenience for adapters: build a percent-used consumption window.
func percentWindow(_ id: String, _ label: String, used: Any?, resetsAt: Any?,
                   kind: UsageWindow.Kind = .consumption) -> UsageWindow? {
    let value: Double?
    if let n = used as? NSNumber { value = n.doubleValue }
    else if let s = used as? String { value = Double(s) }
    else { value = nil }
    guard let usedValue = value else { return nil }
    var reset: Date?
    switch resetsAt {
    case let s as String:
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        reset = iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    case let n as NSNumber:
        // Heuristic: > 1e12 is millis, else seconds.
        reset = Date(timeIntervalSince1970: n.doubleValue > 1e12 ? n.doubleValue / 1000 : n.doubleValue)
    default:
        reset = nil
    }
    return UsageWindow(id: id, label: label, kind: kind, used: usedValue,
                       limit: 100, unit: "%", resetsAt: reset)
}
