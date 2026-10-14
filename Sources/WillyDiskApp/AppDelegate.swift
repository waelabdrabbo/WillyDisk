import AppKit

/// Application lifecycle delegate.
///
/// Ensures the process behaves as a normal macOS app (Dock icon + menu bar) both
/// when launched from the bundled `.app` and when run as a bare executable via
/// `swift run WillyDisk`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
