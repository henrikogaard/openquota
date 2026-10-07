#if os(macOS)
import SwiftUI
import OpenQuotaCore

/// Monochrome provider glyph: an SF Symbol where one fits, else a monogram.
/// Deliberately not provider logos — keeps the UI monochrome and trademark-free.
struct ProviderGlyph: View {
    var providerID: String
    var name: String
    var size: CGFloat = 22

    static let symbols: [String: String] = [
        "claude": "sparkle", "codex": "chevron.left.forwardslash.chevron.right",
        "cursor": "cursorarrow.rays", "openrouter": "arrow.triangle.branch",
        "requesty": "arrow.left.arrow.right", "grok": "bolt", "gemini": "sparkles",
        "devin": "person.crop.square", "opencode": "terminal", "opencode-go": "terminal",
        "copilot": "airplane", "mistral": "wind", "deepseek": "water.waves",
        "elevenlabs": "waveform", "perplexity": "magnifyingglass", "warp": "chevron.right.2",
        "openai-admin": "building.2", "v0": "square.on.square", "vercel-ai-gateway": "triangle",
    ]

    var body: some View {
        ZStack {
            Circle().fill(.primary.opacity(0.08))
            if let symbol = Self.symbols[providerID] {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.45, weight: .medium))
            } else {
                Text(String(name.prefix(1)).uppercased())
                    .font(.system(size: size * 0.48, weight: .semibold, design: .rounded))
            }
        }
        .foregroundStyle(.secondary)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Label and value on one line; optional trailing detail in tertiary.
struct MetricLine: View {
    var label: String
    var value: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let detail { Text(detail).foregroundStyle(.tertiary) }
            Text(value).monospacedDigit()
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }
}

/// One quota window: metric line + capsule meter.
struct WindowRow: View {
    var window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MetricLine(label: Localized.windowLabel(window.label), value: Format.value(window), detail: Format.reset(window).map { $0 == Format.resetting ? L("Resetting now", "Nullstilles nå") : $0 })
            if let fraction = window.fractionUsed { Meter(fractionUsed: fraction) }
        }
    }
}

/// One usage window: label and reset time, then a bar with what's left.
struct QuotaRow: View {
    var window: UsageWindow

    private var resetText: String? {
        guard let reset = Format.reset(window) else { return nil }
        return reset == Format.resetting ? L("Resetting now", "Nullstilles nå") : L("Resets in \(reset)", "Nullstilles om \(reset)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(Localized.windowLabel(window.label)).font(.system(size: 12, weight: .medium))
                Spacer(minLength: 8)
                if let resetText {
                    Text(resetText).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            if let fraction = window.fractionUsed {
                HStack(spacing: 8) {
                    Meter(fractionUsed: fraction)
                    Text(L("\(Format.value(window)) left", "\(Format.value(window)) igjen"))
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(fraction >= Tokens.warnThreshold
                                         ? AnyShapeStyle(Tokens.tint(fractionUsed: fraction))
                                         : AnyShapeStyle(.secondary))
                        .frame(minWidth: 52, alignment: .trailing)
                        .lineLimit(1)
                }
            } else {
                Text(Format.value(window))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Capsule meter showing what's left. Neutral until usage gets tight.
struct Meter: View {
    var fractionUsed: Double
    var height: CGFloat = Tokens.meterHeight

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.1))
                Capsule().fill(Tokens.tint(fractionUsed: fractionUsed))
                    .frame(width: max(proxy.size.width * (1 - fractionUsed), fractionUsed < 1 ? height : 0))
            }
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityValue("\(Int(((1 - fractionUsed) * 100).rounded())) percent left")
    }
}

/// Ring showing what's left, for the popover's headline reading.
struct Ring: View {
    var fractionUsed: Double
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(1 - fractionUsed, 0.001))
                .stroke(Tokens.tint(fractionUsed: fractionUsed),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .accessibilityHidden(true)
    }
}

enum Tokens {
    static let popoverWidth: CGFloat = 340
    static let popoverMaxContentHeight: CGFloat = 600
    static let inset: CGFloat = 12
    static let moduleSpacing: CGFloat = 8
    static let moduleRadius: CGFloat = 16
    static let modulePadding: CGFloat = 12
    static let meterHeight: CGFloat = 6
    static let warnThreshold = 0.8
    static let criticalThreshold = 0.9

    static func tint(fractionUsed: Double) -> Color {
        if fractionUsed >= criticalThreshold { return .red }
        if fractionUsed >= warnThreshold { return .orange }
        return .accentColor
    }
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

    static func value(_ window: UsageWindow) -> String {
        if let remaining = window.percentRemaining,
           window.unit == "%" || window.limit != nil {
            return "\(Int(remaining.rounded()))%"
        }
        if let remaining = window.remaining {
            if let limit = window.limit {
                return L("\(amount(remaining, unit: window.unit)) of \(amount(limit, unit: window.unit))",
                         "\(amount(remaining, unit: window.unit)) av \(amount(limit, unit: window.unit))")
            }
            return L("\(amount(remaining, unit: window.unit)) left", "\(amount(remaining, unit: window.unit)) igjen")
        }
        if let used = window.used { return L("\(amount(used, unit: window.unit)) used", "\(amount(used, unit: window.unit)) brukt") }
        return "—"
    }

    static let resetting = "resetting"

    static func reset(_ window: UsageWindow) -> String? {
        guard let resetsAt = window.resetsAt else { return nil }
        guard resetsAt > Date() else { return resetting }
        return countdown(to: resetsAt)
    }

    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3_600, minutes = (seconds % 3_600) / 60
        if days >= 2 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        let h = L("h", "t")
        if days >= 1 { return "\(days)d \(hours)\(h)" }
        if hours >= 1 { return "\(hours)\(h) \(minutes)m" }
        return "\(max(minutes, 1))m"
    }
}
#endif
