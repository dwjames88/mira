import AppKit

/// Receives files from Finder / `open -a Mira file.jpg`, for cold launch and a running app alike.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppearanceController.shared.start() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Background update check (at most daily, silent unless there is news); never blocks launch.
        MainActor.assumeIsolated { UpdateController.shared.checkAtLaunch() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppState.shared.handleOpen(urls)
        }
    }
}
