import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

@Suite struct PreviewEngineTests {
    let context = Renderer.sharedContext

    /// 2400x1600: red left half, blue right half, with a fine 2 px stripe pattern in the middle third.
    func stripes() -> CIImage {
        let w = 2400, h = 1600
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.9, 0.1, 0.1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(colorSpace: space, components: [0.1, 0.1, 0.9, 1])!)
        ctx.fill(CGRect(x: w / 2, y: 0, width: w / 2, height: h))
        ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        for x in stride(from: w / 3, to: 2 * w / 3, by: 4) { ctx.fill(CGRect(x: x, y: 0, width: 2, height: h)) }
        return CIImage(cgImage: ctx.makeImage()!)
    }

    func engine() throws -> PreviewEngine {
        PreviewEngine(renderer: Renderer(library: try emptyLibrary()), context: context)
    }

    @Test func frameSizeFollowsTheCanvas() throws {
        let e = try engine()
        e.setSource(stripes())
        let frame = try #require(e.render(.neutral, canvas: CGSize(width: 900, height: 900)))
        #expect(frame.pixelSize == CGSize(width: 900, height: 600))
        #expect(frame.surface != nil)
        let big = try #require(e.render(.neutral, canvas: CGSize(width: 9000, height: 9000)))
        #expect(big.pixelSize == CGSize(width: 2400, height: 1600)) // never upscaled
        #expect(big.id > frame.id)
    }

    @Test func fallbackSizeWithoutCanvas() throws {
        let e = try engine()
        e.setSource(stripes())
        let frame = try #require(e.render(.neutral, canvas: nil))
        #expect(frame.pixelSize == CGSize(width: 1600, height: 1067))
    }

    @Test func noSourceNoFrame() throws {
        let e = try engine()
        #expect(e.render(.neutral, canvas: nil) == nil)
    }

    @Test func basesAreCachedPerCropAndSize() throws {
        let e = try engine()
        e.setSource(stripes())
        let canvas = CGSize(width: 800, height: 800)
        let a = try #require(e.previewBase(crop: .identity, canvas: canvas))
        let b = try #require(e.previewBase(crop: .identity, canvas: canvas))
        #expect(a === b)
        var crop = CropSettings.identity
        crop.straighten = 3
        let c = try #require(e.previewBase(crop: crop, canvas: canvas))
        #expect(c !== a)
        e.setSource(stripes())
        let d = try #require(e.previewBase(crop: .identity, canvas: canvas))
        #expect(d !== a)
    }

    @Test func gradedFrameMatchesTheDirectRender() throws {
        let e = try engine()
        let source = stripes()
        e.setSource(source)
        let recipe = Recipe(exposure: 0.4, contrast: 0.3, saturation: 0.2, vignetteAmount: 0.3)
        let canvas = CGSize(width: 1200, height: 800)
        let frame = try #require(e.render(recipe, canvas: canvas))
        let engineCG = try #require(frame.cgImage(context: context))
        // Reference: the same grading on a Lanczos copy made straight from the full-size source.
        let r = Renderer(library: try emptyLibrary())
        let small = r.previewImage(from: source, maxPixelSize: 1200)
        let reference = try #require(r.render(recipe, input: small, context: context))
        #expect(engineCG.width == reference.width && engineCG.height == reference.height)
        let a = Pixels(CIImage(cgImage: engineCG), context: context).rgba
        let b = Pixels(CIImage(cgImage: reference), context: context).rgba
        let diffs = zip(a, b).map { abs(Double($0) - Double($1)) / 255 }
        #expect(mean(diffs) < 0.01, "mean difference \(mean(diffs))")
    }

    /// The crop is cut from the full-size source, so a tight crop keeps the detail a 1600 px copy lost.
    @Test func tightCropStaysSharp() throws {
        let e = try engine()
        let source = stripes()
        e.setSource(source)
        var recipe = Recipe.neutral
        recipe.crop.rect = CropRect(x: 0.35, y: 0.2, w: 0.3, h: 0.5) // 720 x 800 px of the striped middle
        let frame = try #require(e.render(recipe, canvas: CGSize(width: 1600, height: 1600)))
        #expect(frame.pixelSize == CGSize(width: 720, height: 800)) // every source pixel, no upscaling
        let sharp = Pixels(CIImage(cgImage: try #require(frame.cgImage(context: context))), context: context)

        // Old behaviour: crop applied to a 600 px copy of the whole picture.
        let r = Renderer(library: try emptyLibrary())
        let coarse = r.previewImage(from: source, maxPixelSize: 600)
        let blurry = Pixels(r.apply(recipe, to: coarse), context: context)

        func contrast(_ p: Pixels) -> Double {
            let row = (p.height / 2) * p.width
            let g = (0..<p.width).map { Double(p.rgba[(row + $0) * 4 + 1]) / 255 }
            return stddev(g)
        }
        #expect(contrast(sharp) > contrast(blurry) * 1.5, "sharp \(contrast(sharp)) vs old \(contrast(blurry))")
    }

    @Test func thumbnailsFollowTheCrop() throws {
        let e = try engine()
        e.setSource(stripes())
        // The right edge of the picture only: all blue.
        var crop = CropSettings.identity
        crop.rect = CropRect(x: 0.7, y: 0, w: 0.3, h: 1)
        nonisolated(unsafe) var delivered: [(String?, CGImage)] = []
        let lock = NSLock()
        e.renderThumbnails(ids: [nil, nil, nil], crop: crop, longSide: 128, workers: 2) { id, cg in
            lock.lock(); delivered.append((id, cg)); lock.unlock()
        }
        #expect(delivered.count == 3)
        let cg = try #require(delivered.first?.1)
        #expect(max(cg.width, cg.height) <= 128)
        #expect(Double(cg.width) / Double(cg.height) < 1) // 720 x 1600 crop is portrait
        let px = Pixels(CIImage(cgImage: cg), context: context)
        #expect(mean(px.channel(2)) > 0.8)
        #expect(mean(px.channel(0)) < 0.2)
    }

    @Test func thumbnailBatchStopsWhenCancelled() throws {
        let e = try engine()
        e.setSource(stripes())
        nonisolated(unsafe) var count = 0
        let lock = NSLock()
        e.renderThumbnails(ids: Array(repeating: nil, count: 20), crop: .identity, longSide: 64, workers: 1,
                           isCancelled: { lock.lock(); defer { lock.unlock() }; return count >= 2 }) { _, _ in
            lock.lock(); count += 1; lock.unlock()
        }
        #expect(count == 2)
    }
}
