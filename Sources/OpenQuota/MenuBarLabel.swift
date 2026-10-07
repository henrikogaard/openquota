#if os(macOS)
import SwiftUI
import OpenQuotaCore

/// Menu-bar presence: a gauge and the tightest remaining percentage.
/// Stale readings dim the number rather than adding punctuation.
struct MenuBarLabel: View {
    var model: AppModel

    private var tightest: UsageSnapshot? {
        model.snapshots
            .filter { $0.lowestPercentRemaining != nil }
            .min { ($0.lowestPercentRemaining ?? 100) < ($1.lowestPercentRemaining ?? 100) }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "gauge.with.dots.needle.33percent")
            if let tightest, let lowest = tightest.lowestPercentRemaining {
                Text("\(Int(lowest.rounded()))%")
                    .monospacedDigit()
                    .opacity(tightest.isStale ? 0.5 : 1)
            }
        }
        .accessibilityLabel(tightest?.lowestPercentRemaining.map { "OpenQuota, \(Int($0)) percent left" } ?? "OpenQuota")
    }
}
#endif
