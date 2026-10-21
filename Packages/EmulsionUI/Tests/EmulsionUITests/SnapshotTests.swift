import AppKit
import EmulsionCore
import SwiftUI
import Testing
@testable import EmulsionUI

/// Headless visual check: renders the editor and the films browser to PNGs in `<repo>/build/snapshots/`.
@MainActor
@Suite("Snapshots", .serialized)
struct SnapshotTests {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url
    }()

    static func writePNG<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, name: String) throws {
        let renderer = ImageRenderer(content:
            view
                .frame(width: size.width, height: size.height)
                .environment(\.ffInlineScroll, true)
                .environment(\.colorScheme, scheme))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(size)
        guard let cg = renderer.cgImage else { throw SnapshotError.noImage(name) }
        let rep = NSBitmapImageRep(cgImage: cg)
        let dir = root.appendingPathComponent("build/snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent("\(name).png"))
    }

    enum SnapshotError: Error { case noImage(String) }

    static func makeModel() async throws -> EditorModel {
        let library = try FilmLibrary(directory: root.appendingPathComponent("Films"))
        let model = EditorModel(library: library)
        #expect(model.loadSource(url: root.appendingPathComponent("Fixtures/sample.jpg")))
        model.recipe.filmID = "fuji-velvia-50"
        model.recipe.grainAmount = 0.4
        model.recipe.halationAmount = 0.3
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if model.previewImage != nil, model.thumbnails.count >= library.films.count + 1 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.previewImage != nil)
        #expect(model.thumbnails.count == library.films.count + 1)
        return model
    }

    @Test func renderEditorAndBrowser() async throws {
        FieldFramesTheme.registerFonts()
        let model = try await Self.makeModel()
        for (scheme, tag) in [(ColorScheme.dark, "dark"), (.light, "light")] {
            try Self.writePNG(EditorView(model: model), size: CGSize(width: 1280, height: 800), scheme: scheme, name: "editor-\(tag)")
            try Self.writePNG(FilmsBrowserView(library: model.library), size: CGSize(width: 1280, height: 800), scheme: scheme, name: "films-\(tag)")
        }
        try Self.writePNG(FilmsBrowserView(library: model.library), size: CGSize(width: 1280, height: 3000), scheme: .dark, name: "films-tall-dark")
        if let bw = model.films.first(where: { $0.family == .blackAndWhite }) {
            model.hoverFilm(bw.id)
            let deadline = Date().addingTimeInterval(30)
            while model.hoverPreviewFilm == nil, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
            #expect(model.hoverPreviewFilm?.id == bw.id)
            try Self.writePNG(EditorView(model: model), size: CGSize(width: 1280, height: 800), scheme: .dark, name: "editor-hover-dark")
            model.endHover()
        }
        model.recipe.filmID = nil
        try Self.writePNG(EditorView(model: model), size: CGSize(width: 1280, height: 800), scheme: .dark, name: "editor-original-dark")
        model.cancelWork()
    }
}
