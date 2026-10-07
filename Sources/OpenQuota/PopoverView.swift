#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// The popover: providers as quiet sections, one compact block per account,
/// one thin meter per quota window. Color appears only when it means something.
struct PopoverView: View {
    var model: AppModel
    @Environment(\.openSettings) private var openSettings

    /// Grouped by display name so one product (e.g. OpenCode Go from a local
    /// file and from pasted keys) reads as a single section.
    private var groups: [(providerID: String, snapshots: [UsageSnapshot])] {
        var order: [String] = []
        var firstID: [String: String] = [:]
        var byName: [String: [UsageSnapshot]] = [:]
        for snapshot in model.snapshots {
            let name = model.providerName(snapshot.providerID)
            if byName[name] == nil { order.append(name); firstID[name] = snapshot.providerID }
            byName[name, default: []].append(snapshot)
        }
        return order.map { (firstID[$0] ?? $0, byName[$0] ?? []) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if model.snapshots.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Tokens.sectionSpacing) {
                        ForEach(groups, id: \.providerID) { group in
                            ProviderSection(
                                name: model.providerName(group.providerID),
                                dashboardURL: model.dashboardURL(group.providerID),
                                snapshots: group.snapshots)
                        }
                    }
                    .padding(.horizontal, Tokens.inset)
                    .padding(.vertical, 12)
                }
                .scrollIndicators(.never)
                // A window-style MenuBarExtra can't infer a scroll view's height.
                .frame(height: contentHeight)
            }
            if let status = model.statusMessage {
                Divider().opacity(0.5)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Tokens.inset)
                    .padding(.vertical, 8)
            }
        }
        .frame(width: Tokens.popoverWidth)
    }

    private var contentHeight: CGFloat {
        var height: CGFloat = 24
        for group in groups {
            height += 22 + Tokens.sectionSpacing
            for snapshot in group.snapshots {
                height += 22
                height += CGFloat(snapshot.windows.count) * 30
                if snapshot.creditsRemaining != nil && !snapshot.windows.contains(where: { $0.kind == .credits }) {
                    height += 20
                }
                if snapshot.errorMessage != nil { height += 18 }
                height += 10
            }
        }
        return min(max(height, 120), 520)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("OpenQuota")
                .font(.system(size: 13, weight: .semibold))
            if model.isDemo {
                Text("Demo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.refreshing {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
            Button { model.refreshNow() } label: {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r")
            .help("Refresh")
            .disabled(model.refreshing || model.isDemo)
            Menu {
                Button("Settings…") { openSettings(); NSApp.activate() }
                    .keyboardShortcut(",")
                Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
                    .disabled(!UpdateController.shared.canCheckForUpdates)
                Divider()
                Button("Quit OpenQuota") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, Tokens.inset)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Accounts")
                .font(.system(size: 13, weight: .semibold))
            Text("Connect a subscription or add an API key to see what you have left.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Button("Add Account…") { openSettings(); NSApp.activate() }
                .controlSize(.small)
                .padding(.top, 2)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }
}

/// One provider: a small title, then each account beneath it.
struct ProviderSection: View {
    var name: String
    var dashboardURL: URL?
    var snapshots: [UsageSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let dashboardURL {
                    Link(destination: dashboardURL) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.tertiary)
                    .help("Open \(name) usage page")
                }
            }
            ForEach(snapshots, id: \.account.id) { snapshot in
                AccountBlock(snapshot: snapshot, showsLabel: snapshots.count > 1 || snapshot.account.label != nil)
            }
        }
    }
}

/// One account: label line, then its windows.
struct AccountBlock: View {
    var snapshot: UsageSnapshot
    var showsLabel: Bool

    private var creditsLine: String? {
        guard let credits = snapshot.creditsRemaining,
              !snapshot.windows.contains(where: { $0.kind == .credits }) else { return nil }
        return Format.amount(credits, unit: snapshot.creditsUnit) + " left"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsLabel || snapshot.account.plan != nil || snapshot.isStale {
                HStack(spacing: 6) {
                    Text(snapshot.account.label ?? "Default")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let plan = snapshot.account.plan {
                        Text(plan.capitalized)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if snapshot.isStale {
                        Text("Updated \(snapshot.fetchedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .help(snapshot.providerID == "claude"
                                ? "Claude reports usage while you use Claude Code."
                                : "Showing the last good reading.")
                    }
                }
            }
            ForEach(snapshot.windows) { window in
                WindowRow(window: window)
            }
            if let creditsLine {
                MetricLine(label: "Balance", value: creditsLine, detail: nil)
            }
            if let error = snapshot.errorMessage {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }
}

/// Label and value on one line; optional trailing detail in tertiary.
struct MetricLine: View {
    var label: String
    var value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let detail {
                Text(detail).foregroundStyle(.tertiary)
            }
            Text(value)
                .monospacedDigit()
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

/// One quota window: metric line + hairline meter.
struct WindowRow: View {
    var window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetricLine(label: window.label, value: value, detail: resetText)
            if let fraction = window.fractionUsed {
                Meter(fractionUsed: fraction)
            }
        }
    }

    private var value: String {
        if window.unit == "%" || (window.unit == nil && window.limit == 100),
           let remaining = window.percentRemaining {
            return "\(Int(remaining.rounded()))% left"
        }
        if let remaining = window.remaining {
            if let limit = window.limit { return "\(Format.amount(remaining, unit: window.unit)) of \(Format.amount(limit, unit: window.unit))" }
            return "\(Format.amount(remaining, unit: window.unit)) left"
        }
        if let used = window.used {
            if window.limit != nil, let remaining = window.percentRemaining {
                return "\(Int(remaining.rounded()))% left"
            }
            return "\(Format.amount(used, unit: window.unit)) used"
        }
        return "—"
    }

    private var resetText: String? {
        guard let resetsAt = window.resetsAt else { return nil }
        guard resetsAt > Date() else { return "resetting" }
        return Format.countdown(to: resetsAt)
    }
}

/// Hairline capsule meter. Neutral fill until usage gets tight.
struct Meter: View {
    var fractionUsed: Double

    private var tint: Color {
        if fractionUsed >= Tokens.criticalThreshold { return .red }
        if fractionUsed >= Tokens.warnThreshold { return .orange }
        return .primary.opacity(0.55)
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule().fill(tint)
                    .frame(width: max(proxy.size.width * (1 - fractionUsed), fractionUsed < 1 ? Tokens.meterHeight : 0))
            }
        }
        .frame(height: Tokens.meterHeight)
        .accessibilityElement()
        .accessibilityValue("\(Int(((1 - fractionUsed) * 100).rounded())) percent left")
    }
}

enum Tokens {
    static let popoverWidth: CGFloat = 320
    static let inset: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
    static let meterHeight: CGFloat = 4
    static let warnThreshold = 0.8
    static let criticalThreshold = 0.9
}

enum Format {
    static func amount(_ value: Double, unit: String?) -> String {
        switch unit {
        case "$", "USD", "usd":
            return value.formatted(.currency(code: "USD").precision(.fractionLength(value >= 100 ? 0 : 2)))
        case nil, "":
            return compact(value)
        default:
            return "\(compact(value)) \(unit!)"
        }
    }

    static func compact(_ value: Double) -> String {
        value.formatted(.number.notation(.compactName).precision(.significantDigits(1...3)))
    }

    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
        if days >= 2 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        if days >= 1 { return "\(days)d \(hours)h" }
        if hours >= 1 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }
}
#endif
