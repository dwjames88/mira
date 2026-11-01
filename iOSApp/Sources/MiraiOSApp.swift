import SwiftUI
import MiraUI

@main
struct MiraiOSApp: App {
    init() {
        FieldFramesTheme.registerFonts()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
        }
    }
}
