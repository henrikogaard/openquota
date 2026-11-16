#if os(macOS)
import SwiftUI
import OpenQuotaCore

@main
struct OpenQuotaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @AppStorage(Localized.languageKey) private var language = ""

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
                .id(language)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        // The panes' minimum size is the window's minimum; see SettingsWindowSizing.
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// A click on the Dock icon (shown while Settings is open) brings Settings
    /// back, also after the app was hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        sender.unhide(nil)
        sender.activate()
        return true
    }
}
#else
// The app shell is macOS-only; the Linux build exists so CI can compile and
// test OpenQuotaCore. This gives the executable an entry point there.
@main
struct LinuxPlaceholder {
    static func main() {
        print("openquota is a macOS menu-bar app. OpenQuotaCore and tests run on Linux.")
    }
}
#endif
