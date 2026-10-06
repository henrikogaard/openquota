#if os(macOS)
import Foundation
import Sparkle

/// Sparkle auto-updates — same setup as LinkRouter: appcast attached to each
/// GitHub release, EdDSA-signed, background checks on.
final class UpdateController {
    static let shared = UpdateController()

    private let controller = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    private init() {}

    var canCheckForUpdates: Bool {
        controller.updater.canCheckForUpdates
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif
