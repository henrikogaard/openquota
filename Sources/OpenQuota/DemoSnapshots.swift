#if os(macOS)
import Foundation
import OpenQuotaCore

enum DemoSnapshots {
    static var all: [UsageSnapshot] {
        [
            UsageSnapshot(
                account: .init(providerID: "claude", id: "demo-claude", label: "Personal", plan: "Pro"),
                providerID: "claude",
                windows: [
                    .init(id: "5h", label: "5 hours", used: 32, limit: 100,
                          resetsAt: Date().addingTimeInterval(7_200)),
                    .init(id: "week", label: "Week", used: 12, limit: 100,
                          resetsAt: Date().addingTimeInterval(172_800)),
                ]),
            UsageSnapshot(
                account: .init(providerID: "codex", id: "demo-codex", label: "Work", plan: "Plus"),
                providerID: "codex",
                windows: [.init(id: "5h", label: "5 hours", used: 84, limit: 100,
                                resetsAt: Date().addingTimeInterval(3_600))]),
            UsageSnapshot(
                account: .init(providerID: "openrouter", id: "demo-key1", label: "Personal key"),
                providerID: "openrouter", creditsRemaining: 18.75, creditsUnit: "USD"),
            UsageSnapshot(
                account: .init(providerID: "openrouter", id: "demo-key2", label: "Work key"),
                providerID: "openrouter", creditsRemaining: 42.50, creditsUnit: "USD"),
            UsageSnapshot(
                account: .init(providerID: "grok", id: "demo-grok", label: "Personal"),
                providerID: "grok",
                windows: [.init(id: "week", label: "Week", used: 45, limit: 100)],
                fetchedAt: Date().addingTimeInterval(-900), isStale: true,
                errorMessage: "Credentials rejected (re-login?)"),
        ]
    }
}
#endif
