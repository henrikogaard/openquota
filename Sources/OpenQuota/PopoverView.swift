#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// The popover: one card per (provider, account). Each card shows a meter per
/// window with remaining % + reset countdown, plus credits when present.
struct PopoverView: View {
    var model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            if model.snapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(model.snapshots, id: \.account.id) { snapshot in
                            AccountCard(snapshot: snapshot)
                        }
                    }
                    .padding(12)
                }
                .frame(maxHeight: 480)
            }

            Divider()
            footer
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "gauge").font(.title2)
            Text("No accounts yet")
                .font(.headline)
            Text("Add an API key or sign in to a provider's CLI to see usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { openSettings() }
                .controlSize(.small)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Button { model.refreshNow() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Refresh now")
            if model.refreshing { ProgressView().scaleEffect(0.5).frame(width: 12, height: 12) }
            Spacer()
            Menu {
                Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
                    .disabled(!UpdateController.shared.canCheckForUpdates)
                Divider()
                Button("Settings…") { openSettings() }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .buttonStyle(.borderless)
        .font(.callout)
    }
}

/// One provider-account card.
struct AccountCard: View {
    var snapshot: UsageSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            ForEach(snapshot.windows) { window in
                WindowRow(window: window)
            }
            if let credits = snapshot.creditsRemaining {
                Label {
                    Text("\(formatAmount(credits)) \(snapshot.creditsUnit ?? "credits") left")
                        .font(.caption)
                } icon: {
                    Image(systemName: "creditcard")
                        .foregroundStyle(.secondary)
                }
            }
            if let error = snapshot.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private var header: some View {
        HStack {
            Text(snapshot.providerID.capitalized)
                .font(.headline)
            if let label = snapshot.account.label {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
            }
            if snapshot.isStale {
                Text("Outdated")
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(.orange.opacity(0.2), in: .capsule)
            }
            Spacer()
            if let plan = snapshot.account.plan {
                Text(plan).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func formatAmount(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.2f", value)
    }
}

/// One quota window: thin meter + remaining % + reset countdown.
struct WindowRow: View {
    var window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(window.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let remaining = window.percentRemaining {
                    Text("\(Int(remaining))% left")
                        .font(.caption)
                        .monospacedDigit()
                } else if let remaining = window.remaining {
                    Text("\(format(remaining)) \(window.unit ?? "") left")
                        .font(.caption)
                        .monospacedDigit()
                }
            }
            if let fraction = window.fractionUsed {
                ProgressView(value: fraction)
                    .tint(color(fraction: fraction))
                    .scaleEffect(x: 1, y: 0.7, anchor: .center)
            }
            if let resetsAt = window.resetsAt {
                Text("Resets \(resetsAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func color(fraction: Double) -> Color {
        if fraction >= 0.9 { return .red }
        if fraction >= 0.7 { return .orange }
        return .accentColor
    }

    private func format(_ value: Double) -> String {
        value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }
}
#endif
