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
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            state.open(url: url)
            return true
        } isTargeted: { isTargeted = $0 }
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
        VStack(spacing: 16) {
            Image(systemName: "film")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("Open a photo")
                .font(.largeTitle.weight(.semibold))
            Text("Drop an image here, or choose one to start.")
                .foregroundStyle(.secondary)
            Button("Open\u{2026}") { state.presentOpenPanel() }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            Text("To edit inside Photos, open a picture, click Edit, then choose \u{22EF} \u{25B8} Extensions \u{25B8} Emulsion.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 12)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ExportSheet: View {
    @Bindable var state: AppState
    @State private var format = ExportFormat.jpeg
    @State private var quality = 0.92

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Export").font(.title2.weight(.semibold))
            Picker("Format", selection: $format) {
                ForEach(ExportFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if format != .tiff {
                LabeledContent("Quality") {
                    Slider(value: $quality, in: 0.5...1)
                        .frame(width: 180)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { state.showExportSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button("Export\u{2026}") {
                    state.showExportSheet = false
                    state.export(format: format, quality: quality)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}
