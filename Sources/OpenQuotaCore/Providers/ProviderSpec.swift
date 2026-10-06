import Foundation

/// Declarative spec for a "bearer key + JSON endpoint" provider — the common
/// case for adding providers (Requesty, OpenRouter, and most routers fit).
/// A spec captures where to fetch, how to authenticate, and how to map the
/// JSON onto UsageSnapshot fields via JSON-Pointer-lite paths ("$.a.b[0].c").
public struct ProviderSpec: Codable, Sendable {
    public enum AuthType: String, Codable, Sendable {
        /// Authorization: Bearer <key stored in CredentialStore for this account>
        case bearer
        /// x-api-key: <key>
        case apiKeyHeader
        /// A single custom header: `authHeader: authPrefix + key`
        /// (e.g. xi-api-key, api-key, x-goog-api-key, "Authorization" + "Token ").
        case header
        /// Cookie: <key> — a manually pasted session cookie/token. Degraded
        /// mode for providers with no API: never auto-imported from a browser.
        case cookie
    }

    /// JSON path → model field mapping. All optional; missing paths yield nil.
    public struct FieldMap: Codable, Sendable {
        public var plan: String?
        public var used: String?
        public var limit: String?
        public var remaining: String?
        public var resetsAt: String?
        /// Seconds-suffix hint for resetsAt values: "epochSeconds" | "iso8601".
        public var resetsAtFormat: String?
        /// Absolute remaining credit/currency amount and its unit.
        public var creditsRemaining: String?
        /// Optional amount to subtract from creditsRemaining (purchased minus consumed).
        public var creditsUsed: String?
        public var creditsUnit: String?
        public var creditsUnitLabel: String?

        public init() {}
    }

    /// One fetchable window definition. `label` is display text; paths resolve
    /// inside the response body of `url` (or the shared top-level `url`).
    public struct WindowSpec: Codable, Sendable {
        public var label: String
        public var kind: UsageWindow.Kind?
        public var url: String?
        /// HTTP method for this window's request (default GET).
        public var method: String?
        /// Raw request body (JSON string) for POST/GraphQL-style endpoints.
        public var body: String?
        /// Extra headers merged over the auth headers for this request.
        public var headers: [String: String]?
        public var used: String?
        public var limit: String?
        public var remaining: String?
        public var resetsAt: String?
        public var resetsAtFormat: String?
        public var unit: String?

        public init(label: String, kind: UsageWindow.Kind? = nil, url: String? = nil,
                    method: String? = nil, body: String? = nil,
                    headers: [String: String]? = nil,
                    used: String? = nil, limit: String? = nil, remaining: String? = nil,
                    resetsAt: String? = nil, resetsAtFormat: String? = nil, unit: String? = nil) {
            self.label = label
            self.kind = kind
            self.url = url
            self.method = method
            self.body = body
            self.headers = headers
            self.used = used
            self.limit = limit
            self.remaining = remaining
            self.resetsAt = resetsAt
            self.resetsAtFormat = resetsAtFormat
            self.unit = unit
        }
    }

    public var id: String
    public var displayName: String
    /// Primary fetch URL. May contain {now}, {today}, {d7}, {d30} templates —
    /// replaced with epoch seconds (now, start-of-today UTC, now−7d, now−30d).
    public var url: String
    /// HTTP method for the primary fetch (default GET).
    public var method: String?
    /// Raw request body for POST endpoints.
    public var body: String?
    /// Extra headers merged over the auth headers for every request.
    public var headers: [String: String]?
    public var auth: AuthType = .bearer
    /// Header name used by `.header` auth (e.g. "xi-api-key").
    public var authHeader: String?
    /// Value prefix for `.header` auth (e.g. "Bearer "), default "".
    public var authPrefix: String?
    public var dashboardURL: String?
    /// Identity fields for the account label/id (e.g. "$.data.label", "$.data.user_id").
    public var identityLabel: String?
    public var identityKey: String?
    /// True when the endpoint/field mapping is from docs but not yet verified
    /// against a live account — surfaced as an "unverified" hint in Settings.
    public var unverified: Bool = true
    public var map: FieldMap = FieldMap()
    public var windows: [WindowSpec] = []

    public init(
        id: String, displayName: String, url: String, auth: AuthType = .bearer,
        method: String? = nil, body: String? = nil, headers: [String: String]? = nil,
        authHeader: String? = nil, authPrefix: String? = nil,
        dashboardURL: String? = nil, identityLabel: String? = nil, identityKey: String? = nil,
        unverified: Bool = true,
        map: FieldMap = FieldMap(), windows: [WindowSpec] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.method = method
        self.body = body
        self.headers = headers
        self.auth = auth
        self.authHeader = authHeader
        self.authPrefix = authPrefix
        self.dashboardURL = dashboardURL
        self.identityLabel = identityLabel
        self.identityKey = identityKey
        self.unverified = unverified
        self.map = map
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, url, method, body, headers, auth, authHeader, authPrefix
        case dashboardURL, identityLabel, identityKey, unverified, map, windows
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        guard !id.isEmpty, id.count <= 80,
              id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Invalid provider ID")
        }
        self.init(
            id: id, displayName: try c.decode(String.self, forKey: .displayName),
            url: try c.decode(String.self, forKey: .url),
            auth: try c.decodeIfPresent(AuthType.self, forKey: .auth) ?? .bearer,
            method: try c.decodeIfPresent(String.self, forKey: .method),
            body: try c.decodeIfPresent(String.self, forKey: .body),
            headers: try c.decodeIfPresent([String: String].self, forKey: .headers),
            authHeader: try c.decodeIfPresent(String.self, forKey: .authHeader),
            authPrefix: try c.decodeIfPresent(String.self, forKey: .authPrefix),
            dashboardURL: try c.decodeIfPresent(String.self, forKey: .dashboardURL),
            identityLabel: try c.decodeIfPresent(String.self, forKey: .identityLabel),
            identityKey: try c.decodeIfPresent(String.self, forKey: .identityKey),
            unverified: try c.decodeIfPresent(Bool.self, forKey: .unverified) ?? true,
            map: try c.decodeIfPresent(FieldMap.self, forKey: .map) ?? FieldMap(),
            windows: try c.decodeIfPresent([WindowSpec].self, forKey: .windows) ?? [])
    }
}

