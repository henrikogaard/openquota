import Foundation

/// English/Norwegian copy. Every user-facing string goes through here so the
/// UI never mixes languages.
public enum Localized {
    public static var norwegian: Bool {
        ["nb", "nn", "no"].contains(Locale.current.language.languageCode?.identifier ?? "")
    }

    public static func text(_ en: String, _ nb: String) -> String {
        norwegian ? nb : en
    }

    /// Provider-supplied window labels are English; translate the common ones.
    public static func windowLabel(_ label: String) -> String {
        guard norwegian else { return label }
        return windowLabels[label] ?? label
    }

    static let windowLabels: [String: String] = [
        "Week": "Uke", "Weekly": "Ukentlig", "Month": "Måned", "Monthly": "Månedlig",
        "Session": "Økt", "5 hours": "5 timer", "Balance": "Saldo", "Credits": "Kreditter",
        "Plan": "Plan", "Requests": "Forespørsler", "Search": "Søk", "Characters": "Tegn",
        "Subscription": "Abonnement", "Points": "Poeng", "Billing": "Fakturering",
        "Allowance": "Kvote", "Lifetime spend": "Totalt forbruk", "Key spend": "Nøkkelforbruk",
        "Spend 30d": "Forbruk 30d", "Plan credits": "Plankreditter", "Premium week": "Premium-uke",
        "Sessions (30d)": "Økter (30d)", "Input (30d)": "Inndata (30d)", "Output (30d)": "Utdata (30d)",
    ]
}
