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
        public var creditsUnit: String?

        public init() {}
    }

    /// One fetchable window definition. `label` is display text; paths resolve
    /// inside the response body of `url` (or the shared top-level `url`).
    public struct WindowSpec: Codable, Sendable {
        public var label: String
        public var kind: UsageWindow.Kind?
        public var url: String?
        public var used: String?
        public var limit: String?
        public var remaining: String?
        public var resetsAt: String?
        public var resetsAtFormat: String?
        public var unit: String?

        public init(label: String, kind: UsageWindow.Kind? = nil, url: String? = nil,
                    used: String? = nil, limit: String? = nil, remaining: String? = nil,
                    resetsAt: String? = nil, resetsAtFormat: String? = nil, unit: String? = nil) {
            self.label = label
            self.kind = kind
            self.url = url
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
    public var url: String
    public var auth: AuthType = .bearer
    public var dashboardURL: String?
    /// Identity fields for the account label/id (e.g. "$.data.label", "$.data.user_id").
    public var identityLabel: String?
    public var identityKey: String?
    public var map: FieldMap = FieldMap()
    public var windows: [WindowSpec] = []

    public init(
        id: String, displayName: String, url: String, auth: AuthType = .bearer,
        dashboardURL: String? = nil, identityLabel: String? = nil, identityKey: String? = nil,
        map: FieldMap = FieldMap(), windows: [WindowSpec] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.auth = auth
        self.dashboardURL = dashboardURL
        self.identityLabel = identityLabel
        self.identityKey = identityKey
        self.map = map
        self.windows = windows
    }
}

/// Tiny JSON-pointer-lite reader: "$.a.b[0].c" against a JSONSerialization tree.
/// Only walks dictionaries/arrays — deliberately dumb; specs own correctness.
public enum JSONPath {
    public static func value(_ root: Any?, at path: String) -> Any? {
        var current = root
        var path = path
        if path.hasPrefix("$") { path = String(path.dropFirst()) }
        for part in path.split(separator: ".").filter({ !$0.isEmpty }) {
            // Support trailing "[n]" index on the segment.
            var key = String(part)
            var index: Int?
            if let open = key.firstIndex(of: "["), key.hasSuffix("]") {
                index = Int(key[key.index(after: open)..<key.index(before: key.endIndex)])
                key = String(key[..<open])
            }
            if !key.isEmpty {
                guard let dict = current as? [String: Any], let next = dict[key] else { return nil }
                current = next
            }
            if let index {
                guard let array = current as? [Any], array.indices.contains(index) else { return nil }
                current = array[index]
            }
        }
        if let value = current as? NSNull { _ = value; return nil }
        return current
    }

    public static func double(_ root: Any?, at path: String?) -> Double? {
        guard let path, let raw = value(root, at: path) else { return nil }
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }

    public static func string(_ root: Any?, at path: String?) -> String? {
        guard let path, let raw = value(root, at: path) else { return nil }
        if let s = raw as? String { return s }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    public static func date(_ root: Any?, at path: String?, format: String? = nil) -> Date? {
        guard let path, let raw = value(root, at: path) else { return nil }
        if let seconds = raw as? NSNumber { return Date(timeIntervalSince1970: seconds.doubleValue) }
        if let string = raw as? String {
            if format == "epochSeconds", let seconds = Double(string) {
                return Date(timeIntervalSince1970: seconds)
            }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return iso.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
        return nil
    }
}