/// Tiny JSON-pointer-lite reader: "$.a.b[0].c" against a JSONSerialization tree.
/// Only walks dictionaries/arrays — deliberately dumb; specs own correctness.
///
/// Extensions beyond plain key/index walking:
///   - `[n]`    — array index
///   - `[*]`    — flatten: current must be an array; returns array of every
///                element, and the remaining path is applied per-element
///   - `[k=v]`  — filter: current must be an array of dicts; returns first
///                element whose `k` stringifies to `v` (e.g.
///                `$.limits[type=TOKENS_LIMIT]`)
public enum JSONPath {
    public static func value(_ root: Any?, at path: String) -> Any? {
        var current = root
        var path = path
        if path.hasPrefix("$") { path = String(path.dropFirst()) }
        let parts = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        var i = 0
        while i < parts.count {
            var part = parts[i]
            i += 1

            // Trailing "[...]" on the segment: index, wildcard, or k=v filter.
            var indexSpec: String?
            if let open = part.firstIndex(of: "["), part.hasSuffix("]") {
                indexSpec = String(part[part.index(after: open)..<part.index(before: part.endIndex)])
                part = String(part[..<open])
            }

            if !part.isEmpty {
                if let dict = current as? [String: Any] {
                    guard let next = dict[part] else { return nil }
                    current = next
                } else if let array = current as? [Any] {
                    // Key access applied to a wildcard-flattened array.
                    current = array.map { ($0 as? [String: Any])?[part] as Any? }
                        .compactMap { $0 }
                } else {
                    return nil
                }
            }

            guard let spec = indexSpec else { continue }
            if spec == "*" {
                guard let array = current as? [Any] else { return nil }
                // Flatten one level: `results[*]` on [[a,b],[c]] yields
                // [a,b,c] so the next path segment applies per element.
                current = array.flatMap { ($0 as? [Any]) ?? [$0] }
            } else if let eq = spec.firstIndex(of: "=") {
                let key = String(spec[..<eq])
                let want = String(spec[spec.index(after: eq)...])
                guard let array = current as? [Any] else { return nil }
                current = array.first { element in
                    guard let dict = element as? [String: Any],
                          let raw = dict[key] else { return false }
                    return stringify(raw) == want
                }
            } else {
                guard let index = Int(spec),
                      let array = current as? [Any],
                      array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        if let value = current as? NSNull { _ = value; return nil }
        return current
    }

    private static func stringify(_ raw: Any) -> String {
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return String(describing: raw)
    }

    /// Sum of numeric leaves reachable by `path` — the path may end in a
    /// wildcard-flattened array (e.g. `$.data[*].results[*].amount.value`).
    public static func sum(_ root: Any?, at path: String?) -> Double? {
        guard let path, let raw = value(root, at: path) else { return nil }
        if let array = raw as? [Any] {
            var total = 0.0
            var found = false
            for element in array {
                if let n = element as? NSNumber { total += n.doubleValue; found = true }
                else if let s = element as? String, let d = Double(s) { total += d; found = true }
            }
            return found && total.isFinite ? total : nil
        }
        if let n = raw as? NSNumber, n.doubleValue.isFinite { return n.doubleValue }
        if let s = raw as? String, let n = Double(s), n.isFinite { return n }
        return nil
    }

    public static func double(_ root: Any?, at path: String?) -> Double? {
        guard let path, let raw = value(root, at: path) else { return nil }
        if let n = raw as? NSNumber, n.doubleValue.isFinite { return n.doubleValue }
        if let s = raw as? String, let n = Double(s), n.isFinite { return n }
        return nil
    }

    public static func string(_ root: Any?, at path: String?) -> String? {
        guard let path, let raw = value(root, at: path) else { return nil }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    /// `resetsAtFormat` hints: "epochSeconds" (numeric or numeric-string),
    /// "epochMillis", or default ISO-8601 strings / epoch-seconds numbers.
    public static func date(_ root: Any?, at path: String?, format: String? = nil) -> Date? {
        guard let path, let raw = value(root, at: path) else { return nil }
        if let seconds = raw as? NSNumber {
            let divisor = format == "epochMillis" ? 1000.0 : 1.0
            return Date(timeIntervalSince1970: seconds.doubleValue / divisor)
        }
        if let string = raw as? String {
            if format == "epochSeconds", let seconds = Double(string) {
                return Date(timeIntervalSince1970: seconds)
            }
            if format == "epochMillis", let seconds = Double(string) {
                return Date(timeIntervalSince1970: seconds / 1000.0)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
        return nil
    }
}
