import SwiftUI
import MiraUI

@main
struct MiraiOSApp: App {
    @UIApplicationDelegateAdaptor(MiraAppDelegate.self) private var appDelegate

    init() {
        FieldFramesTheme.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .onOpenURL { url in PresetHub.shared.startImport([url]) }
        }
    }
}
