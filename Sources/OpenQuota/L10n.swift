#if os(macOS)
import OpenQuotaCore

/// English/Norwegian UI copy; see `Localized`.
func L(_ en: String, _ nb: String) -> String { Localized.text(en, nb) }
#endif
