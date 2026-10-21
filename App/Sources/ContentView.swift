import EmulsionUI
import SwiftUI

struct ContentView: View {
    @Bindable var state: AppState
    @Environment(\.openWindow) private var openWindow
    @State private var isTargeted = false

    var body: some View {
        Group {
            if let editor = state.editor {
                EditorView(model: editor)
            } else {
                EmptyState(state: state)
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
                Button("Open", systemImage: "photo.badge.plus") { state.presentOpenPanel() }
                Button("Films", systemImage: "film.stack") { openWindow(id: "films") }
                Button("Export", systemImage: "square.and.arrow.up") { state.showExportSheet = true }
                    .disabled(!state.hasPhoto || state.isExporting)
            }
        }
        .sheet(isPresented: $state.showExportSheet) {
            ExportSheet(state: state)
        }
        .alert("Emulsion", isPresented: Binding(
            get: { state.errorMessage != nil },
            set: { if !$0 { state.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.errorMessage ?? "")
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
