#if os(macOS)
import SwiftUI
import OpenQuotaCore

@main
struct OpenQuotaApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
                .frame(width: 360)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
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
