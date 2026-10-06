import Foundation

/// Built-in spec-driven providers. These are "bearer key + JSON endpoint"
/// providers — the exact shape GenericProvider exists for. Providers needing
/// OAuth refresh or Connect/protobuf get a hand-written adapter instead.
public enum BuiltinProviders {

    /// OpenRouter: credit balance + key usage.
    /// GET /api/v1/credits → {"data": {"total_credits": N, "total_usage": N}}
    /// GET /api/v1/key     → {"data": {"label": str, "limit": N|null, "usage": N}}
    public static let openRouter = ProviderSpec(
        id: "openrouter",
        displayName: "OpenRouter",
        url: "https://openrouter.ai/api/v1/credits",
        dashboardURL: "https://openrouter.ai/settings/credits",
        identityLabel: nil,
        map: {
            var map = ProviderSpec.FieldMap()
            map.creditsRemaining = "$.data.total_credits"
            map.creditsUnit = nil // credits unit is implied USD on OpenRouter
            return map
        }(),
        windows: [
            .init(
                label: "Credits",
                kind: .credits,
                // /api/v1/key: usage + optional limit; credits endpoint gives the balance.
                url: "https://openrouter.ai/api/v1/key",
                used: "$.data.usage",
                limit: "$.data.limit",
                unit: "$"
            )
        ]
    )

    /// Requesty: organization balance + aggregated usage.
    /// GET api-v2.requesty.ai/v1/manage/org → org info incl. current balance
    /// (field names per https://docs.requesty.ai — tolerantly mapped).
    public static let requesty = ProviderSpec(
        id: "requesty",
        displayName: "Requesty",
        url: "https://api-v2.requesty.ai/v1/manage/org",
        dashboardURL: "https://app.requesty.ai",
        windows: [
            .init(
                label: "Balance",
                kind: .credits,
                remaining: "$.balance",
                unit: "$"
            )
        ]
    )

    public static let all: [ProviderSpec] = [openRouter, requesty]
}

/// Assembles every provider the app knows: spec-driven built-ins + (later)
/// hand-written adapters for Claude/Codex/Cursor/Grok/Devin/OpenCode/Mistral.
public struct ProviderRegistry: Sendable {
    public var providers: [any UsageProvider]

    public init(http: any HTTPClient, credentials: any CredentialStore,
                extraSpecs: [ProviderSpec] = []) {
        self.providers = (BuiltinProviders.all + extraSpecs).map {
            GenericProvider(spec: $0, http: http, credentials: credentials)
        }
    }
}
