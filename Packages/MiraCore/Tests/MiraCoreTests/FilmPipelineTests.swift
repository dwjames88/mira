import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

/// Float RGBA pixels of a render in extended linear sRGB (no 8-bit quantisation, no clipping).
struct LinearPixels {
    let width: Int, height: Int
    let rgba: [Float]

    init(_ image: CIImage, context: CIContext = Renderer.sharedContext) {
        let r = image.extent
        width = Int(r.width); height = Int(r.height)
        var buf = [Float](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &buf, rowBytes: width * 16, bounds: r, format: .RGBAf,
                       colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        rgba = buf
    }

    func value(_ x: Int, _ y: Int, _ c: Int) -> Double { Double(rgba[(y * width + x) * 4 + c]) }
    func luma(_ x: Int, _ y: Int) -> Double {
        0.2126 * value(x, y, 0) + 0.7152 * value(x, y, 1) + 0.0722 * value(x, y, 2)
    }
}

enum PipelineFixture {
    static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// A linear-light float image from a per-pixel function.
    static func linearImage(width: Int, height: Int, _ f: (Int, Int) -> (Float, Float, Float)) -> CIImage {
        var buf = [Float](repeating: 1, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let (r, g, b) = f(x, y)
            let i = (y * width + x) * 4
            buf[i] = r; buf[i + 1] = g; buf[i + 2] = b
        } }
        let data = buf.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: width * 16, size: CGSize(width: width, height: height),
                       format: .RGBAf, colorSpace: linear)
    }

    static func flat(_ gray: CGFloat, width: Int, height: Int) -> CIImage {
        let c = CIColor(red: gray, green: gray, blue: gray, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        return CIImage(color: c).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// Left half `a`, right half `b` (sRGB-encoded grays).
    static func halves(_ a: CGFloat, _ b: CGFloat, size: Int) -> CIImage {
        let half = size / 2
        let right = flat(b, width: size - half, height: size).transformed(by: CGAffineTransform(translationX: CGFloat(half), y: 0))
        return flat(a, width: half, height: size).composited(over: right)
    }

    static func rect(_ p: Pixels, x: Range<Int>, y: Range<Int>, channel: Int = 1) -> [Double] {
        var out: [Double] = []
        for yy in y { for xx in x { out.append(Double(p.rgba[(yy * p.width + xx) * 4 + channel]) / 255) } }
        return out
    }
}

@Suite struct FilmPipelineTests {
    let context = Renderer.sharedContext

    static func library() throws -> FilmLibrary {
        try SyntheticFilms.library([
            .init(id: "neg", family: .colorNegative),
            .init(id: "slide", family: .slide),
            .init(id: "bw", family: .blackAndWhite),
            .init(id: "negSquare", family: .colorNegative, cube: .square),
        ])
    }

    // MARK: Grain

    @Test func grainIsResolutionIndependent() throws {
        let r = Renderer(library: try emptyLibrary())
        let recipe = Recipe(grainAmount: 0.5)
        let big = r.apply(recipe, to: PipelineFixture.flat(0.45, width: 4000, height: 3000))
        let direct = Pixels(r.apply(recipe, to: PipelineFixture.flat(0.45, width: 1000, height: 750)), context: context)
        let down = Pixels(r.previewImage(from: big, maxPixelSize: 1000), context: context)
        #expect(down.width == 1000 && down.height == 750)
        let sDirect = stddev(direct.channel(1)), sDown = stddev(down.channel(1))
        #expect(sDirect > 0.002, "grain should be visible (\(sDirect))")
        let ratio = sDown / sDirect
        #expect(ratio > 0.75 && ratio < 1.33, "downscaled \(sDown) vs direct \(sDirect) ratio \(ratio)")
        #expect(abs(mean(down.channel(1)) - mean(direct.channel(1))) < 0.01)
        #expect(abs(mean(down.channel(1)) - 0.45) < 0.01)
    }

    /// Std of (image - 2 px Gaussian blur of it), green channel, away from the edges: the grain's high-frequency energy.
    private func highPassStd(_ image: CIImage) -> Double {
        let e = image.extent
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: 2).cropped(to: e)
        let diff = image.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: blurred])
        let p = Pixels(diff.cropped(to: e.insetBy(dx: 20, dy: 20)), context: context)
        return stddev(p.channel(1))
    }

    @Test func previewGrainIsVisibleAndMatchesDownsampledFullRes() throws {
        let r = Renderer(library: try emptyLibrary())
        let full = PipelineFixture.flat(0.45, width: 4000, height: 3000)
        for amount in [0.5, 1.0] {
            let recipe = Recipe(grainAmount: amount)
            let down = r.previewImage(from: r.apply(recipe, to: full), maxPixelSize: 1000)
            let reference = highPassStd(down)
            let small = r.previewImage(from: full, maxPixelSize: 1000)
            let preview = highPassStd(r.withPreviewScale(0.25).apply(recipe, to: small))
            let none = highPassStd(r.withPreviewScale(0.25).apply(Recipe(grainAmount: 0), to: small))
            #expect(preview / max(none, 1e-6) > 1.3, "amount \(amount): preview \(preview) vs none \(none)")
            #expect(preview > 0.65 * reference && preview < 1.35 * reference,
                    "amount \(amount): preview \(preview) vs downsampled full-res \(reference)")
        }
    }

    @Test func previewScaleOneEqualsExport() throws {
        let r = Renderer(library: try emptyLibrary())
        let input = PipelineFixture.flat(0.45, width: 600, height: 400)
        let recipe = Recipe(grainAmount: 0.7)
        let a = Pixels(r.apply(recipe, to: input), context: context)
        let b = Pixels(r.withPreviewScale(1).apply(recipe, to: input), context: context)
        #expect(a.rgba == b.rgba)
    }

    @Test func grainIsDeterministicAndZeroMean() throws {
        let r = Renderer(library: try emptyLibrary())
        let recipe = Recipe(grainAmount: 0.6)
        let input = PipelineFixture.flat(0.45, width: 1000, height: 1000)
        let a = Pixels(r.apply(recipe, to: input), context: context)
        let b = Pixels(r.apply(recipe, to: input), context: Renderer.makeContext())
        #expect(a.rgba == b.rgba)
        let flat = Pixels(input, context: context)
        for c in 0..<3 { #expect(abs(mean(a.channel(c)) - mean(flat.channel(c))) < 0.005) }
        #expect(stddev(a.channel(1)) > 0.002)
    }

    @Test func grainDependsOnDensity() throws {
        let r = Renderer(library: try Self.library())
        let grain = 0.8
        func stds(_ film: String, _ lo: CGFloat, _ hi: CGFloat) -> (Double, Double) {
            let out = Pixels(r.apply(Recipe(filmID: film, grainAmount: grain), to: PipelineFixture.halves(lo, hi, size: 1000)), context: context)
            return (stddev(PipelineFixture.rect(out, x: 100..<400, y: 100..<900)),
                    stddev(PipelineFixture.rect(out, x: 600..<900, y: 100..<900)))
        }
        let neg = stds("neg", 0.4, 0.9)
        #expect(neg.0 > neg.1 * 1.5, "negative: shadows/mids \(neg.0) vs highlights \(neg.1)")
        let slide = stds("slide", 0.15, 0.65)
        #expect(slide.1 > slide.0 * 1.5, "slide: light mids \(slide.1) vs shadows \(slide.0)")
    }

    @Test func monochromeGrainIsNeutralAndColourGrainIsNot() throws {
        let r = Renderer(library: try Self.library())
        let input = PipelineFixture.flat(0.45, width: 800, height: 800)
        let bw = Pixels(r.apply(Recipe(filmID: "bw", grainAmount: 0.8), to: input), context: context)
        let (br, bg, bb) = (bw.channel(0), bw.channel(1), bw.channel(2))
        let maxDiff = (0..<br.count).map { max(abs(br[$0] - bg[$0]), abs(bg[$0] - bb[$0])) }.max() ?? 1
        #expect(maxDiff < 0.005, "B&W channels differ by \(maxDiff)")
        #expect(stddev(bg) > 0.002)
        let neg = Pixels(r.apply(Recipe(filmID: "neg", grainAmount: 0.8), to: input), context: context)
        let (nr, ng) = (neg.channel(0), neg.channel(1))
        let diff = mean((0..<nr.count).map { abs(nr[$0] - ng[$0]) })
        #expect(diff > 0.002, "colour negative grain should differ per channel (\(diff))")
    }

    // MARK: Halation

    @Test func halationRedistributesLuminanceAndTintsTheHalo() throws {
        let lib = try Self.library()
        let r = Renderer(library: lib)
        let n = 256
        let disc = PipelineFixture.linearImage(width: n, height: n) { x, y in
            let d = hypot(Double(x) - 127.5, Double(y) - 127.5)
            return d < 20 ? (2, 2, 2) : (0.02, 0.02, 0.02)
        }
        var coreLuma = 0.0, discCount = 0.0
        for y in 0..<n { for x in 0..<n where hypot(Double(x) - 127.5, Double(y) - 127.5) < 20 { discCount += 1 } }
        coreLuma = 2   // the highlight part of a luma 2.0 pixel is itself (smoothstep is 1 above 1.0)
        for (film, tinted) in [("neg", true), ("bw", false)] {
            let character = try #require(lib.film(id: film)?.resolvedCharacter)
            let a = min(0.5 * 2 * character.halationStrength * 0.5, 0.9)
            let c = Double(GradeKernels.halationCompensation)
            // Strength 0 skips the LUT (which would clip the 2.0 highlights), leaving only the halation.
            let before = LinearPixels(r.apply(Recipe(filmID: film, strength: 0, halationAmount: 0), to: disc))
            let after = LinearPixels(r.apply(Recipe(filmID: film, strength: 0, halationAmount: 0.5), to: disc))
            var mb = 0.0, ma = 0.0
            for y in 0..<n { for x in 0..<n { mb += before.luma(x, y); ma += after.luma(x, y) } }
            // Only the share `c` of the scattered light is removed, all of it comes back: net gain a (1 - c) sum(h).
            let bound = a * (1 - c) * coreLuma * discCount
            #expect(ma - mb <= bound * 1.02, "\(film): luminance \(mb) -> \(ma), bound +\(bound)")
            #expect(ma - mb >= -1e-3 * mb, "\(film): luminance \(mb) -> \(ma)")
            // The core stays on the shoulder: it keeps at least 95% of its luminance.
            #expect(after.luma(127, 127) >= 0.95 * before.luma(127, 127),
                    "\(film): core \(before.luma(127, 127)) -> \(after.luma(127, 127))")
            var dr = 0.0, db = 0.0, count = 0.0
            for y in 0..<n { for x in 0..<n {
                let d = hypot(Double(x) - 127.5, Double(y) - 127.5)
                guard d > 22, d < 32 else { continue }
                dr += after.value(x, y, 0) - before.value(x, y, 0)
                db += after.value(x, y, 2) - before.value(x, y, 2)
                count += 1
            } }
            dr /= count; db /= count
            #expect(dr > 0.001, "\(film): halo should brighten (\(dr))")
            if tinted { #expect(dr > db * 2, "negative halo should be red: r +\(dr) b +\(db)") }
            else { #expect(abs(dr - db) < 1e-4, "B&W halo should be neutral: r +\(dr) b +\(db)") }
        }
    }

    // MARK: Latitude

    @Test func latitudeMatchesKernelAndRollsOff() throws {
        let r = Renderer(library: try Self.library())
        let ramp = PipelineFixture.linearImage(width: 256, height: 1) { x, _ in
            let v = Float(x) / 255
            return (v, v, v)
        }
        let ev = 1.5, g = exp2(ev)
        func render(_ film: String) -> [Double] {
            let out = LinearPixels(r.apply(Recipe(filmID: film, exposure: ev), to: ramp))
            return (0..<256).map { out.value($0, 0, 1) }
        }
        let neg = render("neg")
        let negLatitude = try #require(Renderer(library: try Self.library()).library.film(id: "neg")?.resolvedCharacter.latitude)
        for x in stride(from: 0, to: 256, by: 5) {
            let expected = min(1, FilmMath.exposure(Double(x) / 255, gain: g, latitude: negLatitude))
            #expect(abs(neg[x] - expected) < 0.01, "x=\(x): kernel \(neg[x]) vs \(expected)")
        }
        #expect(neg[255] <= 1.001)
        for i in 1..<256 { #expect(neg[i] >= neg[i - 1] - 1e-3) }
        let slide = render("slide")
        let clippedNeg = neg.filter { $0 >= 0.999 }.count
        let clippedSlide = slide.filter { $0 >= 0.999 }.count
        #expect(clippedSlide > clippedNeg + 20, "slide clips \(clippedSlide), negative \(clippedNeg)")
    }

    @Test func filmMathProperties() {
        #expect(FilmMath.exposure(0.7, gain: 1, latitude: 1) == 0.7)
        #expect(abs(FilmMath.exposure(1, gain: 3, latitude: 1) - 1) < 1e-12)
        #expect(FilmMath.exposure(0.5, gain: 0.5, latitude: 1) == 0.25)
        #expect(FilmMath.exposure(-0.2, gain: 2, latitude: 1) == -0.4)
        #expect(FilmMath.exposure(0.5, gain: 2, latitude: 0) == 1)
    }

    // MARK: White balance order

    @Test func whiteBalanceRunsBeforeFilmInPipeline2AndAfterInPipeline1() throws {
        let r = Renderer(library: try Self.library())
        let input = Fixture.gradientAndPatches(size: 256)
        func px(_ recipe: Recipe, _ image: CIImage = input) -> Pixels { Pixels(r.apply(recipe, to: image), context: context) }
        func meanAbsDiff(_ a: Pixels, _ b: Pixels) -> Double {
            var d = 0.0
            for i in 0..<a.rgba.count where i % 4 != 3 { d += abs(Double(a.rgba[i]) - Double(b.rgba[i])) / 255 }
            return d / Double(a.count * 3)
        }
        let L = Recipe.legacyPipeline
        let p1 = px(Recipe(filmID: "negSquare", warmth: 0.8, pipeline: L))
        let p2 = px(Recipe(filmID: "negSquare", warmth: 0.8))
        #expect(meanAbsDiff(p1, p2) > 0.01, "the two orders must differ")

        // Pipeline 1: film, then white balance. Pipeline 2: white balance, then film.
        let filmOnly = r.apply(Recipe(filmID: "negSquare", pipeline: L), to: input)
        let wbOnly = r.apply(Recipe(warmth: 0.8, pipeline: L), to: input)
        let filmThenWB = r.apply(Recipe(warmth: 0.8, pipeline: L), to: filmOnly)
        let wbThenFilm = r.apply(Recipe(filmID: "negSquare", pipeline: L), to: wbOnly)
        #expect(meanAbsDiff(p1, Pixels(filmThenWB, context: context)) < 0.01)
        #expect(meanAbsDiff(p2, Pixels(wbThenFilm, context: context)) < 0.01)

        // Pipeline 1 still matches the captured legacy checksum.
        let legacy = try #require(LegacyPipelineTests.cases.first { $0.name == "warmth over a non-linear LUT" })
        let lib = try SyntheticFilms.library([.init(id: "square", family: .colorNegative, cube: .square)])
        let hash = LegacyPipelineTests.fnv(LegacyPipelineTests.render(legacy.recipe, renderer: Renderer(library: lib)).rgba)
        #expect(hash == legacy.hash)
    }

    // MARK: Versioning

    @Test func pipelineVersioning() throws {
        let old = try Recipe.decode(Data(#"{"exposure":0.5,"grainAmount":0.3}"#.utf8))
        #expect(old.pipeline == Recipe.legacyPipeline)
        #expect(MiraAdjustment.formatVersion(for: old) == "1")

        let current = Recipe(exposure: 0.5)
        #expect(current.pipeline == 2)
        #expect(try Recipe.decode(current.encoded()).pipeline == 2)
        #expect(MiraAdjustment.formatVersion(for: current) == "4")
        #expect(MiraAdjustment.formatVersion(for: Recipe(highlights: 0.2)) == "4")

        let legacyTone = Recipe(highlights: 0.2, pipeline: Recipe.legacyPipeline)
        #expect(MiraAdjustment.formatVersion(for: legacyTone) == "2")
        #expect(MiraAdjustment.formatVersion(for: Recipe(pipeline: Recipe.legacyPipeline)) == "1")
        #expect(MiraAdjustment.supportedVersions.contains("4"))
        #expect(MiraAdjustment.filmScienceFormatVersion == "4")
    }

    @Test func presetsFromBeforePipelinesStillImport() throws {
        let legacy = Preset(nickname: "Old", recipe: Recipe(filmID: "kodak-portra-400", grainAmount: 0.3, pipeline: Recipe.legacyPipeline),
                            filmName: "Portra 400")
        let data = try PresetFile.encode(legacy, appVersion: "0.4.0")
        #expect(!String(decoding: data, as: UTF8.self).contains("\"pipeline\""))
        let back = try PresetFile.decode(data)
        #expect(back.recipe.pipeline == Recipe.legacyPipeline)
        #expect(back.recipe.grainAmount == 0.3)

        let new = Preset(nickname: "New", recipe: Recipe(filmID: "kodak-portra-400"), filmName: "Portra 400")
        #expect(try PresetFile.decode(PresetFile.encode(new, appVersion: "1.0.0")).recipe.pipeline == 2)
    }
}
