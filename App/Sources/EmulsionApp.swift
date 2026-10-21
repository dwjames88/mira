import AppKit
import EmulsionUI
import SwiftUI

@main
struct EmulsionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        FieldFramesTheme.registerFonts()
    }

    var body: some Scene {
        Window("Emulsion", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Emulsion") { showAbout() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") { state.presentOpenPanel() }
                    .keyboardShortcut("o")
                Button("Save to Photos") { Task { await state.saveToPhotos() } }
                    .keyboardShortcut("s")
                    .disabled(!state.canSave)
                Button("Export\u{2026}") { state.showExportSheet = true }
                    .keyboardShortcut("e")
                    .disabled(!state.hasPhoto)
            }
            CommandGroup(after: .windowArrangement) {
                Button("Films") { openWindow(id: "films") }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }

        Window("Films", id: "films") {
            if let library = state.library {
                FilmsBrowserView(library: library)
            } else {
                Text("The film library could not be loaded.").padding()
            }
        }
        .defaultSize(width: 520, height: 620)
    }

    private func showAbout() {
        let credits = NSAttributedString(
            string: "Film looks are from the RawTherapee Film Simulation Collection by Pat David, licensed under CC BY-SA 4.0 (creativecommons.org/licenses/by-sa/4.0). Film stock names are used for information only; Emulsion is not affiliated with any film maker.",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.labelColor])
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
