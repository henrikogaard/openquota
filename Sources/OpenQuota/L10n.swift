#if os(macOS)
import OpenQuotaCore

/// English/Norwegian UI copy; see `Localized`.
func L(_ en: String, _ nb: String) -> String { Localized.text(en, nb) }

/// Provider-specific wording for errors whose generic text would mislead.
func providerError(_ message: String, providerID: String) -> String {
    guard message == ProviderError.unauthorized.userMessage else { return message }
    switch providerID {
    case "mistral":
        return L("Key rejected. Mistral needs an Admin API key from admin.mistral.ai; a regular API key won't work.",
                 "Nøkkelen ble avvist. Mistral krever en admin-API-nøkkel fra admin.mistral.ai; en vanlig API-nøkkel fungerer ikke.")
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
