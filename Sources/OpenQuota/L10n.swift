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
    case "opencode-console":
        return L("The OpenCode sign-in expired or was rejected. Use Add Account → OpenCode Go → Sign in to OpenCode again.",
                 "OpenCode-påloggingen er utløpt eller avvist. Bruk Legg til konto → OpenCode Go → Logg inn i OpenCode på nytt.")
    case "mistral":
        return L("The Mistral session expired or was rejected. Sign in at admin.mistral.ai and paste a fresh Cookie header in Settings to reconnect.",
                 "Mistral-økten er utløpt eller avvist. Logg inn på admin.mistral.ai og lim inn en fersk Cookie-overskrift i Innstillinger for å koble til igjen.")
    case "opencode":
        return L("Sign-in rejected. Run opencode auth login again, or paste a key under Add Account.",
                 "Påloggingen ble avvist. Kjør opencode auth login på nytt, eller lim inn en nøkkel under Legg til konto.")
    case "anthropic":
        return L("Anthropic rejected this key for spend data. It needs an Admin key (sk-ant-admin…), which only an organization admin can create in the Claude Console; a normal API key can't read spend. Replace the key in Settings.",
                 "Anthropic avviste denne nøkkelen for forbruksdata. Det kreves en Admin-nøkkel (sk-ant-admin…), som bare en organisasjonsadministrator kan opprette i Claude Console; en vanlig API-nøkkel kan ikke lese forbruk. Bytt nøkkelen i Innstillinger.")
    case "openai":
        return L("OpenAI rejected this key for spend data. It needs an Admin key (sk-admin-…) from the organization's Admin keys page; a project or user key (sk-proj-…) can't read spend. Replace the key in Settings.",
                 "OpenAI avviste denne nøkkelen for forbruksdata. Det kreves en Admin-nøkkel (sk-admin-…) fra organisasjonens side for Admin-nøkler; en prosjekt- eller brukernøkkel (sk-proj-…) kan ikke lese forbruk. Bytt nøkkelen i Innstillinger.")
    case "devin":
        return L("Sign-in rejected. Run devin auth login again.",
                 "Påloggingen ble avvist. Kjør devin auth login på nytt.")
    default:
        return message
    }
}
#endif
