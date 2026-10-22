import AppKit
import MiraUI
import SwiftUI

@main
struct MiraApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AppearancePreference.key) private var appearanceRaw = AppearancePreference.system.rawValue

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
                Button("Check for Updates\u{2026}") { UpdateController.shared.checkManually() }
            }
            CommandGroup(replacing: .newItem) {
                Button("Open\u{2026}") { state.presentOpenPanel() }
                    .keyboardShortcut("o")
                Divider()
                Button("Export\u{2026}") { state.showExportSheet = true }
                    .keyboardShortcut("e")
                    .disabled(!state.canExport)
                Button(state.saveTitle) { Task { await state.saveNow() } }
                    .keyboardShortcut("s")
                    .disabled(!state.canSaveNow)
                Button("Revert to Original\u{2026}") { state.showRevertConfirm = true }
                    .disabled(!state.canRevertNow)
                Divider()
                Button("Back to Library") { state.showLibrary() }
                    .keyboardShortcut(.leftArrow, modifiers: .command)
                    .disabled(!state.hasPhoto)
            }
            CommandGroup(before: .toolbar) {
                ForEach(EditorTab.allCases) { tab in
                    Button(tab.title) { state.editor?.selectTab(tab) }
                        .keyboardShortcut(KeyEquivalent(Character(tab.key)), modifiers: [])
                        .disabled(!state.canUseEditorView)
                }
                Divider()
                Button("Toggle Full Screen") { state.editor?.toggleImmersive() }
                    .keyboardShortcut("f", modifiers: [])
                    .disabled(!state.canUseEditorView || state.isCropping)
                Divider()
                Button("Zoom In") { state.editor?.zoomStep(1) }
                    .keyboardShortcut("]", modifiers: [])
                    .disabled(!state.canZoom)
                Button("Zoom Out") { state.editor?.zoomStep(-1) }
                    .keyboardShortcut("[", modifiers: [])
                    .disabled(!state.canZoom)
                Button("Zoom to Fit") { state.editor?.zoomToFit() }
                    .keyboardShortcut("0")
                    .disabled(!state.canZoom)
                Divider()
            }
            CommandGroup(after: .toolbar) {
                Menu("Appearance") {
                    Picker("Appearance", selection: $appearanceRaw) {
                        ForEach(AppearancePreference.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                }
            }
            CommandGroup(after: .undoRedo) {
                Divider()
                Button("Reset Adjustments") { state.resetAdjustments() }
                    .disabled(!state.canResetAdjustments)
                Button("Reset All") { state.resetAll() }
                    .disabled(!state.canResetAll)
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
