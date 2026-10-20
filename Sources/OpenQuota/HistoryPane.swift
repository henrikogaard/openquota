#if os(macOS)
import SwiftUI
import Charts
import OpenQuotaCore

/// Saved daily token and cost totals over time, by provider and model.
struct HistoryPane: View {
    enum Metric: Hashable { case cost, tokens }

    var model: AppModel
    @State private var range = SpendHistoryRange.days30
    @State private var metric = Metric.cost
    @State private var confirmingDelete = false
    @State private var showingConsent = false

    private var history: SpendHistory { model.spendHistory }

    var body: some View {
        Group {
            if history.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        controls
                        summary
                        chart
                        models
                        footer
                    }
                    .padding(20)
                }
            }
        }
        .frame(width: 680, height: 440)
        .environment(\.locale, Localized.appLocale)
        .alert(L("Delete usage history?", "Slette brukshistorikken?"), isPresented: $confirmingDelete) {
            Button(L("Cancel", "Avbryt"), role: .cancel) {}
            Button(L("Delete", "Slett"), role: .destructive) { model.deleteSpendHistory() }
        } message: {
            Text(L("Saved daily totals are deleted. OpenQuota rebuilds what your Claude and Codex logs still hold; older days are gone for good.",
                   "Lagrede dagstotaler slettes. OpenQuota bygger opp igjen det loggene til Claude og Codex fortsatt har; eldre dager er borte for godt."))
        }
        .alert(SpendCopy.enable, isPresented: $showingConsent) {
            Button(SpendCopy.enableShort) { model.setSpendEnabled(true) }
            Button(SpendCopy.cancel, role: .cancel) {}
        } message: {
            Text(SpendCopy.privacy + "\n\n" + SpendCopy.scope)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(L("No History Yet", "Ingen historikk ennå"), systemImage: "chart.bar.xaxis")
        } description: {
            Text(model.spendEnabled
                 ? L("History builds as OpenQuota reads your local Claude and Codex logs.",
                     "Historikken bygges når OpenQuota leser de lokale loggene til Claude og Codex.")
                 : L("Turn on reading local Claude and Codex logs to start saving daily token and cost totals.",
                     "Slå på lesing av lokale Claude- og Codex-logger for å begynne å lagre daglige token- og kostnadstall."))
        } actions: {
            if !model.spendEnabled && !model.isDemo {
                Button(SpendCopy.enableShort) { showingConsent = true }
            }
        }
    }

    private var controls: some View {
        HStack {
            Picker(L("Range", "Periode"), selection: $range) {
                Text(L("30 Days", "30 dager")).tag(SpendHistoryRange.days30)
                Text(L("90 Days", "90 dager")).tag(SpendHistoryRange.days90)
                Text(L("1 Year", "1 år")).tag(SpendHistoryRange.year)
                Text(L("All", "Alt")).tag(SpendHistoryRange.all)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            Picker(L("Show", "Vis"), selection: $metric) {
                Text(L("Cost", "Kostnad")).tag(Metric.cost)
                Text(L("Tokens", "Tokens")).tag(Metric.tokens)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
        }
    }

    private var summary: some View {
        let total = history.total(range)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(format(total))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Spacer()
                Text(metric == .cost ? SpendCopy.notBill : L("Input, output and cache", "Inndata, utdata og hurtigbuffer"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                ForEach(SpendProvider.allCases, id: \.self) { provider in
                    HStack(spacing: 4) {
                        Circle().fill(Self.color(provider)).frame(width: 6, height: 6)
                        Text(Self.name(provider)).foregroundStyle(.secondary)
                        Text(format(history.total(range, provider: provider))).monospacedDigit()
                    }
                }
            }
            .font(.callout)
        }
    }

    private var chart: some View {
        let buckets = history.buckets(range)
        return Chart(buckets) { bucket in
            BarMark(
                x: .value(L("Date", "Dato"), bucket.start, unit: range.granularity),
                y: .value(metric == .cost ? L("Cost", "Kostnad") : L("Tokens", "Tokens"), value(bucket.total)))
            .foregroundStyle(by: .value(L("Provider", "Leverandør"), Self.name(bucket.provider)))
        }
        .chartForegroundStyleScale([Self.name(.claude): Self.color(.claude), Self.name(.codex): Self.color(.codex)])
        .chartLegend(.hidden)
        .chartYAxis {
            AxisMarks { mark in
                AxisGridLine()
                AxisValueLabel {
                    if let number = mark.as(Double.self) { Text(axisLabel(number)) }
                }
            }
        }
        .frame(height: 170)
    }

    private var models: some View {
        let top = history.topModels(range)
        return VStack(alignment: .leading, spacing: 6) {
            Text(L("Top models", "Mest brukte modeller")).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(top) { row in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(Self.color(row.provider)).frame(width: 6, height: 6)
                            Text(row.model.isEmpty ? L("Unknown", "Ukjent") : row.model)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(row.total.tokens.formatted(.number.notation(.compactName)))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Text(row.total.pricedEvents == 0 && row.total.unpricedEvents > 0
                             ? "—" : row.total.dollars.formatted(.currency(code: "USD")))
                            .monospacedDigit()
                            .gridColumnAlignment(.trailing)
                            .help(row.total.unpricedEvents > 0
                                  ? L("\(row.total.unpricedEvents) requests have no known price and are excluded from cost.",
                                      "\(row.total.unpricedEvents) forespørsler har ingen kjent pris og er utelatt fra kostnaden.")
                                  : "")
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if history.hasIncompleteDays(range) {
                Label(L("Some days may be incomplete: a scan reached a limit before reading every log.",
                        "Noen dager kan være ufullstendige: en skanning nådde en grense før alle logger ble lest."),
                      systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text(savedNote)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.spendEnabled {
                Text(L("Reading local logs is off, so no new days are saved.",
                       "Lesing av lokale logger er av, så nye dager lagres ikke."))
                    .font(.caption).foregroundStyle(.orange)
            }
            Button(L("Delete History…", "Slett historikk…")) { confirmingDelete = true }
                .disabled(model.isDemo)
        }
    }

    private var savedNote: String {
        let since = history.firstDay ?? ""
        return L("Daily totals saved on this Mac since \(since). Claude Code deletes its own logs after 30 days by default; OpenQuota keeps these totals. Costs are API-rate estimates, not your bill.",
                 "Dagstotaler lagret på denne Macen siden \(since). Claude Code sletter sine egne logger etter 30 dager som standard; OpenQuota beholder disse tallene. Kostnadene er anslag etter API-pris, ikke fakturaen din.")
    }

    private func value(_ total: SpendTotal) -> Double {
        metric == .cost ? total.dollars : Double(total.tokens)
    }

    private func format(_ total: SpendTotal) -> String {
        metric == .cost
            ? total.dollars.formatted(.currency(code: "USD"))
            : total.tokens.formatted(.number.notation(.compactName))
    }

    private func axisLabel(_ value: Double) -> String {
        metric == .cost
            ? value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
            : value.formatted(.number.notation(.compactName))
    }

    static func name(_ provider: SpendProvider) -> String {
        switch provider {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    static func color(_ provider: SpendProvider) -> Color {
        switch provider {
        case .claude: .orange
        case .codex: .green
        }
    }
}
#endif
