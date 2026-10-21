#if os(macOS)
import Foundation
import Observation
import ServiceManagement

/// Registers the app itself as a login item through `SMAppService.mainApp`.
/// The system owns the state; users can also change it in System Settings.
@MainActor @Observable
final class LoginItemController {
    static let shared = LoginItemController()

    private(set) var status: SMAppService.Status = SMAppService.mainApp.status
    private(set) var errorText: String?

    private init() {}

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        errorText = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else if SMAppService.mainApp.status != .notRegistered {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorText = enabled
                ? L("OpenQuota couldn't be added to your login items. Move it to Applications and try again.",
                    "OpenQuota kunne ikke legges til påloggingsobjektene. Flytt appen til Programmer og prøv igjen.")
                : L("OpenQuota couldn't be removed from your login items. Remove it in System Settings → General → Login Items.",
                    "OpenQuota kunne ikke fjernes fra påloggingsobjektene. Fjern den i Systeminnstillinger → Generelt → Påloggingsobjekter.")
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
#endif
