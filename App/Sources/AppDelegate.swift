import AppKit

/// Receives files from Finder / `open -a Mira file.jpg`, for cold launch and a running app alike.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppearanceController.shared.start() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppState.shared.handleOpen(urls)
        }
    }
}
