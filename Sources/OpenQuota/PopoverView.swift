#if os(macOS)
import SwiftUI
import AppKit
import OpenQuotaCore

/// The popover: a title, the spend tile, then one flat card per provider with
/// every usage window on its own line: ring, label, reset and what's left.
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
        VStack(spacing: Tokens.moduleSpacing) {
            header
            if model.snapshots.isEmpty {
                SpendPanel(model: model)
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: Tokens.moduleSpacing) {
                        SpendPanel(model: model)
                        SectionHeader(title: L("Plans", "Abonnementer"))
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
                .scrollIndicators(.never)
                .scrollEdgeEffectStyle(.soft, for: .vertical)
                .scrollBounceBehavior(.basedOnSize)
                // A window-style MenuBarExtra can't size a scroll view itself;
                // follow the measured content up to most of the screen.
                .frame(height: min(contentHeight, maxContentHeight))
                .clipped()
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
        .frame(width: Tokens.popoverWidth)
    }

    /// Grow with the screen so scrolling is rare; never below the token.
    private var maxContentHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? Tokens.popoverMaxContentHeight
        return max(Tokens.popoverMaxContentHeight, screen - 140)
    }

    private func showSettings(addingAccount: Bool = false) {
        model.requestsAddAccount = addingAccount
        openSettings()
        NSApp.activate()
    }

    private var lastUpdated: Date? {
        model.snapshots.compactMap(\.lastSuccessfulAt).max()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("OpenQuota").font(.system(size: 14, weight: .semibold))
            Spacer()
            if !model.snapshots.isEmpty {
                let count = model.snapshots.count
                Text(count == 1 ? L("1 account", "1 konto") : L("\(count) accounts", "\(count) kontoer"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
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
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.trailing, 4)
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
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .card()
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

    /// For a single account, show its label and plan beneath the provider name.
    private var subtitle: String? {
        guard let single else { return nil }
        let label = single.account.label.flatMap { $0 == name ? nil : $0 }
        let parts = [single.account.plan?.capitalized, label, single.account.email].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProviderGlyph(providerID: providerID, name: name, size: 18)
                Text(name).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                if isExperimental { ExperimentalBadge() }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(subtitle)
                }
                Spacer(minLength: 4)
                if let dashboardURL {
                    Link(destination: dashboardURL) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 10, weight: .semibold))
                            .frame(width: 18, height: 18)
                            .contentShape(.rect)
                    }
                    .foregroundStyle(.tertiary)
                    .help(L("Open Usage Page", "Åpne bruksside"))
                    .accessibilityLabel(L("Open \(name) Usage Page", "Åpne bruksside for \(name)"))
                }
            }
            ForEach(Array(snapshots.enumerated()), id: \.element.account.id) { index, snapshot in
                if index > 0 { Divider().opacity(0.5) }
                AccountUsage(
                    snapshot: snapshot,
                    showsHeader: single == nil,
                    sameAccountLabels: snapshot.sameAccount(in: snapshots).map {
                        $0.account.label ?? L("Default", "Standard")
                    },
                    credentialSourceName: snapshot.credentialSource.map {
                        model.credentialSourceName($0)
                    })
            }
        }
        .card()
    }

}

/// Two connections signed in to one account show the same quota twice.
struct SameAccountWarning: View {
    var labels: [String]
    var compact = false

    var body: some View {
        let names = labels.joined(separator: ", ")
        let full = L("Same account as \(names). These numbers are shared, not extra.",
                     "Samme konto som \(names). Tallene deles, de kommer ikke i tillegg.")
        Label(compact ? L("Shared with \(names)", "Delt med \(names)") : full,
              systemImage: "person.2.fill")
            .font(.system(size: compact ? 10 : 11))
            .foregroundStyle(.orange)
            .lineLimit(compact ? 1 : nil)
            .fixedSize(horizontal: false, vertical: !compact)
            .help(full)
    }
}

/// Every window of one account, plus balance, freshness and errors.
struct AccountUsage: View {
    var snapshot: UsageSnapshot
    var showsHeader: Bool
    var sameAccountLabels: [String] = []
    var credentialSourceName: String?

    private var balance: String? {
        // OpenRouter key usage has a different scope from the account balance.
        guard let credits = snapshot.creditsRemaining,
              (snapshot.providerID == "openrouter"
               || !snapshot.windows.contains(where: { $0.kind == .credits })) else { return nil }
        return Format.amount(credits, unit: snapshot.creditsUnit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if showsHeader {
                HStack(spacing: 6) {
                    Text(snapshot.account.label ?? L("Default", "Standard"))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let plan = snapshot.account.plan {
                        Text(plan.capitalized).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    if let email = snapshot.account.email {
                        Text(email).font(.system(size: 11)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.middle).help(email)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
            }
            ForEach(snapshot.windows) { window in
                if CompactQuotaRow.fits(window) {
                    CompactQuotaRow(window: window)
                } else {
                    QuotaRow(window: window)
                }
            }
            if !sameAccountLabels.isEmpty {
                SameAccountWarning(labels: sameAccountLabels, compact: true)
            }
            if let balance {
                MetricLine(
                    label: snapshot.providerID == "openrouter"
                        ? L("Account balance", "Kontosaldo") : L("Balance", "Saldo"),
                    value: balance, detail: nil)
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
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            // Fresh readings say nothing extra; the footer has the time.
            if snapshot.isStale || snapshot.errorMessage != nil, let lastSuccessfulAt = snapshot.lastSuccessfulAt {
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
            if snapshot.errorMessage != nil, let credentialSourceName {
                Text(credentialSourceName)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(snapshot.isStale && snapshot.errorMessage == nil ? 0.75 : 1)
    }
}
#endif
