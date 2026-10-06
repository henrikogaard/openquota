#if os(macOS)
import SwiftUI
import OpenQuotaCore

/// Menu-bar presence: a small gauge + the worst remaining-% across accounts.
/// Numbers only — one glance answers "how much do I have left".
struct MenuBarLabel: View {
    var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge")
            if let lowest = model.snapshots.compactMap(\.lowestPercentRemaining).min() {
                Text("\(Int(lowest))%\(model.snapshots.contains(where: \.isStale) ? "!" : "")")
                    .monospacedDigit()
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
            }
            if model.refreshing {
                ProgressView().scaleEffect(0.4).frame(width: 8, height: 8)
            }
        }
    }
}
#endif
