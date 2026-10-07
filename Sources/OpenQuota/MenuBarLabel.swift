#if os(macOS)
import SwiftUI
import OpenQuotaCore

/// Menu-bar presence: a gauge whose needle follows the tightest remaining
/// quota, plus (optionally) the percentage. Stale readings dim the number.
struct MenuBarLabel: View {
    var model: AppModel
    @AppStorage("menuBarShowsPercent") private var showsPercent = true

    private var tightest: UsageSnapshot? {
        model.snapshots
            .filter { $0.lowestPercentRemaining != nil }
            .min { ($0.lowestPercentRemaining ?? 100) < ($1.lowestPercentRemaining ?? 100) }
    }

    private var symbol: String {
        guard let left = tightest?.lowestPercentRemaining else { return "gauge.with.dots.needle.33percent" }
        switch left {
        case ..<10: return "gauge.with.dots.needle.0percent"
        case ..<40: return "gauge.with.dots.needle.33percent"
        case ..<60: return "gauge.with.dots.needle.50percent"
        case ..<90: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
            if showsPercent, let tightest, let lowest = tightest.lowestPercentRemaining {
                Text("\(Int(lowest.rounded()))%")
                    .monospacedDigit()
                    .opacity(tightest.isStale ? 0.5 : 1)
            }
        }
        .accessibilityLabel(tightest?.lowestPercentRemaining.map { L("OpenQuota, \(Int($0)) percent left", "OpenQuota, \(Int($0)) prosent igjen") } ?? "OpenQuota")
    }
}
#endif
