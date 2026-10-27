import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Pasted session cookie

/// A validated `Cookie:` request header pasted from a signed-in
/// admin.mistral.ai browser session (Mistral's web login is Ory-based).
struct MistralCookieHeader: Equatable, Sendable {
    struct Pair: Equatable, Sendable {
        var name: String
        var value: String
    }

    /// Normalized `name=value; …` string, exactly what gets sent as the
    /// Cookie header. Canonicalizing here means re-pasting the same session
    /// deduplicates even if the browser's formatting drifted.
    var headerValue: String
    /// All parsed pairs, in paste order.
    var pairs: [Pair]
    /// The first `ory_session_*` cookie — the web session itself.
    var sessionCookie: Pair?
    /// The `csrftoken` cookie, required by the console fallback endpoint.
    var csrfToken: String?

    /// Parses a pasted Cookie header. Accepts an optional leading `Cookie:`
    /// field name; pairs are `name=value` separated by `;`. Rejects header
    /// injection (control characters), over-long input, and headers without
    /// an `ory_session_*` cookie — Mistral answers those with a login redirect.
    init?(_ raw: String) {
        guard raw.utf8.count <= 16_384 else { return nil }
        var text = raw
        if text.hasPrefix("Cookie:") || text.hasPrefix("cookie:") {
            text = String(text.dropFirst("Cookie:".count))
        }
        guard text.unicodeScalars.allSatisfy({ scalar in
            scalar.value > 0x1F && scalar.value != 0x7F
        }) else { return nil }
        var parsed: [Pair] = []
        for part in text.split(separator: ";", omittingEmptySubsequences: true) {
            guard let equals = part.firstIndex(of: "=") else { return nil }
            let name = part[..<equals].trimmingCharacters(in: .whitespaces)
            let value = part[part.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  !name.unicodeScalars.contains(where: \.properties.isWhitespace)
            else { return nil }
            parsed.append(Pair(name: name, value: value))
        }
        guard let session = parsed.first(where: { $0.name.hasPrefix("ory_session_") }) else {
            return nil
        }
        sessionCookie = session
        csrfToken = parsed.first { $0.name == "csrftoken" }?.value
        pairs = parsed
        headerValue = parsed.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

// MARK: - Subscription budgets

/// One subscription allowance as reported by the admin console's subscription
/// page: a used percentage plus the allowance size and billing currency.
struct MistralBudget: Equatable, Hashable, Sendable {
    var usedPercentage: Double
    var initialBudget: Double
    var currencyCode: String
    var resetsAt: Date?
}

/// The subscription page's two allowance objects: the included monthly usage
/// shared across Studio, the API and Vibe Code (`api`), and the separate
/// Vibe Code allowance (`vibe`), which not every plan exposes.
struct MistralSubscriptionBudgets: Equatable, Hashable, Sendable {
    var api: MistralBudget?
    var vibe: MistralBudget?
}

/// Extracts the `budget.api_budget` / `budget.vibe_budget` allowance objects
/// from the subscription page's React Flight (RSC) payload: the page is HTML,
/// and the budgets live inside `self.__next_f.push([1, "…"])` chunks.
///
/// Flight rows are byte-counted (`<len-hex>:T<bytes>,…`), so raw JSON scanning
/// is unsafe; this scans the chunk stream record by record, skipping text and
/// binary rows by their declared length. Ported from CodexBar's MIT-licensed
/// MistralSubscriptionBudgetParser; field shapes are second-hand (its docs and
/// fixtures), not yet observed against a live paid account.
enum MistralSubscriptionParser {
    enum ParseError: Error, Equatable {
        case budgetNotFound
        case ambiguousBudgets
        case invalidRecord
    }

    private static let flightPushMarker = Data("self.__next_f.push(".utf8)
    private static let lengthDelimitedTags = Set("TAOoUSsLlGgMmV".utf8)

    static func parse(html: String) throws -> MistralSubscriptionBudgets {
        let stream = Data(flightChunks(in: html).joined().utf8)
        var matches: Set<MistralSubscriptionBudgets> = []
        try collectModels(in: stream) { root in
            collectBudgets(in: root, into: &matches)
        }
        guard let budgets = matches.first else { throw ParseError.budgetNotFound }
        guard matches.count == 1 else { throw ParseError.ambiguousBudgets }
        return budgets
    }

    /// Concatenates the string chunks from all `self.__next_f.push([1, "…"])`
    /// calls — Next.js's streamed RSC payload.
    private static func flightChunks(in html: String) -> [String] {
        let data = Data(html.utf8)
        var cursor = data.startIndex
        var chunks: [String] = []
        while cursor < data.endIndex,
              let markerRange = data.range(of: flightPushMarker, in: cursor..<data.endIndex)
        {
            var start = markerRange.upperBound
            while start < data.endIndex, isWhitespace(data[start]) {
                start = data.index(after: start)
            }
            guard start < data.endIndex, data[start] == UInt8(ascii: "[") else {
                cursor = markerRange.upperBound
                continue
            }
            guard let end = jsonContainerEnd(in: data, from: start) else {
                cursor = data.index(after: start)
                continue
            }
            let encoded = data.subdata(in: start..<end)
            if let array = try? JSONSerialization.jsonObject(with: encoded) as? [Any],
               array.count >= 2,
               let channel = array[0] as? Int,
               channel == 1,
               let chunk = array[1] as? String
            {
                chunks.append(chunk)
            }
            cursor = end
        }
        return chunks
    }

    /// Walks the flight stream line by line. Records are `<hex-id>:<payload>`
    /// where the payload's first byte marks the row type: length-delimited
    /// text/binary rows are skipped by their byte count (they can contain fake
    /// JSON and newlines); JSON model rows are handed to `body`.
    private static func collectModels(in data: Data, body: (Any) -> Void) throws {
        var cursor = data.startIndex
        while cursor < data.endIndex {
            let lineEnd = data[cursor...].firstIndex(of: UInt8(ascii: "\n")) ?? data.endIndex
            guard let colon = data[cursor..<lineEnd].firstIndex(of: UInt8(ascii: ":")),
                  colon > cursor,
                  data[cursor..<colon].allSatisfy(isHexDigit)
            else {
                cursor = lineEnd < data.endIndex ? data.index(after: lineEnd) : lineEnd
                continue
            }
            let start = data.index(after: colon)
            if start < lineEnd, lengthDelimitedTags.contains(data[start]) {
                guard let comma = data[start..<lineEnd].firstIndex(of: UInt8(ascii: ",")) else {
                    throw ParseError.invalidRecord
                }
                let lengthBytes = data[data.index(after: start)..<comma]
                let payloadStart = data.index(after: comma)
                guard !lengthBytes.isEmpty, lengthBytes.allSatisfy(isHexDigit),
                      let lengthString = String(bytes: lengthBytes, encoding: .utf8),
                      let length = Int(lengthString, radix: 16),
                      length <= data.distance(from: payloadStart, to: data.endIndex)
                else { throw ParseError.invalidRecord }
                cursor = data.index(payloadStart, offsetBy: length)
                continue
            }
            if start < lineEnd, data[start] == UInt8(ascii: "[") || data[start] == UInt8(ascii: "{") {
                guard let root = try? JSONSerialization.jsonObject(with: data.subdata(in: start..<lineEnd))
                else { throw ParseError.invalidRecord }
                body(root)
            }
            cursor = lineEnd < data.endIndex ? data.index(after: lineEnd) : lineEnd
        }
    }

    /// Finds every `budget` object in a model tree; a budget counts only when
    /// at least one allowance decodes validly, so a malformed sibling never
    /// discards a valid one.
    private static func collectBudgets(in value: Any, into results: inout Set<MistralSubscriptionBudgets>) {
        if let dictionary = value as? [String: Any] {
            if let raw = dictionary["budget"] as? [String: Any] {
                let budgets = MistralSubscriptionBudgets(
                    api: budget(from: raw["api_budget"]),
                    vibe: budget(from: raw["vibe_budget"]))
                if budgets.api != nil || budgets.vibe != nil {
                    results.insert(budgets)
                }
            }
            for child in dictionary.values {
                collectBudgets(in: child, into: &results)
            }
        } else if let array = value as? [Any] {
            for child in array {
                collectBudgets(in: child, into: &results)
            }
        }
    }

    /// Allowances derive from Mistral's own percentage and allowance size.
    /// Zero or malformed allowances (non-finite, negative, empty currency)
    /// are omitted rather than shown as healthy quota.
    private static func budget(from value: Any?) -> MistralBudget? {
        guard let dictionary = value as? [String: Any],
              let percentage = adapterNum(dictionary, ["usage_percentage"]),
              let initial = adapterNum(dictionary, ["initial_budget"]),
              let currency = (dictionary["currency"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        else { return nil }
        guard percentage.isFinite, percentage >= 0,
              initial.isFinite, initial > 0, !currency.isEmpty
        else { return nil }
        guard (initial * (percentage / 100)).isFinite else { return nil }
        return MistralBudget(
            usedPercentage: percentage,
            initialBudget: initial,
            currencyCode: currency,
            resetsAt: parseDate(dictionary["reset_at"]))
    }

    /// ISO-8601 first; also accepts React Flight `$D` date tags and epoch
    /// seconds/milliseconds, which Mistral has been observed to send.
    static func parseDate(_ raw: Any?) -> Date? {
        var text: String
        switch raw {
        case let string as String:
            text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        case let number as NSNumber:
            let seconds = number.doubleValue
            if seconds > 1e12 { return Date(timeIntervalSince1970: seconds / 1000) }
            if seconds > 1e9 { return Date(timeIntervalSince1970: seconds) }
            return nil
        default:
            return nil
        }
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("$D") { text = String(text.dropFirst(2)) }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        if let date = ISO8601DateFormatter().date(from: text) { return date }
        if let millis = Double(text), millis > 1e12 {
            return Date(timeIntervalSince1970: millis / 1000)
        }
        return nil
    }

    /// Returns the index just past the JSON container starting at `start`
    /// (string-, bracket- and brace-aware), or nil if unbalanced.
    private static func jsonContainerEnd(in data: Data, from start: Data.Index) -> Data.Index? {
        var expectedClosers: [UInt8] = []
        var inString = false
        var escaped = false
        var index = start
        while index < data.endIndex {
            let byte = data[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "["):
                    expectedClosers.append(UInt8(ascii: "]"))
                case UInt8(ascii: "{"):
                    expectedClosers.append(UInt8(ascii: "}"))
                case UInt8(ascii: "]"), UInt8(ascii: "}"):
                    guard expectedClosers.last == byte else { return nil }
                    expectedClosers.removeLast()
                    if expectedClosers.isEmpty { return data.index(after: index) }
                default:
                    break
                }
            }
            index = data.index(after: index)
        }
        return nil
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 13 || byte == 32
    }
}

// MARK: - Provider

/// Mistral subscription allowances (Pro/Team plans) through the web console
/// session that admin.mistral.ai itself uses.
///
/// There is no public API for this: Mistral's Admin API is Enterprise-only,
/// `api.mistral.ai` exposes no usage endpoint, and the Admin analytics
/// connector reports workspace activity, not a personal allowance. The only
/// source for a Pro/Team remaining allowance is the signed-in Ory web session.
/// The user pastes a `Cookie:` request header manually — the same explicit,
/// no-browser-import model as Cursor's session token. Sessions expire
/// (roughly monthly), and then the row must be re-pasted.
///
/// Requests per refresh (all GET, redirects refused, credentials only in
/// Cookie headers to the two fixed HTTPS hosts):
/// 1. `admin.mistral.ai/subscription` — RSC payload with the two budgets.
/// 2. `admin.mistral.ai/api/billing/credits` — pay-as-you-go balance (best-effort).
/// 3. `console.mistral.ai/api-ui/trpc/billing.vibeUsage` — Vibe percentage
///    fallback when the page has no vibe budget and a csrftoken is available.
public struct MistralProvider: UsageProvider {
    public let id = "mistral"
    public let displayName = "Mistral"
    public let dashboardURL = URL(string: "https://admin.mistral.ai/subscription")

    static let subscriptionURL = "https://admin.mistral.ai/subscription"
    static let creditsURL = "https://admin.mistral.ai/api/billing/credits"
    /// Pre-encoded tRPC batch input: `{"0":{"json":null,"meta":{"values":["undefined"],"v":1}}}`.
    static let vibeFallbackURL =
        "https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D%7D"

    private let http: any HTTPClient
    private let credentials: any CredentialStore
    private let storage: GenericProvider

    public init(http: any HTTPClient, credentials: any CredentialStore, manifestURL: URL? = nil) {
        self.http = http
        self.credentials = credentials
        self.storage = GenericProvider(
            spec: ProviderSpec(id: "mistral", displayName: "Mistral", url: "https://admin.mistral.ai"),
            http: http, credentials: credentials, manifestURL: manifestURL)
    }

    /// What the wizard can check live while you paste: presence of the
    /// required session cookie and the optional CSRF token. Cookie values are
    /// never returned, shown or stored by this check.
    public struct CookieCheck: Equatable, Sendable {
        public var hasSessionCookie: Bool
        public var hasCsrfToken: Bool
    }

    public static func checkCookieHeader(_ raw: String) -> CookieCheck {
        guard let header = MistralCookieHeader(raw) else {
            return CookieCheck(hasSessionCookie: false, hasCsrfToken: false)
        }
        return CookieCheck(
            hasSessionCookie: true,
            hasCsrfToken: header.csrfToken.map { !$0.isEmpty } ?? false)
    }

    public func accounts() async throws -> [AccountDescriptor] {
        try await storage.accounts()
    }

    /// Register a pasted `Cookie:` header (Settings → Mistral → paste). The
    /// same session re-pasted updates its account instead of adding another.
    public func addCookieHeader(_ raw: String, label: String?) throws -> AccountIdentity {
        guard let cookie = MistralCookieHeader(raw) else {
            throw invalidCookieError
        }
        return try storage.addKey(cookie.headerValue, label: label)
    }

    public func replaceCookieHeader(_ raw: String, accountID: String) throws {
        guard let cookie = MistralCookieHeader(raw) else {
            throw invalidCookieError
        }
        _ = try storage.replaceKey(cookie.headerValue, accountID: accountID)
    }

    public func removeCookieHeader(accountID: String) throws {
        try storage.removeKey(accountID: accountID)
    }

    public func renameCookieHeader(accountID: String, label: String?) throws {
        try storage.renameKey(accountID: accountID, label: label)
    }

    private var invalidCookieError: ProviderError {
        .badResponse(Localized.text(
            "Paste the Cookie request header from a signed-in admin.mistral.ai page. It must include an ory_session_ cookie.",
            "Lim inn Cookie-forespørselsoverskriften fra en innlogget side på admin.mistral.ai. Den må inneholde en ory_session_-cookie."))
    }

    public func refresh(account: AccountDescriptor) async throws -> UsageSnapshot {
        guard account.account.providerID == id,
              let raw = try credentials.secret(for: storage.credentialKey(account.account.id)),
              let cookie = MistralCookieHeader(raw) else { throw ProviderError.notLoggedIn }
        return try await fetchSnapshot(account: account.account, cookie: cookie)
    }

    /// Wizard step: verifies a pasted `Cookie:` header before anything is
    /// saved. Fetches exactly what a refresh would fetch, against a transient
    /// identity, and returns the snapshot the card would show. Nothing is
    /// stored; a failed preview leaves no trace.
    public func preview(_ raw: String) async throws -> UsageSnapshot {
        guard let cookie = MistralCookieHeader(raw) else { throw invalidCookieError }
        return try await fetchSnapshot(
            account: AccountIdentity(providerID: id, id: "mistral@preview"), cookie: cookie)
    }

    private func fetchSnapshot(
        account: AccountIdentity, cookie: MistralCookieHeader
    ) async throws -> UsageSnapshot {
        try Task.checkCancellation()

        var windows: [UsageWindow] = []
        var firstSourceError: (any Error)?

        // 1) Subscription page: included API and Vibe Code allowances.
        do {
            if let budgets = try await fetchBudgets(cookie) {
                if let api = budgets.api,
                   let window = Self.percentWindow("mistral.included", "Included", api.usedPercentage, api.resetsAt) {
                    windows.append(window)
                }
                if let vibe = budgets.vibe,
                   let window = Self.percentWindow("mistral.vibe", "Vibe", vibe.usedPercentage, vibe.resetsAt) {
                    windows.append(window)
                }
            }
        } catch {
            try propagateFatal(after: error)
            firstSourceError = firstSourceError ?? error
        }

        // 2) Vibe allowance fallback from the console when the page omits it.
        if !windows.contains(where: { $0.id == "mistral.vibe" }),
           let csrfToken = cookie.csrfToken, !csrfToken.isEmpty {
            do {
                if let vibe = try await fetchVibeFallback(cookie, csrfToken: csrfToken),
                   let window = Self.percentWindow("mistral.vibe", "Vibe", vibe.percentage, vibe.resetsAt) {
                    windows.append(window)
                }
            } catch {
                try propagateFatal(after: error)
                firstSourceError = firstSourceError ?? error
            }
        }

        // 3) Pay-as-you-go credit balance, best-effort.
        var creditsRemaining: Double?
        var creditsUnit: String?
        do {
            if let balance = try await fetchCredits(cookie) {
                creditsRemaining = balance.remaining
                creditsUnit = balance.currency
            }
        } catch {
            try propagateFatal(after: error)
            firstSourceError = firstSourceError ?? error
        }

        try Task.checkCancellation()
        guard !windows.isEmpty || creditsRemaining != nil else {
            throw firstSourceError ?? ProviderError.badResponse(Localized.text(
                "Mistral reported no subscription allowance or credit balance for this session.",
                "Mistral rapporterte ingen abonnementskvote eller kredittsaldo for denne økten."))
        }
        return UsageSnapshot(
            account: account,
            providerID: id,
            windows: windows,
            creditsRemaining: creditsRemaining,
            creditsUnit: creditsUnit)
    }

    /// A dead session fails every source, so auth and rate-limit failures end
    /// the whole refresh; other source failures only drop that source.
    private func propagateFatal(after error: Error) throws {
        if error is CancellationError { throw error }
        if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
        if let providerError = error as? ProviderError {
            switch providerError {
            case .unauthorized, .rateLimited: throw providerError
            default: break
            }
        }
        try Task.checkCancellation()
    }

    private static func percentWindow(
        _ id: String, _ label: String, _ usedPercentage: Double, _ resetsAt: Date?
    ) -> UsageWindow? {
        guard usedPercentage.isFinite, usedPercentage >= 0 else { return nil }
        return UsageWindow(
            id: id, label: label, kind: .consumption,
            used: usedPercentage, limit: 100, unit: "%", resetsAt: resetsAt)
    }

    // MARK: - Sources

    /// The subscription page. A missing/ambiguous budget payload is not an
    /// error — some plans expose no allowances on the page at all.
    private func fetchBudgets(_ cookie: MistralCookieHeader) async throws -> MistralSubscriptionBudgets? {
        let data = try await get(
            Self.subscriptionURL, headers: [
                "Cookie": cookie.headerValue,
                "Accept": "text/html",
                "Accept-Language": "en-US,en;q=0.9",
                "Referer": Self.subscriptionURL,
            ])
        guard let html = String(data: data, encoding: .utf8), !html.isEmpty else {
            throw ProviderError.badResponse("subscription page")
        }
        return try? MistralSubscriptionParser.parse(html: html)
    }

    private func fetchCredits(_ cookie: MistralCookieHeader) async throws -> (remaining: Double, currency: String)? {
        let data = try await get(
            Self.creditsURL, headers: [
                "Cookie": cookie.headerValue,
                "Accept": "*/*",
                "Referer": "https://admin.mistral.ai/organization/billing",
                "Origin": "https://admin.mistral.ai",
            ])
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let wallet = adapterNum(root, ["wallet_amount"]),
              let currency = (root["currency"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              wallet.isFinite, !currency.isEmpty
        else { return nil }
        let notes = adapterNum(root, ["credit_notes_amount"]) ?? 0
        let ongoing = adapterNum(root, ["ongoing_usage_balance"]) ?? 0
        guard notes.isFinite, ongoing.isFinite else { return nil }
        let remaining = max(0, wallet + notes - ongoing)
        guard remaining.isFinite else { return nil }
        return (remaining, currency)
    }

    /// The console's tRPC Vibe usage. Only the cookies console.mistral.ai
    /// needs are forwarded; other admin cookies stay origin-bound.
    private func fetchVibeFallback(
        _ cookie: MistralCookieHeader, csrfToken: String
    ) async throws -> (percentage: Double, resetsAt: Date?)? {
        let sessionPairs = cookie.pairs
            .filter { $0.name.hasPrefix("ory_session_") || $0.name == "csrftoken" }
            .map { "\($0.name)=\($0.value)" }
        guard !sessionPairs.isEmpty else { return nil }
        let data = try await get(
            Self.vibeFallbackURL, headers: [
                "Cookie": sessionPairs.joined(separator: "; "),
                "Accept": "*/*",
                "X-CSRFToken": csrfToken,
            ])
        guard let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let result = rows.first?["result"] as? [String: Any],
              let payload = result["data"] as? [String: Any],
              let json = payload["json"] as? [String: Any],
              let percentage = adapterNum(json, ["usage_percentage"]),
              percentage.isFinite, (0...100).contains(percentage)
        else { return nil }
        return (percentage, MistralSubscriptionParser.parseDate(json["reset_at"]))
    }

    private func get(_ urlString: String, headers: [String: String]) async throws -> Data {
        try Task.checkCancellation()
        let response = try await http.send(HTTPRequest(
            method: "GET",
            url: try OAuthRefresher.validatedURL(urlString),
            headers: headers,
            allowsRedirects: false))
        switch response.status {
        case 200..<300:
            return response.body
        case 300..<400, 401, 403:
            // A redirect is Mistral's answer to a dead session: the login flow.
            throw ProviderError.unauthorized
        case 429:
            throw ProviderError.rateLimited(retryAfter: response.retryAfter)
        default:
            throw ProviderError.serverError(response.status)
        }
    }
}
