import AppKit
import CoreImage
import EmulsionCore
import EmulsionUI
import Observation
import UniformTypeIdentifiers

enum ExportFormat: String, CaseIterable, Identifiable {
    case jpeg = "JPEG", heic = "HEIC", tiff = "TIFF"

    var id: String { rawValue }
    var type: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heic: .heic
        case .tiff: .tiff
        }
    }
    var fileExtension: String {
        switch self {
        case .jpeg: "jpg"
        case .heic: "heic"
        case .tiff: "tiff"
        }
    }
}

/// App-level state: the open photo, its editor, and export.
@MainActor
@Observable
final class AppState {
    let library: FilmLibrary?
    private(set) var editor: EditorModel?
    private(set) var sourceURL: URL?
    var errorMessage: String?
    var showExportSheet = false
    private(set) var isExporting = false

    @ObservationIgnored private var scopedURL: URL?

    init() {
        library = FilmLibrary.bundled()
    }

    var hasPhoto: Bool { editor != nil }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Open a Photo"
        if panel.runModal() == .OK, let url = panel.url { open(url: url) }
    }

    func open(url: URL) {
        guard let library else {
            errorMessage = "Emulsion could not load its film library."
            return
        }
        scopedURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        scopedURL = url
        let model = EditorModel(library: library)
        guard model.loadSource(url: url) else {
            errorMessage = "\(url.lastPathComponent) could not be opened as an image."
            return
        }
        editor = model
        sourceURL = url
    }

    func export(format: ExportFormat, quality: Double) {
        guard let editor, let sourceURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.type]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = sourceURL.deletingPathExtension().lastPathComponent
            + " Emulsion." + format.fileExtension
        panel.title = "Export Photo"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }

        let recipe = editor.recipe
        let renderer = editor.renderer
        let type = format.type
        isExporting = true
        Task {
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result { try renderer.export(recipe, inputURL: sourceURL, outputURL: outputURL, type: type, quality: quality) }
            }.value
            isExporting = false
            if case .failure(let error) = result {
                errorMessage = "Export failed: \(error)"
            }
        }
    }
}
