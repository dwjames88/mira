import MiraUI
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @State private var isTargeted = false

    /// F / full screen: only the photo on ink remains, so the window toolbar and its hairline go too.
    private var isImmersive: Bool { state.mode == .editor && (state.editor?.isImmersive ?? false) }

    var body: some View {
        Group {
            switch state.mode {
            case .library:
                LibraryView(state: state)
            case .editor:
                if let editor = state.editor {
                    EditorScreen(state: state, editor: editor)
                } else {
                    EmptyState(state: state)
                }
            }
        }
        .overlay {
            if isTargeted {
                Rectangle()
                    .strokeBorder(FieldFramesTheme.lichen, lineWidth: 1)
                    .padding(FieldFramesTheme.cells(1))
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            state.open(url: url)
            return true
        } isTargeted: { isTargeted = $0 }
        .fieldFramesWindow()
        .safeAreaInset(edge: .top, spacing: 0) { if !isImmersive { FFHairline() } }
        .toolbar(removing: .title)
        .toolbar {
            // The window toolbar carries only the wordmark; every command lives in the menu bar.
            ToolbarItem(placement: .navigation) {
                Text("Mira")
                    .font(FieldFramesTheme.display(18))
                    .foregroundStyle(FieldFramesTheme.paper)
                    .padding(.horizontal, FieldFramesTheme.cells(1))
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .toolbarBackground(FieldFramesTheme.ink, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbar(isImmersive ? .hidden : .visible, for: .windowToolbar)
        .sheet(isPresented: $state.showExportSheet) {
            ExportSheet(state: state)
        }
        .confirmationDialog("You have unsaved changes", isPresented: $state.showLeaveDialog, titleVisibility: .visible) {
            Button("Save to Photos") { state.confirmLeaveSaving() }
            Button("Discard Changes", role: .destructive) { state.confirmLeaveDiscarding() }
            Button("Cancel", role: .cancel) { state.cancelLeave() }
        } message: {
            Text("This edit has not been saved to your Photos library.")
        }
        .confirmationDialog("Revert to original?", isPresented: $state.showRevertConfirm, titleVisibility: .visible) {
            Button("Revert to Original", role: .destructive) { Task { await state.revertToOriginal() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(state.isAssetTarget
                 ? "This removes the edit from the picture in Photos. The original is untouched."
                 : "This deletes the saved recipe (sidecar) for this file. The file itself is untouched.")
        }
        .alert("Mira", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
        }
        .task { state.runSelfTestsIfRequested() }
    }
}

/// The editor with the app's sub-toolbar extras (LIBRARY, status, SAVE) and, when the "Show
/// edit-source footer" setting is on, a mono footer under the canvas: sidecar / Photos status,
/// notes and progress.
private struct EditorScreen: View {
    let state: AppState
    let editor: EditorModel

    private var hostBar: EditorHostBar {
        let status = state.toolbarStatus
        return EditorHostBar(
            onLibrary: { state.showLibrary() },
            status: status,
            statusHelp: state.toolbarStatusHelp,
            save: .init(isEnabled: state.canSaveNow, isSaved: status == "SAVED",
                        action: { Task { await state.saveNow() } }))
    }

    var body: some View {
        EditorView(model: editor, host: hostBar, windowFullScreen: true) {
            EditorFooter(state: state)
        }
        .disabled(state.isOpening)
        .overlay {
            if let busy = state.busyText {
                VStack(spacing: FieldFramesTheme.rows(0.5)) {
                    Text(busy).font(FieldFramesTheme.display(30, weight: .medium))
                    if let p = state.busyProgress {
                        ProgressView(value: p).frame(width: FieldFramesTheme.cells(24))
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(FieldFramesTheme.cells(4))
                .background(FieldFramesTheme.ink)
                .overlay(Rectangle().strokeBorder(FieldFramesTheme.hair, lineWidth: 1))
            }
        }
    }
}

private struct EditorFooter: View {
    @AppStorage(MiraSettings.showEditSourceFooterKey) private var showFooter = false
    let state: AppState

    var body: some View {
        if showFooter {
            VStack(spacing: 0) {
                FFHairline()
                HStack(spacing: FieldFramesTheme.cells(2)) {
                    if let status = state.statusLine { Text(status).ffLabel(size: 10) }
                    if let note = state.editorNote { Text(note).ffLabel(size: 10, color: FieldFramesTheme.lichen) }
                    Spacer()
                    if let result = state.resultLine { Text(result).ffLabel(size: 10, color: FieldFramesTheme.lichen) }
                    if state.isDirty { Text("UNSAVED").ffLabel(size: 10, color: FieldFramesTheme.paperMid) }
                }
                .padding(.horizontal, FieldFramesTheme.cells(2))
                .frame(height: FieldFramesTheme.rows(2))
                .background { FFPanelBackground() }
            }
        }
    }
}

private struct EmptyState: View {
    let state: AppState

    var body: some View {
        FFEmptyState(
            title: "Open a photo",
            subtitle: "Drop an image here, or choose one to start",
            buttonTitle: "Open\u{2026}",
            note: "To edit inside Photos, open a picture, click Edit, then choose \u{22EF} \u{25B8} Extensions \u{25B8} Mira.",
            action: { state.presentOpenPanel() })
    }
}

private struct ExportSheet: View {
    @Bindable var state: AppState
    @State private var format = ExportFormat.jpeg
    @State private var quality = 0.92

    var body: some View {
        VStack(alignment: .leading, spacing: FieldFramesTheme.rows(1)) {
            Text("Export")
                .font(FieldFramesTheme.display(30, weight: .medium))
            FFTabBar(ExportFormat.allCases.map { (value: $0, title: $0.rawValue) }, selection: $format)
            FFHairline()
            if format != .tiff {
                FFSlider("Quality", value: $quality, in: 0.5...1, default: 0.92)
            }
            HStack(spacing: FieldFramesTheme.cells(1)) {
                Spacer()
                Button("Cancel") { state.showExportSheet = false }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.ff)
                Button("Export\u{2026}") {
                    state.showExportSheet = false
                    state.export(format: format, quality: quality)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.ffProminent)
            }
        }
        .padding(FieldFramesTheme.cells(3))
        .frame(width: FieldFramesTheme.cells(44))
        .fieldFramesWindow()
    }
}
