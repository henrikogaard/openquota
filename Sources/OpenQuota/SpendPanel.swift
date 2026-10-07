#if os(macOS)
import SwiftUI
import OpenQuotaCore

struct SpendPanel: View {
    var model: AppModel
    @State private var period = SpendPeriod.today
    @State private var showingConsent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var total: SpendTotal { model.spend.total(period: period) }
    private var hasReading: Bool { model.spend.scannedAt != nil && !model.spend.pricingUnavailable && model.spend.hasLogs }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(SpendCopy.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.spendScanning { ProgressView().controlSize(.mini) }
                Text(SpendCopy.thisMac).font(.caption).foregroundStyle(.secondary)
            }
            if model.spendEnabled {
                Picker(SpendCopy.period, selection: $period) {
                    ForEach(SpendPeriod.allCases, id: \.self) { value in
                        Text(SpendCopy.period(value)).tag(value)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(alignment: .firstTextBaseline) {
                    Text(hasReading && (total.pricedEvents > 0 || (total.unpricedEvents == 0 && !model.spend.isPartial)) ? money(total.dollars) : "—")
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Spacer()
                    Text(SpendCopy.notBill)
                        .font(.caption).foregroundStyle(.secondary)
                }
                if hasReading {
                    HStack(spacing: 16) {
                        provider(.claude, name: "Claude", color: .orange)
                        provider(.codex, name: "Codex", color: .green)
                    }
                    .font(.caption)
                    if total.recordedUSD > 0 {
                        Text("\(SpendCopy.recorded): \(money(total.recordedUSD)) · \(SpendCopy.estimated): \(money(total.estimatedUSD))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if let warning {
                    Label(warning, systemImage: "exclamationmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let updated = model.spend.scannedAt {
                    HStack(spacing: 3) {
                        Text(SpendCopy.checked)
                        Text(updated, format: .relative(presentation: .named))
                    }
                    .font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    Text(SpendCopy.intro)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(SpendCopy.enableShort) { showingConsent = true }
                        .buttonStyle(.glass)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if reduceTransparency { RoundedRectangle(cornerRadius: Tokens.moduleRadius).fill(.background) }
        }
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Tokens.moduleRadius))
        .alert(SpendCopy.enable, isPresented: $showingConsent) {
            Button(SpendCopy.enableShort) { model.setSpendEnabled(true) }
            Button(SpendCopy.cancel, role: .cancel) {}
        } message: {
            Text(SpendCopy.privacy + "\n\n" + SpendCopy.scope)
        }
    }

    private func provider(_ provider: SpendProvider, name: String, color: Color) -> some View {
        let value = model.spend.total(provider: provider, period: period)
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 5, height: 5).accessibilityHidden(true)
            Text(name).foregroundStyle(.secondary)
            Text(value.unpricedEvents > 0 && value.pricedEvents == 0 ? "—" : money(value.dollars)).monospacedDigit()
        }
    }

    private var warning: String? {
        if model.spend.pricingUnavailable { return SpendCopy.noPricing }
        if model.spend.isPartial { return SpendCopy.partial }
        if total.unpricedEvents > 0 { return "\(total.unpricedEvents) \(SpendCopy.unpriced)" }
        if model.spend.scannedAt == nil { return SpendCopy.scanning }
        if !model.spend.hasLogs { return SpendCopy.noLogs }
        return nil
    }

    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD"))
    }
}

enum SpendCopy {
    private static func text(_ en: String, _ nb: String) -> String { Localized.text(en, nb) }
    static var title: String { text("Estimated Spend", "Estimert forbruk") }
    static var thisMac: String { text("This Mac", "Denne Macen") }
    static var enable: String { text("Read Local Claude & Codex Usage Logs", "Les lokale brukslogger for Claude og Codex") }
    static var enableShort: String { text("Enable…", "Aktiver…") }
    static var cancel: String { text("Cancel", "Avbryt") }
    static var intro: String { text("See the API-rate value of your local Claude and Codex activity.", "Se API-verdien av lokal Claude- og Codex-aktivitet.") }
    static var privacy: String {
        text("Opt in to read token counts, model names, timestamps and recorded costs from local Claude/Codex session logs. Nothing is uploaded. Prompts are not retained. Turning this off clears the in-memory usage cache.",
             "Aktiver for å lese tokenantall, modellnavn, tidspunkt og registrerte kostnader fra lokale Claude-/Codex-logger. Ingenting lastes opp. Ledetekster lagres ikke. Deaktivering tømmer bruksmellomlageret.")
    }
    static var scope: String {
        text("Includes default CLI homes and connected configurations, not other devices. Shared histories cannot be attributed to a subscription. Prices are bundled snapshots, updated with the app—not your invoice.",
             "Inkluderer standard CLI-mapper og tilkoblede konfigurasjoner, ikke andre enheter. Delt historikk kan ikke knyttes til et abonnement. Prisene følger appoppdateringer – dette er ikke fakturaen din.")
    }
    static var settingsToggle: String { text("Read local Claude and Codex logs", "Les lokale Claude- og Codex-logger") }
    static var settingsFooter: String {
        text("Estimates API-rate value from token counts on this Mac. Nothing is uploaded, and it isn't your bill.",
             "Anslår API-verdi fra tokenantall på denne Macen. Ingenting lastes opp, og det er ikke fakturaen din.")
    }
    static var period: String { text("Period", "Periode") }
    static func period(_ value: SpendPeriod) -> String {
        switch value {
        case .today: text("Today", "I dag")
        case .yesterday: text("Yesterday", "I går")
        case .thirtyDays: text("30 Days", "30 dager")
        }
    }
    static var notBill: String { text("API value · not a bill", "API-verdi · ikke faktura") }
    static var recorded: String { text("Log-reported", "Registrert i logg") }
    static var estimated: String { text("Estimated", "Estimert") }
    static var checked: String { text("Scanned", "Skannet") }
    static var noPricing: String { text("Pricing data unavailable. Reinstall or update OpenQuota.", "Prisdata mangler. Installer OpenQuota på nytt eller oppdater appen.") }
    static var partial: String { text("Partial total: some logs could not be read, or a scan limit was reached. Unpriced usage is excluded.", "Delvis sum: noen logger kunne ikke leses, eller en skannegrense ble nådd. Bruk uten pris er utelatt.") }
    static var unpriced: String { text("unpriced requests excluded", "forespørsler uten pris er utelatt") }
    static var scanning: String { text("Scanning local logs…", "Skanner lokale logger…") }
    static var noLogs: String { text("No recent local usage logs found.", "Fant ingen nylige lokale brukslogger.") }
}
#endif
