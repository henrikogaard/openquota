#if os(macOS)
import SwiftUI
import OpenQuotaCore

private func openRouterAmount(_ value: Double) -> String {
    value.formatted(.currency(code: "USD").precision(.fractionLength(2)))
}

/// Currency amounts keep the key allowance distinct from account funds.
struct OpenRouterKeyUsage: View {
    var window: UsageWindow
    var totalSpend: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let used = totalSpend ?? window.used {
                MetricLine(label: L("Key usage", "Nøkkelbruk"),
                           value: L("\(openRouterAmount(used)) used",
                                    "\(openRouterAmount(used)) brukt"), detail: nil)
            }
            if let limit = window.limit, let remaining = window.remaining {
                Text(L("\(openRouterAmount(remaining)) left of \(openRouterAmount(limit)) key allowance",
                       "\(openRouterAmount(remaining)) igjen av nøkkelkvoten på \(openRouterAmount(limit))"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(L("Key usage is lifetime spend. The key allowance may reset independently.",
                "Nøkkelbruk er samlet forbruk. Nøkkelkvoten kan nullstilles separat."))
        .accessibilityElement(children: .combine)
    }
}

/// Shared by the popover and account details; periods appear only in details.
struct OpenRouterAccountReadings: View {
    var snapshot: UsageSnapshot
    var showsPeriodSpend = false
    @AppStorage private var storedThreshold: Double

    init(snapshot: UsageSnapshot, showsPeriodSpend: Bool = false) {
        self.snapshot = snapshot
        self.showsPeriodSpend = showsPeriodSpend
        _storedThreshold = AppStorage(wrappedValue: 5,
                                     OpenRouterDetails.warningPreferenceKey(accountID: snapshot.account.id))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let balance = snapshot.creditsRemaining {
                MetricLine(label: L("Account balance", "Kontosaldo"),
                           value: openRouterAmount(balance), detail: nil)
                if OpenRouterDetails.isLowBalance(balance, threshold: storedThreshold) {
                    Label(L("Low account balance", "Lav kontosaldo"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if showsPeriodSpend {
                if let daily = snapshot.openRouter?.dailySpend {
                    MetricLine(label: L("Key spend today", "Nøkkelforbruk i dag"),
                               value: openRouterAmount(daily), detail: nil)
                }
                if let monthly = snapshot.openRouter?.monthlySpend {
                    MetricLine(label: L("Key spend this month", "Nøkkelforbruk denne måneden"),
                               value: openRouterAmount(monthly), detail: nil)
                }
            }
            if let issue = snapshot.openRouter?.balanceIssue {
                issueLabel(issue.message(balance: true))
            }
            if let issue = snapshot.openRouter?.keyIssue {
                issueLabel(issue.message(balance: false))
            }
        }
    }

    private func issueLabel(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11)).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct OpenRouterBalancePreference: View {
    @AppStorage private var storedThreshold: Double

    init(accountID: String) {
        _storedThreshold = AppStorage(wrappedValue: 5,
                                     OpenRouterDetails.warningPreferenceKey(accountID: accountID))
    }

    var body: some View {
        Stepper(value: Binding(
            get: { OpenRouterDetails.warningThreshold(storedThreshold) },
            set: { storedThreshold = OpenRouterDetails.warningThreshold($0) }), in: 0...1000, step: 1) {
            LabeledContent(L("Warn below", "Varsle under"),
                           value: storedThreshold == 0 ? L("Off", "Av")
                           : openRouterAmount(OpenRouterDetails.warningThreshold(storedThreshold)))
        }
        Text(L("Highlights this account's balance below the chosen USD amount. Set to 0 to turn off. No notifications are sent.",
               "Fremhever kontosaldoen under det valgte beløpet i USD. Sett til 0 for å slå av. Ingen varslinger sendes."))
            .font(.caption).foregroundStyle(.secondary)
    }
}
#endif
