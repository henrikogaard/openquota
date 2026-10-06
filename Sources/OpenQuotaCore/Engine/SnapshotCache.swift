import Foundation

/// Persists snapshots to a single small JSON file, written atomically.
/// Bounded by design: it only ever holds one entry per configured account,
/// so size is O(accounts), not O(history) — the file that ate CodexBar (#2637)
/// grew per scanned session file; this one can't.
public struct SnapshotCache: Sendable {
    private let url: URL
    /// Safety valve: refuse to load a cache above this size — it would mean
    /// something else wrote junk here. 256 KB is ~100 accounts' worth.
    static let maxBytes: UInt64 = 256 * 1024

    public init(url: URL) {
        self.url = url
    }

    public func load() -> [String: UsageSnapshot] {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size <= Self.maxBytes,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder.openQuota.decode([String: UsageSnapshot].self, from: data)
        else { return [:] }
        return dict
    }

    public func save(_ snapshots: [String: UsageSnapshot]) throws {
        let data = try JSONEncoder.openQuota.encode(snapshots)
        guard data.count <= Self.maxBytes else {
            throw ProviderError.badResponse("snapshot cache exceeds 256 KB")
        }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static var openQuota: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    static var openQuota: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
