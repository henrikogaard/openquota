#if os(macOS)
import OpenQuotaCore

/// English/Norwegian UI copy; see `Localized`.
func L(_ en: String, _ nb: String) -> String { Localized.text(en, nb) }

/// Provider-specific wording for errors whose generic text would mislead.
func providerError(_ message: String, providerID: String) -> String {
    guard message == ProviderError.unauthorized.userMessage else { return message }
    switch providerID {
    case "cursor":
        return L("Cursor session expired or rejected. Add a new Cursor session token in Settings to reconnect.",
                 "Cursor-økten er utløpt eller avvist. Legg til en ny Cursor-øktnøkkel i Innstillinger for å koble til igjen.")
    case "mistral":
        return L("The Mistral session expired or was rejected. Sign in at admin.mistral.ai and paste a fresh Cookie header in Settings to reconnect.",
                 "Mistral-økten er utløpt eller avvist. Logg inn på admin.mistral.ai og lim inn en fersk Cookie-overskrift i Innstillinger for å koble til igjen.")
    case "opencode":
        return L("Sign-in rejected. Run opencode auth login again, or paste a key under Add Account.",
                 "Påloggingen ble avvist. Kjør opencode auth login på nytt, eller lim inn en nøkkel under Legg til konto.")
    case "devin":
        return L("Sign-in rejected. Run devin auth login again.",
                 "Påloggingen ble avvist. Kjør devin auth login på nytt.")
    default:
        return message
    }
}
#endif
