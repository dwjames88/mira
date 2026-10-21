import AppKit
import MiraUI
import Observation

/// Applies the stored appearance preference to `NSApp` and publishes the real effective appearance,
/// so the toolbar glyph is right even while following the system.
@MainActor
@Observable
final class AppearanceController {
    static let shared = AppearanceController()

    private(set) var isDark = false
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        apply()
        observation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { _, _ in
            Task { @MainActor in AppearanceController.shared.refresh() }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in AppearanceController.shared.apply() }
        }
    }

    private func apply() {
        let preference = AppearancePreference(storedValue: UserDefaults.standard.string(forKey: AppearancePreference.key))
        let appearance = preference.nsAppearance
        if NSApp.appearance?.name != appearance?.name { NSApp.appearance = appearance }
        refresh()
    }

    private func refresh() {
        let dark = NSApp.effectiveAppearance.isDarkAqua
        if dark != isDark { isDark = dark }
    }
}
