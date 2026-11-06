import AppKit
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

/// Round 3 "before/after" snapshot of the editor as the Photos editing extension hosts it: `ExtensionHosting.install`
/// into a window-sized container (the exact view Photos' window owns), in a window that is never ordered front, so
/// nothing appears on screen. Writes `build/snapshots/extension-host-<tab>-<tag>.png` (1100x750, the extension's
/// default window size). Test code only.
@MainActor
@Suite("Baseline snapshots", .serialized)
struct BaselineSnapshotTests {
    @Test func extensionHostScreens() async throws {
        FieldFramesTheme.registerFonts()
        // A temp preset store: the shared one is the user's real App Group file, which would put their presets in the shot.
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        let model = EditorModel(library: library, presetStore: PresetModelTests.tempStore())
        #expect(model.loadSource(url: SnapshotTests.root.appendingPathComponent("Fixtures/sample.jpg")))
        model.recipe.filmID = "fuji-velvia-50"
        model.recipe.grainAmount = 0.4
        model.recipe.halationAmount = 0.3
        try await HoverTests.waitFor(90) { model.previewImage != nil && model.thumbnailsSettled && model.isPreviewIdle }
        #expect(model.previewImage != nil && model.thumbnailsSettled)
        let size = CGSize(width: 1100, height: 750)
        let dir = SnapshotTests.root.appendingPathComponent("build/snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (tag, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
            window.appearance = NSAppearance(named: appearance)
            let container = NSView(frame: NSRect(origin: .zero, size: size))
            window.contentView = container
            let host = ExtensionHosting.install(model, in: container)
            for tab in [EditorTab.films, .develop] {
                model.selectTab(tab)
                if tab == .develop { await model.refreshHistogramNow() }
                try await HoverTests.waitFor { model.isPreviewIdle }
                try await SnapshotSettle.settle(model)
                container.layoutSubtreeIfNeeded()
                host.layoutSubtreeIfNeeded()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try #require(rep.representation(using: .png, properties: [:]))
                try png.write(to: dir.appendingPathComponent("extension-host-\(tab == .films ? "films" : "develop")-\(tag).png"))
            }
            host.removeFromSuperview()
        }
        model.selectTab(.films)
        model.cancelWork()
    }
}
