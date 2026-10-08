#if os(macOS)
import SwiftUI
import OpenQuotaCore

struct MenuBarLabel: View {
    var model: AppModel
    @AppStorage("menuBarShowsPercent") private var showsPercent = true
    @AppStorage("menuBarDisplayStyle") private var storedStyle = ""
    @AppStorage("menuBarAccountID") private var accountID = ""
    @AppStorage("menuBarWindowID") private var windowID = ""

    private var style: MenuBarDisplayStyle {
        .resolve(storedStyle, legacyShowsPercent: showsPercent)
    }

    private var reading: MenuBarReading? {
        .select(from: model.snapshots, accountID: accountID, windowID: windowID)
    }

    private var symbol: String {
        guard let left = reading?.percentRemaining else { return "gauge.with.dots.needle.33percent" }
        switch left {
        case ..<10: return "gauge.with.dots.needle.0percent"
        case ..<40: return "gauge.with.dots.needle.33percent"
        case ..<60: return "gauge.with.dots.needle.50percent"
        case ..<90: return "gauge.with.dots.needle.67percent"
        default: return "gauge.with.dots.needle.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if style == .iconOnly || style == .iconAndPercentage {
                Image(systemName: symbol)
            }
            if style == .providerAndPercentage {
                Text("\(reading.map { model.providerName($0.snapshot.providerID) } ?? "OpenQuota") \(reading.map { "\(Int($0.percentRemaining.rounded()))%" } ?? "—")")
                    .lineLimit(1)
                    .monospacedDigit()
            }
            if style != .iconOnly && style != .providerAndPercentage {
                Text(reading.map { "\(Int($0.percentRemaining.rounded()))%" } ?? "—")
                    .monospacedDigit()
            }
        }
        .opacity(reading?.snapshot.isStale == true ? 0.5 : 1)
        .help(sourceDescription)
        .accessibilityLabel(sourceDescription)
    }

    private var sourceDescription: String {
        guard let reading else {
            return accountID.isEmpty
                ? L("OpenQuota — no percentage available", "OpenQuota — ingen prosent tilgjengelig")
                : L("OpenQuota — the selected account or window has no percentage available",
                    "OpenQuota — den valgte kontoen eller perioden har ingen prosent tilgjengelig")
        }
        let snapshot = reading.snapshot
        let source = [
            model.providerName(snapshot.providerID),
            snapshot.account.label,
            Localized.windowLabel(reading.window.label)
        ].compactMap { $0 }.joined(separator: " · ")
        let value = Int(reading.percentRemaining.rounded())
        let selection = accountID.isEmpty
            ? L("Lowest remaining across all accounts", "Lavest gjenværende på tvers av alle kontoer")
            : L("Selected account", "Valgt konto")
        let freshness = snapshot.isStale ? L("Cached reading", "Bufret avlesning") : L("Updated", "Oppdatert")
        let updated = snapshot.fetchedAt.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Localized.appLocale))
        return "\(source): " + L("\(value)% remaining", "\(value)% igjen") +
            "\n\(selection)\n\(freshness) \(updated)"
    }
}

extension MenuBarDisplayStyle {
    var title: String {
        switch self {
        case .iconOnly: L("Icon only", "Kun ikon")
        case .percentageOnly: L("Percentage only", "Kun prosent")
        case .iconAndPercentage: L("Icon and percentage", "Ikon og prosent")
        case .providerAndPercentage: L("Provider and percentage", "Leverandør og prosent")
        }
    }
}
#endif
