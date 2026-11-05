import Observation
import UIKit

/// The Home Screen quick action "Load film" (`com.fieldframes.mira.camera`) sets this flag; `RootView` reads it.
@MainActor @Observable
final class CameraLaunch {
    static let shared = CameraLaunch()
    static let shortcutType = "com.fieldframes.mira.camera"
    var cameraRequested = false

    @discardableResult
    func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == Self.shortcutType else { return false }
        cameraRequested = true
        return true
    }
}

/// Cold launches deliver the shortcut in the connection options; warm ones go to the scene delegate.
@MainActor
final class MiraAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let item = options.shortcutItem { CameraLaunch.shared.handle(item) }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = MiraSceneDelegate.self
        return configuration
    }
}

@MainActor
final class MiraSceneDelegate: NSObject, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        completionHandler(CameraLaunch.shared.handle(shortcutItem))
    }
}
