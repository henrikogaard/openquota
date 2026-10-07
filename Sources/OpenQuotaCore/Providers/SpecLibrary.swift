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

    /// Vibe Code activity. Mistral does not expose a personal remaining allowance here.
    public static let mistral = ProviderSpec(
        id: "mistral",
        displayName: "Mistral Vibe",
        url: "https://api.mistral.ai/v1/admin/analytics/vibe/code/usage/by_workspace?start_time={d30}&end_time={now}",
        auth: .bearer,
        dashboardURL: "https://admin.mistral.ai/plateforme/billing",
        unverified: true,
        windows: [
            .init(
                label: "Sessions (30d)", kind: .requests,
                used: "sum:$.sessions[*].nb_sessions", unit: "sessions"
            ),
            .init(label: "Input (30d)", kind: .requests,
                  used: "sum:$.consumed_tokens[*].input_tokens", unit: "tokens"),
            .init(label: "Output (30d)", kind: .requests,
                  used: "sum:$.consumed_tokens[*].output_tokens", unit: "tokens")
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

    /// Full bundled library: the two fixture-tested specs + the doc-mapped tail.
    // MARK: - Documented API-key providers (endpoints mirrored from CodexBar's
    // public-API integrations; all unverified against live accounts).

    /// ClinePass — subscription limits (five_hour / weekly / monthly) by type.
    public static let clinePass = ProviderSpec(
        id: "clinepass",
        displayName: "ClinePass",
        url: "https://api.cline.bot/api/v1/users/me/plan/usage-limits",
        dashboardURL: "https://app.cline.bot",
        windows: ["five_hour": "5 hours", "weekly": "Week", "monthly": "Month"]
            .sorted { $0.key < $1.key }
            .map { type, label in
                .init(label: label, kind: .consumption,
                      used: "$.data.limits[type=\(type)].percentUsed",
                      resetsAt: "$.data.limits[type=\(type)].resetsAt", unit: "%")
            }
    )

    /// Vercel AI Gateway — team credit balance and lifetime spend (decimal strings).
    public static let vercelGateway = ProviderSpec(
        id: "vercel-ai-gateway",
        displayName: "Vercel AI Gateway",
        url: "https://ai-gateway.vercel.sh/v1/credits",
        dashboardURL: "https://vercel.com/dashboard/ai-gateway",
        map: {
            var map = ProviderSpec.FieldMap()
            map.creditsRemaining = "$.balance"
            map.creditsUnitLabel = "USD"
            return map
        }(),
        windows: [
            .init(label: "Balance", kind: .credits, remaining: "$.balance", unit: "$"),
            .init(label: "Lifetime spend", kind: .credits, used: "$.total_used", unit: "$"),
        ]
    )

    /// Atlas Cloud — account-wide available USD balance.
    public static let atlasCloud = ProviderSpec(
        id: "atlascloud",
        displayName: "Atlas Cloud",
        url: "https://api.atlascloud.ai/public/v1/balance",
        dashboardURL: "https://www.atlascloud.ai/console",
        map: {
            var map = ProviderSpec.FieldMap()
            map.creditsRemaining = "$.available.value"
            map.creditsUnitLabel = "USD"
            return map
        }(),
        windows: [.init(label: "Balance", kind: .credits, remaining: "$.available.value", unit: "$")]
    )

    /// Poe — current point balance.
    public static let poe = ProviderSpec(
        id: "poe",
        displayName: "Poe",
        url: "https://api.poe.com/usage/current_balance",
        dashboardURL: "https://poe.com/api/keys",
        windows: [.init(label: "Points", kind: .credits,
                        remaining: "$.current_point_balance", unit: "points")]
    )

    /// ZenMux — rolling 5-hour and 7-day flow quotas (Management API key).
    public static let zenMux = ProviderSpec(
        id: "zenmux",
        displayName: "ZenMux",
        url: "https://zenmux.ai/api/v1/management/subscription/detail",
        dashboardURL: "https://zenmux.ai/platform/management",
        map: {
            var map = ProviderSpec.FieldMap()
            map.plan = "$.data.plan.tier"
            return map
        }(),
        windows: [
            .init(label: "5 hours", kind: .consumption,
                  used: "$.data.quota_5_hour.used_flows", limit: "$.data.quota_5_hour.max_flows",
                  resetsAt: "$.data.quota_5_hour.resets_at", unit: "flows"),
            .init(label: "Week", kind: .consumption,
                  used: "$.data.quota_7_day.used_flows", limit: "$.data.quota_7_day.max_flows",
                  resetsAt: "$.data.quota_7_day.resets_at", unit: "flows"),
        ]
    )

    /// DevPass (LLM Gateway) — billing-cycle plan credits + premium weekly allowance.
    public static let devPass = ProviderSpec(
        id: "devpass",
        displayName: "DevPass",
        url: "https://api.llmgateway.io/v1/key",
        dashboardURL: "https://llmgateway.io/dashboard",
        map: {
            var map = ProviderSpec.FieldMap()
            map.plan = "$.data.devPlan"
            return map
        }(),
        windows: [
            .init(label: "Plan credits", kind: .consumption,
                  used: "$.data.devPlanCreditsUsed", limit: "$.data.devPlanCreditsLimit", unit: "$"),
            .init(label: "Premium week", kind: .consumption,
                  used: "$.data.devPlanPremiumCreditsUsed", limit: "$.data.devPlanPremiumWeeklyLimit",
                  resetsAt: "$.data.devPlanPremiumWeekResetsAt", unit: "$"),
            .init(label: "Key spend", kind: .credits,
                  used: "$.data.usage", limit: "$.data.limit", unit: "$"),
        ]
    )

    /// v0 Platform API — token-billing balance (or legacy allowance) + request rate limit.
    public static let v0 = ProviderSpec(
        id: "v0",
        displayName: "v0",
        url: "https://api.v0.dev/v1/user/billing",
        dashboardURL: "https://v0.app/settings/billing",
        windows: [
            .init(label: "Billing", kind: .credits,
                  limit: "$.data.balance.total", remaining: "$.data.balance.remaining",
                  resetsAt: "$.data.billingCycle.end", unit: "credits"),
            .init(label: "Allowance", kind: .credits,
                  limit: "$.data.limit", remaining: "$.data.remaining",
                  resetsAt: "$.data.reset", unit: "credits"),
            .init(label: "Requests", kind: .requests,
                  url: "https://api.v0.dev/v1/rate-limits",
                  limit: "$.limit", remaining: "$.remaining", resetsAt: "$.reset", unit: "requests"),
        ]
    )

    /// Codebuff — credit usage/balance and next quota reset (API key).
    public static let codebuff = ProviderSpec(
        id: "codebuff",
        displayName: "Codebuff",
        url: "https://www.codebuff.com/api/v1/usage",
        method: "POST",
        body: #"{"fingerprintId":"openquota-usage"}"#,
        dashboardURL: "https://www.codebuff.com/usage",
        map: {
            var map = ProviderSpec.FieldMap()
            map.creditsRemaining = "$.remainingBalance"
            map.creditsUnitLabel = "credits"
            return map
        }(),
        windows: [.init(label: "Credits", kind: .consumption,
                        used: "$.usage", limit: "$.quota",
                        resetsAt: "$.next_quota_reset", unit: "credits")]
    )

    /// OpenCode Go — the same key OpenCode stores as `opencode-go` in auth.json,
    /// pasted directly so several subscriptions can be tracked side by side.
    public static let opencodeGo = ProviderSpec(
        id: "opencode-go",
        displayName: "OpenCode Go",
        url: "https://opencode.ai/zen/go/v1/usage",
        dashboardURL: "https://opencode.ai/zen",
        map: {
            var map = ProviderSpec.FieldMap()
            map.creditsRemaining = "$.usage.balance"
            map.creditsUnit = "$"
            return map
        }(),
        windows: [("5h", "rolling"), ("Week", "weekly"), ("Month", "monthly")].map { label, key in
            .init(
                label: label, kind: .consumption,
                used: "$.usage.\(key).percent",
                resetsAt: "$.usage.\(key).resetsAt",
                unit: "%"
            )
        }
    )

    public static let all: [ProviderSpec] = [
        BuiltinProviders.openRouter,
        BuiltinProviders.requesty,
        opencodeGo,
        deepseek, moonshot, zai, elevenLabs, minimax, synthetic,
        kilo, venice, openAIAdmin, warp, perplexity,
        clinePass, vercelGateway, atlasCloud, poe, zenMux, devPass, v0, codebuff
    ]
}
