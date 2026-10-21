import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Started from a terminal (`swift run`, or the built binary) there is no app bundle, and macOS then treats the process as one that may not
    /// own the keyboard: windows draw, but nothing can be typed. A regular, active app has a menu bar, a Dock icon and keyboard focus.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        LaunchHarness.applicationDidFinishLaunching()
    }

    /// The Dock badge shows a pending approval; it must not outlive the app.
    func applicationWillTerminate(_ notification: Notification) {
        NSApp.dockTile.badgeLabel = nil
    }
}
