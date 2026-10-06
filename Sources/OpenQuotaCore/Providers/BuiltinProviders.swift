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
            map.creditsUsed = "$.data.total_usage"
            map.creditsUnitLabel = "USD"
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

/// Assembles every provider the app knows: the bundled spec library +
/// user-defined specs + hand-written adapters (local credentials, OAuth
/// refresh, Connect/protobuf — the shapes GenericProvider can't express).
public struct ProviderRegistry: Sendable {
    public var providers: [any UsageProvider]

    public init(
        http: any HTTPClient,
        credentials: any CredentialStore,
        extraSpecs: [ProviderSpec] = [],
        adapters: [any UsageProvider]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        var seen = Set<String>()
        let specs = (extraSpecs + SpecLibrary.all).filter { seen.insert($0.id).inserted }
        var list: [any UsageProvider] = specs.map {
            GenericProvider(spec: $0, http: http, credentials: credentials)
        }
        list.append(contentsOf: (adapters
            ?? Adapters.all(http: http, credentials: credentials)).filter { seen.insert($0.id).inserted })
        list.append(contentsOf: CLIProviders.all(environment: environment).filter { seen.insert($0.id).inserted })
        self.providers = list
    }
}
