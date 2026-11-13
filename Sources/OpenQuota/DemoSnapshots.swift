#if os(macOS)
import Foundation
import OpenQuotaCore

enum DemoSnapshots {
    static var all: [UsageSnapshot] {
        [
            UsageSnapshot(
                account: .init(providerID: "claude", id: "demo-claude", label: "Personal", plan: "Max"),
                providerID: "claude",
                windows: [
                    .init(id: "5h", label: "Session", used: 32, limit: 100, unit: "%",
                          resetsAt: Date().addingTimeInterval(7_400)),
                    .init(id: "week", label: "Weekly", used: 12, limit: 100, unit: "%",
                          resetsAt: Date().addingTimeInterval(320_000)),
                ]),
            UsageSnapshot(
                account: .init(providerID: "codex", id: "demo-codex", label: "ChatGPT", plan: "Plus"),
                providerID: "codex",
                windows: [
                    .init(id: "5h", label: "Session", used: 84, limit: 100, unit: "%",
                          resetsAt: Date().addingTimeInterval(3_600)),
                    .init(id: "week", label: "Weekly", used: 41, limit: 100, unit: "%",
                          resetsAt: Date().addingTimeInterval(400_000)),
                ],
                creditsRemaining: 12.40, creditsUnit: "USD"),
            UsageSnapshot(
                account: .init(providerID: "opencode", id: "demo-oc1", label: "Personal"),
                providerID: "opencode",
                windows: [
                    .init(id: "rolling", label: "Session", used: 6, limit: 100, unit: "%",
                          resetsAt: Date().addingTimeInterval(15_000)),
                    .init(id: "weekly", label: "Weekly", used: 27, limit: 100, unit: "%",
                          resetsAt: Date().addingTimeInterval(500_000)),
                    .init(id: "monthly", label: "Monthly", used: 93, limit: 100, unit: "%",
                          resetsAt: Date().addingTimeInterval(1_500_000)),
                ]),
            UsageSnapshot(
                account: .init(providerID: "opencode-console", id: "demo-console#workspace", label: "Console workspace"),
                providerID: "opencode-console",
                windows: [
                    .init(id: "console.5h", label: "5h", used: 25, limit: 100, unit: "%"),
                    .init(id: "console.budget", label: "Budget $50", kind: .credits, used: 12.5, limit: 50, unit: "$"),
                ],
                creditsRemaining: 12.34, creditsUnit: "USD"),
            UsageSnapshot(
                account: .init(providerID: "opencode-go", id: "demo-oc2", label: "Work key"),
                providerID: "opencode-go",
                errorMessage: ProviderError.unauthorized.userMessage),
            UsageSnapshot(
                account: .init(providerID: "openrouter", id: "demo-key1", label: "Personal key"),
                providerID: "openrouter",
                windows: [.init(id: "openrouter.key usage", label: "Key usage", kind: .credits,
                                used: 3, limit: 10, remaining: 7, unit: "$")],
                creditsRemaining: 3.75, creditsUnit: "USD",
                openRouter: .init(totalSpend: 3, dailySpend: 0.50, monthlySpend: 3)),
            UsageSnapshot(
                account: .init(providerID: "mistral", id: "demo-mistral", label: "Pro"),
                providerID: "mistral",
                windows: [
                    .init(id: "mistral.included", label: "Included", used: 36, limit: 100, unit: "%",
                          resetsAt: Date().addingTimeInterval(120_000)),
                    .init(id: "mistral.vibe", label: "Vibe", used: 58, limit: 100, unit: "%",
                          resetsAt: Date().addingTimeInterval(120_000)),
                ],
                creditsRemaining: 4.20, creditsUnit: "EUR"),
            UsageSnapshot(
                account: .init(providerID: "grok", id: "demo-grok", label: "henrik@example.com"),
                providerID: "grok",
                windows: [.init(id: "week", label: "Weekly", used: 45, limit: 100, unit: "%",
                                resetsAt: Date().addingTimeInterval(200_000))],
                fetchedAt: Date().addingTimeInterval(-900), isStale: true),
        ]
    }
}
#endif
