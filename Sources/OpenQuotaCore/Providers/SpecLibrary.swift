import Foundation

/// The bundled spec library: every provider expressible as "credential + JSON
/// endpoint". Specs marked `unverified` have endpoint/mapping taken from public
/// docs or CodexBar's implementation but not yet exercised against a live
/// account — they fail safe (row shows the error, other providers unaffected).
///
/// Intentionally absent:
/// - Providers with no usage endpoint (GroqCloud exposes only rate-limit
///   headers; Doubao probes a deployment, not a quota).
/// - Proxy providers needing a user-supplied base URL (LiteLLM, LLM Proxy,
///   ClawRouter) — need a spec `baseURL` field; TODO.
/// - Cookie-only providers other than Perplexity — the `.cookie` auth path
///   exists for custom specs, see docs/providers.md.
public enum SpecLibrary {

    /// DeepSeek — GET /user/balance returns balance_infos[] (strings).
    public static let deepseek = ProviderSpec(
        id: "deepseek",
        displayName: "DeepSeek",
        url: "https://api.deepseek.com/user/balance",
        dashboardURL: "https://platform.deepseek.com/usage",
        map: {
            var map = ProviderSpec.FieldMap()
            map.creditsRemaining = "$.balance_infos[0].total_balance"
            map.creditsUnit = "$.balance_infos[0].currency"
            return map
        }(),
        windows: [
            .init(
                label: "Balance", kind: .credits,
                remaining: "$.balance_infos[0].total_balance",
                unit: "$"
            )
        ]
    )

    /// Moonshot AI platform — GET /v1/users/me/balance → data.available_balance.
    public static let moonshot = ProviderSpec(
        id: "moonshot",
        displayName: "Moonshot",
        url: "https://api.moonshot.ai/v1/users/me/balance",
        dashboardURL: "https://platform.moonshot.ai/console/account",
        map: {
            var map = ProviderSpec.FieldMap()
            map.creditsRemaining = "$.data.available_balance"
            map.creditsUnit = "$"
            return map
        }(),
        windows: [
            .init(
                label: "Balance", kind: .credits,
                remaining: "$.data.available_balance", unit: "$"
            )
        ]
    )

    /// z.ai GLM Coding Plan — quota API returns a limits[] array filtered by
    /// `type` (TIME_LIMIT = 5h session, TOKENS_LIMIT = weekly tokens,
    /// WEB_SEARCH = search calls). percentage = percent remaining;
    /// nextResetTime is epoch milliseconds.
    public static let zai = ProviderSpec(
        id: "zai",
        displayName: "z.ai",
        url: "https://api.z.ai/api/monitor/usage/quota/limit",
        dashboardURL: "https://z.ai/subscribe",
        unverified: true,
        windows: [
            .init(
                label: "5h", kind: .consumption,
                remaining: "$.data.limits[type=TIME_LIMIT].percentage",
                resetsAt: "$.data.limits[type=TIME_LIMIT].nextResetTime",
                resetsAtFormat: "epochMillis", unit: "%"
            ),
            .init(
                label: "Weekly", kind: .consumption,
                remaining: "$.data.limits[type=TOKENS_LIMIT].percentage",
                resetsAt: "$.data.limits[type=TOKENS_LIMIT].nextResetTime",
                resetsAtFormat: "epochMillis", unit: "%"
            ),
            .init(
                label: "Search", kind: .requests,
                remaining: "$.data.limits[type=WEB_SEARCH].percentage",
                unit: "%"
            )
        ]
    )

    /// ElevenLabs — subscription endpoint exposes character quota + reset.
    /// Auth is the xi-api-key header.
    public static let elevenLabs = ProviderSpec(
        id: "elevenlabs",
        displayName: "ElevenLabs",
        url: "https://api.elevenlabs.io/v1/user/subscription",
        auth: .header, authHeader: "xi-api-key",
        dashboardURL: "https://elevenlabs.io/app/usage",
        map: {
            var map = ProviderSpec.FieldMap()
            map.plan = "$.tier"
            return map
        }(),
        windows: [
            .init(
                label: "Characters", kind: .requests,
                used: "$.character_count", limit: "$.character_limit",
                resetsAt: "$.next_character_count_reset_unix",
                resetsAtFormat: "epochSeconds"
            )
        ]
    )

    /// MiniMax Coding Plan — remains endpoint lists per-model interval counts
    /// and a weekly bucket. Best-guess field mapping — unverified.
    public static let minimax = ProviderSpec(
        id: "minimax",
        displayName: "MiniMax",
        url: "https://api.minimax.io/v1/api/openplatform/coding_plan/remains",
        dashboardURL: "https://platform.minimax.io/user-center/basic-information",
        unverified: true,
        windows: [
            .init(
                label: "5h", kind: .requests,
                used: "$.model_remains[0].current_interval_usage_count",
                limit: "$.model_remains[0].current_interval_total_count",
                resetsAt: "$.model_remains[0].end_time",
                resetsAtFormat: "epochMillis"
            ),
            .init(
                label: "Weekly", kind: .requests,
                used: "$.weekly_remains[0].used_count",
                limit: "$.weekly_remains[0].total_count",
                resetsAt: "$.weekly_remains[0].end_time",
                resetsAtFormat: "epochMillis"
            )
        ]
    )

