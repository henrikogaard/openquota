import Foundation

public enum MenuBarDisplayStyle: String, CaseIterable, Sendable {
    case iconOnly
    case percentageOnly
    case iconAndPercentage
    case providerAndPercentage

    public static func resolve(_ stored: String, legacyShowsPercent: Bool) -> Self {
        Self(rawValue: stored) ?? (legacyShowsPercent ? .iconAndPercentage : .iconOnly)
    }
}

public struct MenuBarReading: Sendable {
    public var snapshot: UsageSnapshot
    public var window: UsageWindow
    public var percentRemaining: Double

    /// An unavailable pinned source stays unavailable; it never switches accounts.
    public static func select(
        from snapshots: [UsageSnapshot],
        accountID: String = "",
        windowID: String = ""
    ) -> Self? {
        let candidates = snapshots
            .filter { accountID.isEmpty || $0.account.id == accountID }
            .flatMap { snapshot in
                snapshot.windows.compactMap { window -> Self? in
                    guard accountID.isEmpty || windowID.isEmpty || window.id == windowID,
                          [window.used, window.limit, window.remaining]
                            .compactMap({ $0 }).allSatisfy({ $0.isFinite }),
                          let percent = window.percentRemaining, percent.isFinite else { return nil }
                    return Self(snapshot: snapshot, window: window, percentRemaining: percent)
                }
            }
        return candidates.min {
            if $0.percentRemaining != $1.percentRemaining {
                return $0.percentRemaining < $1.percentRemaining
            }
            if $0.snapshot.account.id != $1.snapshot.account.id {
                return $0.snapshot.account.id < $1.snapshot.account.id
            }
            return $0.window.id < $1.window.id
        }
    }
}
