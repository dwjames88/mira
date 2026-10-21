import AppKit

/// Receives files from Finder / `open -a Emulsion file.jpg`, for cold launch and a running app alike.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated {
            AppState.shared.handleOpen(urls)
        }
    }
}
