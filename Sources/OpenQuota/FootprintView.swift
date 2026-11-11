#if os(macOS)
import SwiftUI
import Charts
import OpenQuotaCore

/// Estimated electricity, CO2e and cooling water behind the saved token
/// totals. Every figure is an estimate with a range, never a measurement.
struct FootprintView: View {
    let history: SpendHistory
    let range: SpendHistoryRange
    @AppStorage("footprintGrid") private var gridID = FootprintGrid.standard.id

    private var grid: FootprintGrid { .preset(gridID) }

    var body: some View {
        let footprint = history.footprint(range)
        VStack(alignment: .leading, spacing: 16) {
            headline(footprint)
            tiles(footprint)
            Text(comparisons(footprint.energyWh.mid))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            chart
            models
            Text(Self.assumptions)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func headline(_ footprint: Footprint) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("≈ " + Self.energy(footprint.energyWh.mid))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(L("Estimate, not measured", "Anslag, ikke målt"))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker(L("Power grid", "Strømnett"), selection: $gridID) {
                ForEach(FootprintGrid.presets) { grid in
                    Text("\(Self.gridName(grid.id)) (\(Int(grid.gramsPerKWh)) g/kWh)").tag(grid.id)
                }
            }
            .fixedSize()
        }
    }

    private func tiles(_ footprint: Footprint) -> some View {
        let co2 = footprint.co2Grams(grid)
        let water = footprint.waterML()
        return Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 4) {
            GridRow {
                tile(L("Electricity", "Strøm"), "≈ " + Self.energy(footprint.energyWh.mid),
                     Self.rangeText(footprint.energyWh, Self.energy))
                tile("CO₂e", "≈ " + Self.mass(co2.mid), Self.rangeText(co2, Self.mass))
                tile(L("Cooling water", "Kjølevann"), "≈ " + Self.volume(water.mid),
                     Self.rangeText(water, Self.volume))
                tile(L("Saved by caching", "Spart med hurtigbuffer"), "≈ " + Self.energy(footprint.cacheSavedWh),
                     L("\(Self.percent(footprint.cacheSavedShare)) less, assumed", "\(Self.percent(footprint.cacheSavedShare)) mindre, antatt"))
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
            Text(detail).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var chart: some View {
        let buckets = history.footprintBuckets(range)
        return Chart(buckets) { bucket in
            BarMark(
                x: .value(L("Date", "Dato"), bucket.start, unit: range.granularity),
                y: .value("kWh", bucket.footprint.energyWh.mid / 1000))
            .foregroundStyle(Color.accentColor)
        }
        .chartYAxis {
            AxisMarks { mark in
                AxisGridLine()
                AxisValueLabel {
                    if let number = mark.as(Double.self) { Text(Self.energy(number * 1000)) }
                }
            }
        }
        .frame(height: 130)
        .accessibilityLabel(L("Estimated electricity over time", "Anslått strømforbruk over tid"))
    }

    private var models: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("By model", "Per modell")).font(.headline)
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow {
                    Text(L("Model", "Modell")).gridColumnAlignment(.leading)
                    Text(L("Size", "Størrelse")).gridColumnAlignment(.leading)
                    Text(L("Requests", "Forespørsler"))
                    Text(L("New input", "Ny inndata"))
                    Text(L("Cache read", "Lest fra buffer"))
                    Text(L("Output", "Utdata"))
                    Text(L("Electricity", "Strøm"))
                    Text(L("Range", "Intervall"))
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(history.footprintModels(range)) { row in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(HistoryPane.color(row.provider)).frame(width: 6, height: 6)
                            Text(row.model.isEmpty ? L("Unknown", "Ukjent") : row.model)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(Self.className(row.modelClass)).foregroundStyle(.secondary)
                        Text(Self.compact(row.footprint.requests))
                        Text(Self.compact(row.footprint.newInputTokens))
                        Text(Self.compact(row.footprint.cacheReadTokens))
                        Text(Self.compact(row.footprint.outputTokens))
                        Text("≈ " + Self.energy(row.footprint.energyWh.mid))
                        Text(Self.rangeText(row.footprint.energyWh, Self.energy)).foregroundStyle(.secondary)
                    }
                    .font(.callout).monospacedDigit()
                }
            }
        }
    }

    // MARK: Copy

    static let assumptions = L(
        "Estimates from token counts in your local Claude and Codex logs. Anthropic and OpenAI publish no energy figures, so the range is wide: 0.3 to 3 Wh per 1,000 output tokens, from Google's measured Gemini prompt (low), Epoch AI's method scaled to Claude (central) and Jegham et al. (high). Assumed, not measured: an input token counts as one fifth of an output token, a cache read as one tenth of an input token, and small and large models as 0.25× and 2×. Water is on-site cooling only, 0.15 to 1.15 mL per Wh. CO₂e uses the grid you pick; the data centre's real grid and its clean-power purchases are unknown. Training and hardware are not included.",
        "Anslag ut fra tokentall i de lokale loggene til Claude og Codex. Anthropic og OpenAI publiserer ingen energitall, så intervallet er bredt: 0,3 til 3 Wh per 1000 utdatatokens, fra Googles målte Gemini-forespørsel (lavt), Epoch AIs metode skalert til Claude (midten) og Jegham mfl. (høyt). Antatt, ikke målt: en inndatatoken teller som en femtedel av en utdatatoken, en lesing fra hurtigbufferen som en tidel av en inndatatoken, og små og store modeller som 0,25× og 2×. Vann er bare kjøling på stedet, 0,15 til 1,15 mL per Wh. CO₂e bruker strømnettet du velger; datasenterets faktiske strømnett og kjøp av ren kraft er ukjent. Trening og maskinvare er ikke med.")

    /// Everyday comparisons for the central estimate: a 100 W TV, a 50 W
    /// laptop, a 15 Wh phone charge and a 10 W LED bulb.
    private func comparisons(_ wh: Double) -> String {
        let tv = Self.number(wh / 100), laptop = Self.number(wh / 50)
        let phone = Self.number(wh / 15), bulb = Self.number(wh / 10)
        return L("Roughly \(tv) hours of TV (100 W), \(laptop) hours of laptop use (50 W), \(phone) phone charges (15 Wh) or \(bulb) hours of an LED bulb (10 W).",
                 "Omtrent \(tv) timer TV (100 W), \(laptop) timer bærbar PC (50 W), \(phone) mobilladinger (15 Wh) eller \(bulb) timer med en LED-pære (10 W).")
    }

    static func gridName(_ id: String) -> String {
        switch id {
        case "us": L("United States", "USA")
        case "world": L("World", "Verden")
        case "eu": "EU"
        case "germany": L("Germany", "Tyskland")
        case "uk": L("United Kingdom", "Storbritannia")
        case "france": L("France", "Frankrike")
        case "sweden": L("Sweden", "Sverige")
        case "norway": L("Norway", "Norge")
        default: id
        }
    }

    static func className(_ modelClass: FootprintModelClass) -> String {
        switch modelClass {
        case .small: L("Small", "Liten")
        case .standard: L("Standard", "Standard")
        case .large: L("Large", "Stor")
        }
    }

    // MARK: Numbers

    /// Two significant digits: these are estimates.
    static func number(_ value: Double) -> String {
        value.formatted(.number.precision(.significantDigits(1...2)).locale(Localized.appLocale))
    }

    static func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName).locale(Localized.appLocale))
    }

    static func percent(_ share: Double) -> String {
        share.formatted(.percent.precision(.fractionLength(0)).locale(Localized.appLocale))
    }

    static func energy(_ wh: Double) -> String { scaled(wh, "Wh", "kWh") }
    static func mass(_ grams: Double) -> String { scaled(grams, "g", "kg") }
    static func volume(_ ml: Double) -> String { scaled(ml, "mL", "L") }

    /// 999.5 and up rounds to 1,000, so it moves to the larger unit.
    private static func scaled(_ value: Double, _ unit: String, _ thousand: String) -> String {
        value >= 999.5 ? "\(number(value / 1000)) \(thousand)" : "\(number(value)) \(unit)"
    }

    /// "2.7–68 kWh" when both ends share a unit, "300 Wh–3 kWh" otherwise.
    static func rangeText(_ range: FootprintRange, _ format: (Double) -> String) -> String {
        let low = format(range.low).split(separator: " "), high = format(range.high)
        if low.count == 2, high.hasSuffix(" " + low[1]) { return "\(low[0])–\(high)" }
        return "\(format(range.low))–\(high)"
    }
}
#endif
