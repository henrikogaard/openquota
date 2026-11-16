#if os(macOS)
import AppKit
import SwiftUI

/// Gives OpenQuota a Dock icon and a ⌘-Tab entry only while the Settings
/// window is open, so the window can be found again after another app covers
/// it. The menu-bar popover never adds one; closing Settings removes it.
///
/// The state is one flag that follows the window's visibility, so opening
/// Settings again while it is open changes nothing, and every close ends in
/// `.accessory`.
struct SettingsDockPresence: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        private var observers: [NSObjectProtocol] = []
        private var shown = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                // Removed from the window without a close: never leave the icon behind.
                if shown {
                    shown = false
                    NSApp.setActivationPolicy(.accessory)
                }
                return
            }
            let center = NotificationCenter.default
            // Fires when the window is ordered in or out, including a reopen
            // of the same window.
            observers.append(center.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    // Hiding the app (⌘H) orders the window out but keeps it
                    // open; it must stay reachable from the Dock.
                    guard !NSApp.isHidden else { return }
                    // A minimized window keeps the icon, or it could not be restored.
                    self?.update(window, shown: window.isVisible || window.isMiniaturized)
                }
            })
            observers.append(center.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self] note in
                guard let window = note.object as? NSWindow else { return }
                MainActor.assumeIsolated { self?.update(window, shown: false) }
            })
            update(window, shown: window.isVisible || window.isMiniaturized)
        }

        private func update(_ window: NSWindow, shown: Bool) {
            guard shown != self.shown else { return }
            self.shown = shown
            if shown {
                NSApp.setActivationPolicy(.regular)
                // Right after the switch to `.regular` the app is not yet
                // frontmost, so the window would stay behind other apps.
                DispatchQueue.main.async { [weak window] in
                    NSApp.activate()
                    window?.makeKeyAndOrderFront(nil)
                }
            } else {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
#endif
