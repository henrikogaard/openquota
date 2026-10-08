#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// The popover: one Liquid Glass section per provider, every usage window
/// visible as a labelled bar with what's left and when it resets.
struct PopoverView: View {
    var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var contentHeight: CGFloat = 240

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
        GlassEffectContainer(spacing: Tokens.moduleSpacing) {
            VStack(spacing: Tokens.moduleSpacing) {
                if model.snapshots.isEmpty {
                    SpendPanel(model: model)
                    emptyState
                } else {
                    ScrollView {
                        VStack(spacing: Tokens.moduleSpacing) {
                            SpendPanel(model: model)
                            ForEach(groups, id: \.providerID) { group in
                                ProviderSection(
                                    model: model,
                                    providerID: group.providerID,
                                    name: model.providerName(group.providerID),
                                    dashboardURL: model.dashboardURL(group.providerID),
                                    snapshots: group.snapshots,
                                    isExperimental: group.snapshots.contains {
                                        model.isExperimentalProvider($0.providerID)
                                    })
                            }
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
                    }
                    .scrollIndicators(.automatic)
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
                footer
            }
            .padding(Tokens.inset)
        }
        .frame(width: Tokens.popoverWidth)
    }

    private func showSettings(addingAccount: Bool = false) {
        model.requestsAddAccount = addingAccount
        openSettings()
        NSApp.activate()
    }

    private var lastUpdated: Date? {
        model.snapshots.compactMap(\.lastSuccessfulAt).max()
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Group {
                if model.isDemo {
                    Text(L("Demo Data", "Demodata"))
                } else if model.refreshing {
                    Text(L("Refreshing…", "Oppdaterer…"))
                } else if let lastUpdated {
                    Text(L("Updated", "Oppdatert") + " " + lastUpdated.formatted(.relative(presentation: .named).locale(Localized.appLocale)))
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
            Spacer()
            Button { model.refreshNow() } label: {
                Label(L("Refresh", "Oppdater"), systemImage: "arrow.clockwise")
                    .symbolEffect(.rotate, isActive: model.refreshing)
            }
            .keyboardShortcut("r")
            .disabled(model.refreshing || model.isDemo)
            .help(L("Refresh", "Oppdater"))
            Menu {
                Button(L("Add Account…", "Legg til konto…")) { showSettings(addingAccount: true) }
                    .disabled(model.isDemo)
                Button(L("Settings…", "Innstillinger…")) { showSettings() }
                    .keyboardShortcut(",")
                Button(L("Check for Updates…", "Se etter oppdateringer…")) { UpdateController.shared.checkForUpdates() }
                    .disabled(!UpdateController.shared.canCheckForUpdates)
                Divider()
                Button(L("Quit OpenQuota", "Avslutt OpenQuota")) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Label(L("Options", "Valg"), systemImage: "ellipsis")
            }
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary)
            Text(L("No Accounts", "Ingen kontoer"))
                .font(.headline)
            Text(L("Connect a subscription or add an API key to see what you have left.",
                   "Koble til et abonnement eller legg til en API-nøkkel for å se hva du har igjen."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 240)
            Button(L("Add Account…", "Legg til konto…")) { showSettings(addingAccount: true) }
                .buttonStyle(.glassProminent)
                .padding(.top, 4)
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: Tokens.moduleRadius))
    }
}

/// One provider: header (glyph, name, plan, usage page), then each account's
/// windows, balance, freshness and errors — nothing hidden behind a click.
struct ProviderSection: View {
    var model: AppModel
    var providerID: String
    var name: String
    var dashboardURL: URL?
    var snapshots: [UsageSnapshot]
    var isExperimental = false

    private var single: UsageSnapshot? { snapshots.count == 1 ? snapshots[0] : nil }

    /// For a single account, its label and plan sit beside the provider name.
    private var subtitle: String? {
        guard let single else { return nil }
        let label = single.account.label.flatMap { $0 == name ? nil : $0 }
        let parts = [single.account.plan?.capitalized, label].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderGlyph(providerID: providerID, name: name, size: 22)
                Text(name).font(.system(size: 13, weight: .semibold))
                if isExperimental { ExperimentalBadge() }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if let dashboardURL {
                    Link(destination: dashboardURL) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(.rect)
                    }
                    .foregroundStyle(.secondary)
                    .help(L("Open Usage Page", "Åpne bruksside"))
                    .accessibilityLabel(L("Open \(name) Usage Page", "Åpne bruksside for \(name)"))
                }
            }
            ForEach(Array(snapshots.enumerated()), id: \.element.account.id) { index, snapshot in
                if index > 0 { Divider().opacity(0.5) }
                AccountUsage(
                    snapshot: snapshot,
                    showsHeader: single == nil,
                    credentialSourceName: snapshot.credentialSource.map {
                        model.credentialSourceName($0)
                    })
            }
        }
        .padding(Tokens.modulePadding)
        .glassEffect(.regular, in: .rect(cornerRadius: Tokens.moduleRadius))
    }

}

/// Every window of one account, plus balance, freshness and errors.
struct AccountUsage: View {
    var snapshot: UsageSnapshot
    var showsHeader: Bool
    var credentialSourceName: String?

    private var balance: String? {
        guard let credits = snapshot.creditsRemaining,
              !snapshot.windows.contains(where: { $0.kind == .credits }) else { return nil }
        return Format.amount(credits, unit: snapshot.creditsUnit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if showsHeader {
                HStack(spacing: 6) {
                    Text(snapshot.account.label ?? L("Default", "Standard"))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let plan = snapshot.account.plan {
                        Text(plan.capitalized).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
            ForEach(snapshot.windows) { window in QuotaRow(window: window) }
            if let balance {
                MetricLine(label: L("Balance", "Saldo"), value: balance, detail: nil)
            }
            if snapshot.windows.isEmpty && balance == nil && snapshot.errorMessage == nil {
                Text(snapshot.providerID == "claude"
                     ? L("Usage appears after your next Claude Code reply.",
                         "Bruken vises etter neste svar i Claude Code.")
                     : ProviderError.awaitingReading.userMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            if let error = snapshot.errorMessage {
                Label(providerError(error, providerID: snapshot.providerID), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let lastSuccessfulAt = snapshot.lastSuccessfulAt {
                Text(
                    (snapshot.isStale
                        ? L("Saved reading · last successful", "Lagret måling · sist vellykket")
                        : L("Last successful", "Sist vellykket"))
                        + " " + lastSuccessfulAt.formatted(
                            .relative(presentation: .named).locale(Localized.appLocale)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if snapshot.errorMessage != nil, let attemptedAt = snapshot.lastAttemptedAt {
                Text(L("Last attempt", "Siste forsøk") + " " + attemptedAt.formatted(
                    .relative(presentation: .named).locale(Localized.appLocale)))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            if let credentialSourceName {
                Text(credentialSourceName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(snapshot.isStale && snapshot.errorMessage == nil ? 0.75 : 1)
    }
}
#endif
