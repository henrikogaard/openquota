#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// The popover, laid out like a Control Center panel: a headline reading for
/// whatever runs out first, one Liquid Glass module per provider, and a row
/// of glass controls. Modules collapse to one line per account.
struct PopoverView: View {
    var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var expanded: Set<String> = []
    @State private var contentHeight: CGFloat = 240
    @Namespace private var glass

    /// Grouped by display name so one product (e.g. OpenCode Go from a local
    /// file and from pasted keys) reads as a single module.
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

    /// The single window closest to running out, across every account.
    private var headline: (snapshot: UsageSnapshot, window: UsageWindow)? {
        model.snapshots
            .flatMap { snapshot in snapshot.windows.map { (snapshot, $0) } }
            .filter { $0.1.fractionUsed != nil }
            .min { ($0.1.percentRemaining ?? 100) < ($1.1.percentRemaining ?? 100) }
    }

    var body: some View {
        GlassEffectContainer(spacing: Tokens.moduleSpacing) {
            VStack(spacing: Tokens.moduleSpacing) {
                if model.snapshots.isEmpty {
                    emptyState
                } else {
                    if let headline {
                        HeadlineModule(
                            name: model.providerName(headline.snapshot.providerID),
                            snapshot: headline.snapshot, window: headline.window)
                    }
                    ScrollView {
                        VStack(spacing: Tokens.moduleSpacing) {
                            ForEach(groups, id: \.providerID) { group in
                                let name = model.providerName(group.providerID)
                                ProviderModule(
                                    providerID: group.providerID, name: name,
                                    dashboardURL: model.dashboardURL(group.providerID),
                                    snapshots: group.snapshots,
                                    isExpanded: expanded.contains(name),
                                    toggle: { toggle(name) })
                                .glassEffectID(name, in: glass)
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .scrollIndicators(.never)
                    .scrollBounceBehavior(.basedOnSize)
                    // A window-style MenuBarExtra can't size a scroll view itself;
                    // follow the measured content up to a cap.
                    .frame(height: min(contentHeight, Tokens.popoverMaxContentHeight))
                }
                if let status = model.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                }
                controls
            }
            .padding(Tokens.inset)
        }
        .frame(width: Tokens.popoverWidth)
    }

    private func toggle(_ name: String) {
        withAnimation(.smooth(duration: 0.25)) {
            if expanded.contains(name) { expanded.remove(name) } else { expanded.insert(name) }
        }
    }

    private func showSettings(addingAccount: Bool = false) {
        model.requestsAddAccount = addingAccount
        openSettings()
        NSApp.activate()
    }

    private var controls: some View {
        HStack(spacing: 8) {
            Button { model.refreshNow() } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: model.refreshing)
            }
            .keyboardShortcut("r")
            .disabled(model.refreshing || model.isDemo)
            Button { showSettings(addingAccount: true) } label: {
                Label("Add Account", systemImage: "plus")
            }
            .disabled(model.isDemo)
            Spacer()
            if model.isDemo {
                Text("Demo").font(.caption).foregroundStyle(.secondary)
            }
            Button { showSettings() } label: {
                Label("Settings", systemImage: "gearshape")
            }
            .keyboardShortcut(",")
            Menu {
                Button("Check for Updates…") { UpdateController.shared.checkForUpdates() }
                    .disabled(!UpdateController.shared.canCheckForUpdates)
                Divider()
                Button("Quit OpenQuota") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text("No Accounts")
                .font(.headline)
            Text("Connect a subscription or add an API key to see what you have left.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            Button("Add Account…") { showSettings(addingAccount: true) }
                .buttonStyle(.glassProminent)
                .padding(.top, 4)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: Tokens.moduleRadius))
    }
}

/// Headline reading: the window that will run out first, as a ring.
struct HeadlineModule: View {
    var name: String
    var snapshot: UsageSnapshot
    var window: UsageWindow

    var body: some View {
        HStack(spacing: 14) {
            if let fraction = window.fractionUsed {
                ZStack {
                    Ring(fractionUsed: fraction, lineWidth: 6)
                    ProviderGlyph(providerID: snapshot.providerID, name: name, size: 26)
                }
                .frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("\(Int((window.percentRemaining ?? 0).rounded()))%")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("left").font(.callout).foregroundStyle(.secondary)
                }
                Text([name, snapshot.account.label, window.label].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let reset = Format.reset(window) {
                    Text(reset == "resetting" ? "Resetting now" : "Resets in \(reset)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Tokens.modulePadding)
        .glassEffect(.regular, in: .rect(cornerRadius: Tokens.moduleRadius))
        .accessibilityElement(children: .combine)
    }
}

/// One provider as a glass module. Collapsed: one line per account.
/// Expanded: every window, credits, freshness and errors.
struct ProviderModule: View {
    var providerID: String
    var name: String
    var dashboardURL: URL?
    var snapshots: [UsageSnapshot]
    var isExpanded: Bool
    var toggle: () -> Void

    private var hasError: Bool { snapshots.contains { $0.errorMessage != nil } }
    private var isStale: Bool { snapshots.contains { $0.isStale } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    ProviderGlyph(providerID: providerID, name: name)
                    Text(name).font(.system(size: 13, weight: .semibold))
                    if hasError {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10)).foregroundStyle(.orange)
                            .help("Couldn't refresh")
                    } else if isStale {
                        Image(systemName: "clock")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .help("Showing the last good reading")
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(isExpanded ? "Collapse" : "Expand")

            ForEach(snapshots, id: \.account.id) { snapshot in
                if isExpanded {
                    ExpandedAccount(snapshot: snapshot, showsLabel: snapshots.count > 1 || snapshot.account.label != nil)
                } else {
                    CollapsedAccount(snapshot: snapshot)
                }
            }

            if isExpanded, let dashboardURL {
                Link(destination: dashboardURL) {
                    Label("Usage Page", systemImage: "arrow.up.right")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(Tokens.modulePadding)
        .glassEffect(.regular, in: .rect(cornerRadius: Tokens.moduleRadius))
    }
}

/// One line: account label, its tightest meter, and that value.
struct CollapsedAccount: View {
    var snapshot: UsageSnapshot

    private var tightest: UsageWindow? {
        snapshot.windows.filter { $0.fractionUsed != nil }
            .min { ($0.percentRemaining ?? 100) < ($1.percentRemaining ?? 100) }
    }

    private var value: String {
        if let tightest { return Format.value(tightest) }
        if let credits = snapshot.creditsRemaining { return Format.amount(credits, unit: snapshot.creditsUnit) }
        if let first = snapshot.windows.first { return Format.value(first) }
        return snapshot.errorMessage == nil ? "—" : "Error"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(snapshot.account.label ?? snapshot.account.plan?.capitalized ?? "Default")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            if let fraction = tightest?.fractionUsed {
                Meter(fractionUsed: fraction)
            } else {
                Spacer()
            }
            Text(value)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
        }
        .opacity(snapshot.isStale ? 0.6 : 1)
    }
}

struct ExpandedAccount: View {
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
                    Text(snapshot.account.label ?? "Default").font(.system(size: 12, weight: .medium))
                    if let plan = snapshot.account.plan {
                        Text(plan.capitalized).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if snapshot.isStale {
                        Text("Updated \(snapshot.fetchedAt, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            ForEach(snapshot.windows) { window in WindowRow(window: window) }
            if let creditsLine { MetricLine(label: "Balance", value: creditsLine, detail: nil) }
            if let error = snapshot.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
    }
}
#endif
