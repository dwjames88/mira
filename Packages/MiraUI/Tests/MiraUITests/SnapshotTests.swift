import AppKit
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

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
                .environment(\.ffImageCanvas, true)
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
        }
        try Self.writePNG(AboutView(library: model.library, version: "VERSION 0.1.0 (1)"),
                          size: CGSize(width: 560, height: 2500), scheme: .dark, name: "about-dark")
        try Self.writePNG(SettingsView(), size: CGSize(width: 480, height: 384), scheme: .light, name: "settings-light")
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
        model.recipe.filmID = "fuji-velvia-50"

        // Crop mode: 3:2 box, 6 degrees straighten, grid forced on so it can be inspected.
        model.beginCrop()
        model.straighten = 6
        model.setAspect("3:2")
        let canvas = try #require(model.cropCanvasSize)
        let boxW = 0.72, boxH = boxW * canvas.width / canvas.height / 1.5
        model.crop.rect = CropRect(x: 0.16, y: 0.2, w: boxW, h: boxH)
        let deadline = Date().addingTimeInterval(30)
        let canvasBefore = model.previewImage
        while model.previewImage === canvasBefore, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        try Self.writePNG(EditorView(model: model).environment(\.ffCropForceGrid, true),
                          size: CGSize(width: 1280, height: 800), scheme: .dark, name: "editor-crop-dark")
        model.cancelCrop()
        model.cancelWork()
    }

    /// The sub-toolbar and each tab: `editor-tab-films.png`, `editor-tab-develop.png`, `editor-tab-crop.png`.
    @Test func renderTabs() async throws {
        FieldFramesTheme.registerFonts()
        let model = try await Self.makeModel()
        let host = EditorHostBar(onLibrary: {}, status: "UNSAVED", statusHelp: nil,
                                 save: .init(isEnabled: true, isSaved: false, action: {}))
        let size = CGSize(width: 1280, height: 800)

        model.selectTab(.films)
        try Self.writePNG(EditorView(model: model, host: host), size: size, scheme: .dark, name: "editor-tab-films")

        model.selectTab(.develop)
        await model.refreshHistogramNow()
        try Self.writePNG(EditorView(model: model, host: host), size: size, scheme: .dark, name: "editor-tab-develop")

        model.selectTab(.crop)
        model.straighten = 4
        model.setAspect("3:2")
        let before = model.previewImage
        let deadline = Date().addingTimeInterval(30)
        while model.previewImage === before, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(300))
        try Self.writePNG(EditorView(model: model, host: host).environment(\.ffCropForceGrid, true),
                          size: size, scheme: .dark, name: "editor-tab-crop")

        // The extension's bar: tabs only.
        model.selectTab(.films)
        try Self.writePNG(EditorView(model: model), size: size, scheme: .light, name: "editor-tab-films-extension-light")
        model.cancelWork()
    }
}
