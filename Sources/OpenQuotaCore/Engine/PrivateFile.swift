import Foundation

/// Writes app-owned files readable only by the current user: the parent
/// directory is 0700 and the file is 0600 before it is moved into place.
enum PrivateFile {
    static func write(_ data: Data, to url: URL) throws {
        let fm = FileManager.default
        let dir = url.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // createDirectory ignores attributes on pre-existing dirs; tighten in
        // place so installs from before PrivateFile converge on 0700 too.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let temp = dir.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard fm.createFile(atPath: temp.path, contents: data,
                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(temp.path, url.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
