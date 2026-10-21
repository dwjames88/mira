import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import EmulsionCore

@Suite struct RendererTests {
    let context = Renderer.makeContext()

    @Test func neutralReturnsInputUnchanged() throws {
        let r = Renderer(library: try emptyLibrary())
        let input = Fixture.gradientAndPatches(size: 128)
        let out = r.apply(.neutral, to: input)
        #expect(out.extent == input.extent)
        #expect(Pixels(out, context: context).rgba == Pixels(input, context: context).rgba)
    }

    @Test func determinism() throws {
        let r = Renderer(library: try emptyLibrary())
        let input = Fixture.gradientAndPatches(size: 256)
        let recipe = Recipe(exposure: 0.3, contrast: 0.2, saturation: 0.1, warmth: 0.3, tint: -0.2,
                            grainAmount: 0.5, halationAmount: 0.5, bloomAmount: 0.3, vignetteAmount: 0.4)
        let a = Pixels(r.apply(recipe, to: input), context: context).rgba
        let b = Pixels(r.apply(recipe, to: input), context: Renderer.makeContext()).rgba
        #expect(a == b)
        #expect(a != Pixels(input, context: context).rgba)
    }

    @Test func extentsPreservedExceptBorder() throws {
        let r = Renderer(library: try emptyLibrary())
        let input = Fixture.gradientAndPatches(size: 200)
        let all = Recipe(exposure: 0.2, contrast: 0.2, grainAmount: 0.5, halationAmount: 1, bloomAmount: 1, vignetteAmount: 1)
        #expect(r.apply(all, to: input).extent == input.extent)
        var bordered = Recipe.neutral
        bordered.borderEnabled = true
        let out = r.apply(bordered, to: input)
        #expect(out.extent == input.extent.insetBy(dx: -8, dy: -8))
    }

    @Test func warmthAndTintDirections() throws {
        let r = Renderer(library: try emptyLibrary())
        let input = Fixture.solid(gray: 0.5, size: 32)
        let warm = Pixels(r.apply(Recipe(warmth: 0.8), to: input), context: context)
        #expect(mean(warm.channel(0)) > mean(warm.channel(2)) + 0.02)
        let cool = Pixels(r.apply(Recipe(warmth: -0.8), to: input), context: context)
        #expect(mean(cool.channel(2)) > mean(cool.channel(0)) + 0.02)
        let magenta = Pixels(r.apply(Recipe(tint: 0.8), to: input), context: context)
        #expect(mean(magenta.channel(1)) < (mean(magenta.channel(0)) + mean(magenta.channel(2))) / 2 - 0.01, "g \(mean(magenta.channel(1))) r \(mean(magenta.channel(0))) b \(mean(magenta.channel(2)))")
    }

    @Test func grainIsResolutionIndependent() throws {
        let r = Renderer(library: try emptyLibrary())
        let recipe = Recipe(grainAmount: 0.6)
        let small = Pixels(r.apply(recipe, to: Fixture.solid(gray: 0.5, size: 1000)), context: context)
        let bigImage = r.apply(recipe, to: Fixture.solid(gray: 0.5, size: 2000))
        let big = Pixels(bigImage, context: context)
        let down = Pixels(r.previewImage(from: bigImage, maxPixelSize: 1000), context: context)

        let flat = Pixels(Fixture.solid(gray: 0.5, size: 1000), context: context)
        #expect(stddev(flat.luma) < 1e-3)

        let sSmall = stddev(small.luma), sBig = stddev(big.luma), sDown = stddev(down.luma)
        #expect(sSmall > 0.01, "grain should be visible, std \(sSmall)")
        #expect(abs(sBig - sSmall) / sSmall < 0.25, "native std \(sBig) vs \(sSmall)")
        #expect(abs(sDown - sSmall) / sSmall < 0.25, "downscaled std \(sDown) vs \(sSmall)")
        #expect(abs(mean(small.luma) - mean(flat.luma)) < 0.02, "mean \(mean(small.luma)) vs \(mean(flat.luma))")
        #expect(abs(mean(big.luma) - mean(flat.luma)) < 0.02)
    }

    @Test func exportOrientationAndSize() throws {
        let r = Renderer(library: try emptyLibrary())
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("emulsion-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // 120x80 image tagged orientation 6 (rotate 90 CW) -> upright output is 80x120.
        let src = dir.appendingPathComponent("in.jpg")
        let cg = context.createCGImage(Fixture.gradientAndPatches(size: 120).cropped(to: CGRect(x: 0, y: 0, width: 120, height: 80)),
                                       from: CGRect(x: 0, y: 0, width: 120, height: 80))!
        let d = CGImageDestinationCreateWithURL(src as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(d))

        for (type, ext) in [(UTType.jpeg, "jpg"), (UTType.tiff, "tiff"), (UTType.heic, "heic")] {
            let out = dir.appendingPathComponent("out.\(ext)")
            try r.export(Recipe(exposure: 0.2, grainAmount: 0.2), inputURL: src, outputURL: out, type: type, quality: 0.9)
            let s = CGImageSourceCreateWithURL(out as CFURL, nil)!
            let p = CGImageSourceCopyPropertiesAtIndex(s, 0, nil) as! [CFString: Any]
            #expect(p[kCGImagePropertyPixelWidth] as? Int == 80, "\(ext)")
            #expect(p[kCGImagePropertyPixelHeight] as? Int == 120, "\(ext)")
            #expect((p[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "\(ext)")
        }
    }
}
