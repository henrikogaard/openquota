import Foundation

/// Optional OpenRouter-only readings. Kept separate from quota windows so period
/// spend and endpoint permissions never masquerade as an account allowance.
public struct OpenRouterDetails: Codable, Equatable, Sendable {
    public enum Issue: String, Codable, Sendable {
        case managementKeyRequired, unauthorized, unavailable, rateLimited

        public func message(balance: Bool) -> String {
            if self == .managementKeyRequired {
                return Localized.text("Account balance requires a management key. Key usage is separate.",
                                      "Kontosaldo krever en administrasjonsnøkkel. Nøkkelbruk vises separat.")
            }
            let scope = balance ? Localized.text("Account balance", "Kontosaldo")
                                : Localized.text("Key usage", "Nøkkelbruk")
            switch self {
            case .unauthorized:
                return Localized.text("\(scope): access denied. Check or replace the key in Settings.",
                                      "\(scope): tilgang avvist. Sjekk eller bytt nøkkel i Innstillinger.")
            case .rateLimited:
                return Localized.text("\(scope): rate limited. Will retry later.",
                                      "\(scope): for mange forespørsler. Prøver igjen senere.")
            default:
                return Localized.text("\(scope) is unavailable. Will retry on refresh.",
                                      "\(scope) er utilgjengelig. Prøver igjen ved oppdatering.")
            }
        }
    }

    public var totalSpend: Double?
    public var dailySpend: Double?
    public var monthlySpend: Double?
    public var balanceIssue: Issue?
    public var keyIssue: Issue?
    public var retryAfter: TimeInterval?

    public init(totalSpend: Double? = nil, dailySpend: Double? = nil, monthlySpend: Double? = nil,
                balanceIssue: Issue? = nil, keyIssue: Issue? = nil, retryAfter: TimeInterval? = nil) {
        self.totalSpend = totalSpend
        self.dailySpend = dailySpend
        self.monthlySpend = monthlySpend
        self.balanceIssue = balanceIssue
        self.keyIssue = keyIssue
        self.retryAfter = retryAfter
    }

    /// $0 disables warnings. Invalid stored preferences use the $5 default.
    public static func warningThreshold(_ stored: Double) -> Double {
        stored.isFinite && (0...1000).contains(stored) ? stored : 5
    }

    public static func isLowBalance(_ balance: Double?, threshold: Double) -> Bool {
        let threshold = warningThreshold(threshold)
        guard threshold > 0, let balance, balance.isFinite else { return false }
        return balance < threshold
    }

    public static func warningPreferenceKey(accountID: String) -> String {
        "openrouter.lowBalanceUSD.\(accountID)"
    }
}

/// Built-in adapter; GenericProvider continues to own credential bookkeeping.
enum OpenRouterReadings {
    private struct Reading: Sendable {
        var balance: Double?
        var usage: Double?
        var limit: Double?
        var remaining: Double?
        var daily: Double?
        var monthly: Double?
    }

    private struct Failure: Error, Sendable {
        var error: ProviderError
        var issue: OpenRouterDetails.Issue
    }

    private static func fetch(http: any HTTPClient, headers: [String: String],
                              balance: Bool) async throws -> Result<Reading, Failure> {
        do {
            let url = URL(string: "https://openrouter.ai/api/v1/\(balance ? "credits" : "key")")!
            let response = try await http.send(HTTPRequest(url: url, headers: headers, allowsRedirects: false))
            if balance && response.status == 403 {
                return .failure(Failure(error: .unauthorized, issue: .managementKeyRequired))
            }
            let data = try requireOK(response)
            guard let root = LenientJSON.object(with: data) else {
                throw ProviderError.badResponse("not JSON")
            }
            func number(_ field: String) -> Double? { JSONPath.double(root, at: "$.data.\(field)") }
            if balance {
                guard let purchased = number("total_credits"), let used = number("total_usage"),
                      (purchased - used).isFinite else {
                    throw ProviderError.badResponse("no recognized account balance")
                }
                return .success(Reading(balance: purchased - used))
            }
            guard let usage = number("usage") else {
                throw ProviderError.badResponse("no recognized key usage")
            }
            let limit = number("limit").flatMap { $0 >= 0 ? $0 : nil }
            // Lifetime usage cannot be subtracted from a resetting allowance.
            let resets = JSONPath.string(root, at: "$.data.limit_reset") != nil
            let remaining = limit.flatMap { limit in
                let candidate = number("limit_remaining") ?? (resets ? nil : limit - usage)
                return candidate.flatMap { $0.isFinite && (limit - $0).isFinite ? $0 : nil }
            }
            return .success(Reading(usage: usage, limit: limit, remaining: remaining,
                                    daily: number("usage_daily"), monthly: number("usage_monthly")))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            let error = error as? ProviderError ?? .network("request failed")
            let issue: OpenRouterDetails.Issue
            switch error {
            case .unauthorized: issue = .unauthorized
            case .rateLimited: issue = .rateLimited
            default: issue = .unavailable
            }
            return .failure(Failure(error: error, issue: issue))
        }
    }

    static func refresh(http: any HTTPClient, headers: [String: String],
                        account: AccountDescriptor) async throws -> UsageSnapshot {
        async let balanceResult = fetch(http: http, headers: headers, balance: true)
        async let keyResult = fetch(http: http, headers: headers, balance: false)
        let (balance, key) = try await (balanceResult, keyResult)
        try Task.checkCancellation()
        var details = OpenRouterDetails()
        var credits: Double?
        var windows: [UsageWindow] = []
        var failures: [ProviderError] = []
        switch balance {
        case .success(let reading): credits = reading.balance
        case .failure(let failure): details.balanceIssue = failure.issue; failures.append(failure.error)
        }
        switch key {
        case .success(let reading):
            details.totalSpend = reading.usage
            details.dailySpend = reading.daily
            details.monthlySpend = reading.monthly
            // When the API supplies remaining allowance, use it for the meter.
            // Lifetime spend stays separate in details for the currency row.
            windows = [UsageWindow(id: "openrouter.key usage", label: "Key usage", kind: .credits,
                                   used: reading.limit.flatMap { limit in reading.remaining.map { limit - $0 } } ?? reading.usage,
                                   limit: reading.remaining == nil ? nil : reading.limit,
                                   remaining: reading.remaining, unit: "$")]
        case .failure(let failure): details.keyIssue = failure.issue; failures.append(failure.error)
        }
        guard credits != nil || !windows.isEmpty else {
            throw failures.first(where: { if case .rateLimited = $0 { true } else { false } })
                ?? failures.first ?? ProviderError.badResponse("no recognized usage fields")
        }
        details.retryAfter = failures.compactMap { error -> TimeInterval? in
            if case .rateLimited(let delay) = error { return delay }
            return nil
        }.max()
        return UsageSnapshot(account: account.account, providerID: "openrouter", windows: windows,
                             creditsRemaining: credits, creditsUnit: "USD", openRouter: details)
    }
}
