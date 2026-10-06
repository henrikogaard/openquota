#if os(macOS)
import Foundation
import OpenQuotaCore

/// User preferences + user-defined provider specs. Persisted as JSON in
/// Application Support — no UserDefaults dance, atomic writes, small file.
struct AppSettings {
    /// Custom providers the user added via a spec file/paste.
    func userSpecs() throws -> [ProviderSpec] {
        let url = Self.specsURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 1_048_576 else { throw ProviderError.badResponse("provider specs exceed 1 MiB") }
        let specs = try JSONDecoder().decode([ProviderSpec].self, from: Data(contentsOf: url))
        guard specs.count <= 100 else { throw ProviderError.badResponse("maximum 100 custom providers") }
        return specs
    }

    static var specsURL: URL {
        AppModel.appSupportDir.appendingPathComponent("provider-specs.json")
    }
}
#endif
