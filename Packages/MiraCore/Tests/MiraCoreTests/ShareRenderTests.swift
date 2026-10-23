import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MiraCore

@Suite("ShareRender")
struct ShareRenderTests {
    private func props(_ url: URL) -> [CFString: Any] {
        CGImageSourceCopyPropertiesAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil) as! [CFString: Any]
    }

    @Test func fileNames() {
        #expect(ShareRender.fileName(baseName: "IMG_0042", type: .jpeg) == "IMG_0042 - Mira.jpg")
        #expect(ShareRender.fileName(baseName: "a/b:c", type: .heic) == "a-b-c - Mira.heic")
        #expect(ShareRender.fileName(baseName: " ", type: .jpeg) == "Photo - Mira.jpg")
    }

    @Test func writesUprightFullSizeFileInExportFormat() throws {
        let r = Renderer(library: try emptyLibrary())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-share-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 120x80 tagged orientation 6: the upright picture is 80x120.
        let src = dir.appendingPathComponent("in.jpg")
        let cg = Renderer.sharedContext.createCGImage(
            Fixture.gradientAndPatches(size: 120).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 80)),
            from: CGRect(x: 0, y: 0, width: 120, height: 80))!
        let d = CGImageDestinationCreateWithURL(src as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(d))
        let loaded = try #require(ImageSource.loadWithColorSpace(url: src))

        for type in [UTType.jpeg, .heic] {
            let url = try ShareRender.render(Recipe(exposure: 0.2), source: loaded.image, metadataFrom: src,
                                             baseName: "in", type: type, quality: 0.9, colorSpace: loaded.colorSpace,
                                             renderer: r, directory: dir.appendingPathComponent(type.identifier))
            #expect(url.lastPathComponent == "in - Mira." + ShareRender.fileExtension(for: type))
            let p = props(url)
            #expect(p[kCGImagePropertyPixelWidth] as? Int == 80)
            #expect(p[kCGImagePropertyPixelHeight] as? Int == 120)
            #expect((p[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
            let sourceType = CGImageSourceGetType(CGImageSourceCreateWithURL(url as CFURL, nil)!) as String?
            #expect(sourceType == type.identifier)
        }
    }

    @Test func fixtureKeepsFullSize() throws {
        var fixture = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { fixture.deleteLastPathComponent() }
        fixture.appendPathComponent("Fixtures/sample.jpg")
        let r = Renderer(library: try emptyLibrary())
        let loaded = try #require(ImageSource.loadWithColorSpace(url: fixture))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-share-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = try ShareRender.render(Recipe(exposure: 0.1, grainAmount: 0.2), source: loaded.image, metadataFrom: fixture,
                                         baseName: "sample", type: .jpeg, quality: 0.92, colorSpace: loaded.colorSpace,
                                         renderer: r, directory: dir)
        let p = props(url)
        #expect(p[kCGImagePropertyPixelWidth] as? Int == Int(loaded.image.extent.width))
        #expect(p[kCGImagePropertyPixelHeight] as? Int == Int(loaded.image.extent.height))
        #expect((p[kCGImagePropertyOrientation] as? Int ?? 1) == 1)
    }

    /// Timing only (printed): a synthetic 24 MP picture through the share render.
    @Test func timesA24MegapixelRender() throws {
        let r = Renderer(library: try emptyLibrary())
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 6000, y: 4000),
            "inputColor0": CIColor(red: 0.1, green: 0.2, blue: 0.5), "inputColor1": CIColor(red: 0.9, green: 0.7, blue: 0.3),
        ])!.outputImage!.cropped(to: CGRect(x: 0, y: 0, width: 6000, height: 4000))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-share-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()
        let url = try ShareRender.render(Recipe(exposure: 0.2, grainAmount: 0.3, halationAmount: 0.3), source: gradient,
                                         metadataFrom: nil, baseName: "big", type: .jpeg, quality: 0.92,
                                         colorSpace: space, renderer: r, directory: dir)
        print("SHARE 24MP render+write: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        #expect(props(url)[kCGImagePropertyPixelWidth] as? Int == 6000)
    }

    @Test func stagingReplacesPreviousAndClearsStale() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("mira-stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }
        let old = parent.appendingPathComponent(ShareRender.directoryPrefix + "old")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let other = parent.appendingPathComponent("keep-me")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

        let staging = ShareRender.Staging(parent: parent)
        staging.removeStale()
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        let first = try staging.nextDirectory()
        let second = try staging.nextDirectory()
        #expect(first != second)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
    }
}
