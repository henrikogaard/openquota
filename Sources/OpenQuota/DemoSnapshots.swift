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
                account: .init(providerID: "opencode-go", id: "demo-oc2", label: "Work key"),
                providerID: "opencode-go",
                errorMessage: ProviderError.unauthorized.userMessage),
            UsageSnapshot(
                account: .init(providerID: "openrouter", id: "demo-key1", label: "Personal key"),
                providerID: "openrouter", creditsRemaining: 18.75, creditsUnit: "USD"),
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
