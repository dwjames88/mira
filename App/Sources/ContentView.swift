import MiraUI
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @State private var isTargeted = false

    /// A glass-free SF Symbol toolbar button; the old mono label is the accessibility label.
    private func iconButton(_ title: String, symbol: String, help: String, active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.ffToolbarIcon(active: active))
            .accessibilityLabel(title)
            .help(help)
    }

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
        .safeAreaInset(edge: .top, spacing: 0) { FFHairline() }
        .toolbar(removing: .title)
        .toolbar {
            // Left: wordmark, then Library (editor), Open, Crop (editor).
            ToolbarItem(placement: .navigation) {
                HStack(spacing: FieldFramesTheme.cells(1)) {
                    Text("Mira")
                        .font(FieldFramesTheme.display(18))
                        .foregroundStyle(FieldFramesTheme.paper)
                        .padding(.horizontal, FieldFramesTheme.cells(1))
                        .accessibilityAddTraits(.isHeader)
                    if state.mode == .editor {
                        iconButton("Library", symbol: "photo.on.rectangle.angled", help: "Back to the library") {
                            state.showLibrary()
                        }
                    }
                    iconButton("Open", symbol: "folder", help: "Open\u{2026} \u{2318}O") { state.presentOpenPanel() }
                    if state.mode == .editor, let editor = state.editor {
                        iconButton("Crop", symbol: "crop", help: "Crop, rotate and straighten \u{2318}K",
                                   active: editor.isCropping) { editor.toggleCrop() }
                            .disabled(editor.source == nil || state.isBusy)
                    }
                }
            }
            .sharedBackgroundVisibility(.hidden)
            // Right: status, Revert, Save, then Export at the trailing edge.
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: FieldFramesTheme.cells(1)) {
                    if state.mode == .editor {
                        if let status = state.toolbarStatus {
                            Text(status)
                                .ffLabel(size: 10, color: status == "UNSAVED" ? FieldFramesTheme.paperMid : FieldFramesTheme.lichen)
                                .padding(.trailing, FieldFramesTheme.cells(1))
                                .help(state.toolbarStatusHelp ?? "")
                        }
                        iconButton("Revert", symbol: "arrow.uturn.backward", help: "Revert to original") {
                            state.showRevertConfirm = true
                        }
                        .disabled(!state.canRevert || state.isCropping)
                        if state.isAssetTarget {
                            iconButton("Save", symbol: "checkmark.circle", help: "Save to Photos \u{2318}S", active: state.canSave) {
                                Task { await state.saveToPhotos() }
                            }
                            .disabled(!state.canSave || state.isCropping)
                        }
                    }
                    iconButton("Export", symbol: "square.and.arrow.up", help: "Export\u{2026} \u{2318}E") {
                        state.showExportSheet = true
                    }
                    .disabled(!state.hasPhoto || state.isExporting || state.isBusy || state.isCropping)
                }
            }
            .sharedBackgroundVisibility(.hidden)
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

/// The editor plus, when the "Show edit-source footer" setting is on, a mono footer: sidecar / Photos
/// status, notes and progress.
private struct EditorScreen: View {
    @AppStorage(MiraSettings.showEditSourceFooterKey) private var showFooter = false
    let state: AppState
    let editor: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            EditorView(model: editor)
                .disabled(state.isOpening)
            if showFooter {
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
