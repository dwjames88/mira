import AppKit
import MiraUI
import SwiftUI

@main
struct MiraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    init() {
        FieldFramesTheme.registerFonts()
    }

    var body: some Scene {
        Window("Mira", id: "main") {
            ContentView(state: state)
                .frame(minWidth: 900, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About Mira") { openWindow(id: "about") }
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
            CommandGroup(after: .toolbar) {
                Button("Crop") { state.editor?.toggleCrop() }
                    .keyboardShortcut("k")
                    .disabled(state.editor?.source == nil || state.isBusy)
            }
        }

        Window("About Mira", id: "about") {
            AboutView(library: state.library)
        }
        .defaultSize(width: 560, height: 720)
        .windowToolbarStyle(.unified)

        Settings {
            SettingsView()
        }
        .windowToolbarStyle(.unified)
    }
}
