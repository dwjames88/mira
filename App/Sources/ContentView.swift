import EmulsionUI
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var isTargeted = false

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
        .toolbar {
            ToolbarItemGroup {
                if state.mode == .editor {
                    Button("Library", systemImage: "square.grid.3x3") { state.showLibrary() }
                }
                Button("Open", systemImage: "photo.badge.plus") { state.presentOpenPanel() }
                Button("Films", systemImage: "film.stack") { openWindow(id: "films") }
                Button("Export", systemImage: "square.and.arrow.up") { state.showExportSheet = true }
                    .disabled(!state.hasPhoto || state.isExporting || state.isBusy)
                if state.mode == .editor {
                    if state.isAssetTarget {
                        Button("Save", systemImage: "checkmark.circle") { Task { await state.saveToPhotos() } }
                            .disabled(!state.canSave)
                    }
                    Button("Revert", systemImage: "arrow.uturn.backward") { state.showRevertConfirm = true }
                        .disabled(!state.canRevert)
                }
            }
        }
        .toolbarBackground(FieldFramesTheme.ink, for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
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
        .alert("Emulsion", isPresented: Binding(
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

/// The editor plus a mono footer: sidecar / Photos status, notes and progress.
private struct EditorScreen: View {
    let state: AppState
    let editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            EditorView(model: editor)
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
        }
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

private struct EmptyState: View {
    let state: AppState

    var body: some View {
        FFEmptyState(
            title: "Open a photo",
            subtitle: "Drop an image here, or choose one to start",
            buttonTitle: "Open\u{2026}",
            note: "To edit inside Photos, open a picture, click Edit, then choose \u{22EF} \u{25B8} Extensions \u{25B8} Emulsion.",
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