    /// Synthetic — subscription quota + pay-as-you-go balance. Unverified.
    public static let synthetic = ProviderSpec(
        id: "synthetic",
        displayName: "Synthetic",
        url: "https://api.synthetic.new/v2/quotas",
        dashboardURL: "https://synthetic.new/dashboard",
        unverified: true,
        map: {
            var map = ProviderSpec.FieldMap()
            map.creditsRemaining = "$.data.payg.balance"
            map.creditsUnit = "$"
            return map
        }(),
        windows: [
            .init(
                label: "Subscription", kind: .consumption,
                used: "$.data.subscription.usage",
                limit: "$.data.subscription.limit",
                resetsAt: "$.data.subscription.renewAt"
            )
        ]
    )

    /// Kilo — gateway balance. Unverified.
    public static let kilo = ProviderSpec(
        id: "kilo",
        displayName: "Kilo",
        url: "https://kilocode.ai/api/users/me/balance",
        dashboardURL: "https://kilocode.ai/profile",
        unverified: true,
        map: {
            var map = ProviderSpec.FieldMap()
            map.creditsRemaining = "$.balance"
            map.creditsUnit = "$"
            return map
        }(),
        windows: [
            .init(label: "Balance", kind: .credits, remaining: "$.balance", unit: "$")
        ]
    )

    /// Venice — API-key list carries DIEM/USD consumption. Unverified.
    public static let venice = ProviderSpec(
        id: "venice",
        displayName: "Venice",
        url: "https://api.venice.ai/api/v1/apikeys",
        dashboardURL: "https://venice.ai/settings/api",
        unverified: true,
        map: {
            var map = ProviderSpec.FieldMap()
            map.creditsRemaining = "$.data[0].consumption.diem"
            map.creditsUnit = "DIEM"
            return map
        }(),
        windows: [
            .init(
                label: "USD", kind: .credits,
                used: "$.data[0].consumption.usd", unit: "$"
            )
        ]
    )

    /// Mistral (admin key) — org usage endpoint. Unverified.
    public static let mistral = ProviderSpec(
        id: "mistral",
        displayName: "Mistral",
        url: "https://api.mistral.ai/v1/admin/usage",
        auth: .apiKeyHeader,
        dashboardURL: "https://admin.mistral.ai/plateforme/billing",
        unverified: true,
        windows: [
            .init(
                label: "Month", kind: .consumption,
                used: "$.data.usage", unit: "$"
            )
        ]
    )

    /// OpenAI Admin API — organization costs rolled up over 30 days. Requires
    /// an org admin key. Sums amount.value across buckets — the `sum:` path
    /// exists for exactly this. Unverified.
    public static let openAIAdmin = ProviderSpec(
        id: "openai",
        displayName: "OpenAI",
        url: "https://api.openai.com/v1/organization/costs?start_time={d30}&group_by=line_item",
        dashboardURL: "https://platform.openai.com/usage",
        unverified: true,
        windows: [
            .init(
                label: "Spend 30d", kind: .credits,
                used: "sum:$.data[*].results[*].amount.value", unit: "$"
            )
        ]
    )

    /// Warp — GraphQL request-limit info via POST body. Unverified.
    public static let warp = ProviderSpec(
        id: "warp",
        displayName: "Warp",
        url: "https://app.warp.dev/graphql",
        method: "POST",
        body: """
            {"operationName":"GetRequestLimitInfo","variables":{},"query":"query GetRequestLimitInfo { requestLimitInfo { isUnlimited requestLimit requestsUsedSincePeriodStart nextLimitResetTime } }"}
            """,
        dashboardURL: "https://app.warp.dev/settings/usage",
        unverified: true,
        windows: [
            .init(
                label: "Requests", kind: .requests,
                used: "$.data.requestLimitInfo.requestsUsedSincePeriodStart",
                limit: "$.data.requestLimitInfo.requestLimit",
                resetsAt: "$.data.requestLimitInfo.nextLimitResetTime"
            )
        ]
    )

    /// Perplexity — no public API for Pro credits; paste the session cookie
    /// (DevTools → request headers → Cookie) into Settings. Rot does not crash:
    /// the row shows an error until re-pasted. Unverified.
    public static let perplexity = ProviderSpec(
        id: "perplexity",
        displayName: "Perplexity",
        url: "https://www.perplexity.ai/api/credits",
        auth: .cookie,
        dashboardURL: "https://www.perplexity.ai/settings/billing",
        unverified: true,
        windows: [
            .init(
                label: "Credits", kind: .credits,
                remaining: "$.data.credits", unit: "$"
            )
        ]
    )

    /// Full bundled library: the two verified specs + the doc-mapped tail.
    public static let all: [ProviderSpec] = [
        BuiltinProviders.openRouter,
        BuiltinProviders.requesty,
        deepseek, moonshot, zai, elevenLabs, minimax, synthetic,
        kilo, venice, mistral, openAIAdmin, warp, perplexity
    ]
}
