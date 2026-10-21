import AppKit
import CoreGraphics
import CoreImage
import ImageIO
import MiraCore
import Testing
import UniformTypeIdentifiers
@testable import MiraUI

@MainActor
@Suite("Preview pipeline", .serialized)
struct PerformanceModelTests {
    static func model() throws -> EditorModel {
        let root = SnapshotTests.root
        let library = try FilmLibrary(directory: root.appendingPathComponent("Films"))
        let model = EditorModel(library: library)
        #expect(model.loadSource(url: root.appendingPathComponent("Fixtures/sample.jpg")))
        return model
    }

    static func bytes(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var data = [UInt8](repeating: 0, count: w * h * 4)
        data.withUnsafeMutableBytes { buf in
            let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return data
    }

    static func settle(_ model: EditorModel) async throws {
        try await HoverTests.waitFor { model.previewImage != nil && model.isPreviewIdle }
    }

    @Test func framesFollowTheReportedCanvas() async throws {
        let model = try Self.model()
        model.setCanvas(pixels: CGSize(width: 700, height: 500))
        try await Self.settle(model)
        // 2400x1600 fitted into the 704x512 quantised canvas.
        #expect(model.previewFrame?.pixelSize == CGSize(width: 704, height: 469))
        model.setCanvas(pixels: CGSize(width: 1500, height: 1000))
        try await HoverTests.waitFor { model.previewFrame?.pixelSize.width == 1536 && model.isPreviewIdle }
        #expect(model.previewFrame?.pixelSize == CGSize(width: 1536, height: 1024))
        model.cancelWork()
    }

    @Test func burstOfSliderChangesIsCoalescedAndLatestWins() async throws {
        let model = try Self.model()
        model.setCanvas(pixels: CGSize(width: 1500, height: 1000))
        try await Self.settle(model)
        let before = model.publishedFrames
        for i in 0..<60 { model.recipe.exposure = -1 + 2 * Double(i) / 59 }
        try await HoverTests.waitFor { model.isPreviewIdle }
        let frames = model.publishedFrames - before
        #expect(frames >= 1)
        #expect(frames < 60, "\(frames) frames rendered for 60 changes")

        // The settled frame is the last recipe: same pixels as rendering it directly.
        let direct = try #require(model.engine.render(model.recipe, canvas: CGSize(width: 1536, height: 1024)))
        let a = try #require(model.previewFrame?.cgImage(context: model.engine.context))
        let b = try #require(direct.cgImage(context: model.engine.context))
        #expect(Self.bytes(a) == Self.bytes(b))
        model.cancelWork()
    }

    @Test func holdToCompareStillShowsTheOriginal() async throws {
        let model = try Self.model()
        model.recipe.filmID = "fuji-velvia-50"
        model.recipe.saturation = 0.4
        try await Self.settle(model)
        try await HoverTests.waitFor { model.displayedFrame != nil }
        let graded = model.displayedFrame
        model.showOriginal = true
        let original = model.displayedFrame
        #expect(original != nil)
        #expect(original?.id != graded?.id)
        model.showOriginal = false
        #expect(model.displayedFrame?.id == graded?.id)
        model.cancelWork()
    }

    @Test func thumbnailsFollowTheCommittedCrop() async throws {
        let model = try Self.model()
        try await HoverTests.waitFor(60) { model.thumbnails.count == model.films.count + 1 }
        let tile = try #require(model.thumbnails[EditorModel.originalTileID])
        let before = tile.size
        #expect(before.width > before.height) // 3:2 landscape

        model.beginCrop()
        model.crop.rect = CropRect(x: 0.3, y: 0, w: 0.2, h: 1) // a tall sliver
        model.commitCrop()
        try await HoverTests.waitFor {
            guard let t = model.thumbnails[EditorModel.originalTileID] else { return false }
            return t.size.height > t.size.width
        }
        let cropped = try #require(model.thumbnails[EditorModel.originalTileID])
        #expect(cropped.size.height > cropped.size.width)
        // Every film tile was re-rendered for the crop.
        try await HoverTests.waitFor {
            model.thumbnails.values.allSatisfy { $0.size.height > $0.size.width }
        }
        #expect(model.thumbnails.values.allSatisfy { $0.size.height > $0.size.width })
        model.cancelWork()
    }

    /// A 3000x2000 JPEG opens through a stand-in and then the real photo, and `fullSource()` waits.
    @Test func largeFileOpensWithStandInThenFullSource() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: 3000, height: 2000, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.2, 0.5, 0.7, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: 3000, height: 2000))
        let url = dir.appendingPathComponent("big.jpg")
        let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))

        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        let model = EditorModel(library: library)
        #expect(model.loadSource(url: url))
        #expect(model.isSourceFull == false)
        #expect((model.source?.extent.width ?? 0) <= 1600)
        let full = await model.fullSource()
        #expect(full?.extent.size == CGSize(width: 3000, height: 2000))
        #expect(model.isSourceFull)
        #expect(model.source?.extent.size == CGSize(width: 3000, height: 2000))
        model.cancelWork()
    }
}
