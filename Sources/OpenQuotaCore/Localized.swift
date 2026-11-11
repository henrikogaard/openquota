import Foundation

/// English/Norwegian copy. Every user-facing string goes through here so the
/// UI never mixes languages.
public enum Localized {
    /// UserDefaults key for the language chosen in Settings: "en", "nb", or
    /// empty/missing to follow the system.
    public static let languageKey = "appLanguage"

    /// The language the UI uses: the Settings choice when it is one we
    /// support, else the first system language.
    static func language(override: String?, preferred: [String]) -> String {
        if let override, ["en", "nb"].contains(override) { return override }
        return preferred.first ?? "en"
    }

    private static var language: String {
        language(override: UserDefaults.standard.string(forKey: languageKey),
                 preferred: Locale.preferredLanguages)
    }

    public static var norwegian: Bool {
        guard let code = language.split(separator: "-").first else { return false }
        return ["nb", "nn", "no"].contains(code)
    }

    public static func text(_ en: String, _ nb: String) -> String {
        norwegian ? nb : en
    }

    /// Locale for user-facing date/relative-time formatting; follows the app's
    /// resolved language (the Settings choice, else `-AppleLanguages`-aware
    /// system language), not the region locale.
    public static var appLocale: Locale {
        Locale(identifier: language)
    }

    /// Provider-supplied window labels are English; translate the common ones.
    public static func windowLabel(_ label: String) -> String {
        guard norwegian else { return label }
        // "Budget $50", "Budget 2": a budget's limit or number follows the word.
        if label.hasPrefix("Budget ") { return "Budsjett " + label.dropFirst(7) }
        return windowLabels[label] ?? label
    }

    static let windowLabels: [String: String] = [
        "Week": "Uke", "Weekly": "Ukentlig", "Month": "Måned", "Monthly": "Månedlig",
        "Session": "Økt", "5 hours": "5 timer", "Balance": "Saldo", "Credits": "Kreditter",
        "Plan": "Plan", "Budget": "Budsjett", "Requests": "Forespørsler", "Search": "Søk", "Characters": "Tegn",
        "Subscription": "Abonnement", "Points": "Poeng", "Billing": "Fakturering",
        "Allowance": "Kvote", "Lifetime spend": "Totalt forbruk", "Key spend": "Nøkkelforbruk",
        "Spend 30d": "Forbruk 30d", "Plan credits": "Plankreditter", "Premium week": "Premium-uke",
        "Sessions (30d)": "Økter (30d)", "Input (30d)": "Inndata (30d)", "Output (30d)": "Utdata (30d)",
        "Cursor Models": "Cursor-modeller", "Other Models": "Andre modeller", "On-demand spend": "Ekstraforbruk",
    ]
}
