#if os(macOS)
import Foundation
import Sparkle

/// Sparkle auto-updates — same setup as LinkRouter: appcast attached to each
/// GitHub release, EdDSA-signed, background checks on.
@MainActor
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

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#endif
