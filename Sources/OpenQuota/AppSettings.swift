#if os(macOS)
import Foundation
import OpenQuotaCore

/// User preferences + user-defined provider specs. Persisted as JSON in
/// Application Support — no UserDefaults dance, atomic writes, small file.
struct AppSettings {
    /// Custom providers the user added via a spec file/paste.
    func userSpecs() -> [ProviderSpec] {
        let url = Self.specsURL
        guard let data = try? Data(contentsOf: url),
              let specs = try? JSONDecoder().decode([ProviderSpec].self, from: data)
        else { return [] }
        return specs
    }

    static var specsURL: URL {
        AppModel.appSupportDir.appendingPathComponent("provider-specs.json")
    }
}
#endif
