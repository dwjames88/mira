import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

enum SweepSupport {
    /// Counts of non-finite values and of 16x16 tiles that are black here but not in `reference`.
    static func audit(_ p: LinearPixels, reference: LinearPixels?) -> (nonFinite: Int, blackTiles: Int) {
        var bad = 0
        for v in p.rgba where !v.isFinite { bad += 1 }
        guard let reference, reference.width == p.width, reference.height == p.height else { return (bad, 0) }
        var tiles = 0
        let t = 16
        for ty in stride(from: 0, to: p.height - t + 1, by: t) {
            for tx in stride(from: 0, to: p.width - t + 1, by: t) {
                var maxHere: Float = 0, maxRef: Float = 0
                for y in ty..<(ty + t) { for x in tx..<(tx + t) {
                    let i = (y * p.width + x) * 4
                    maxHere = max(maxHere, p.rgba[i].isFinite ? max(p.rgba[i], p.rgba[i + 1], p.rgba[i + 2]) : 0)
                    maxRef = max(maxRef, reference.rgba[i], reference.rgba[i + 1], reference.rgba[i + 2])
                } }
                if maxHere < 0.002, maxRef > 0.02 { tiles += 1 }
            }
        }
        return (bad, tiles)
    }
}

@Suite(.serialized) struct NonFiniteTests {
    static func render(width: Int, height: Int, recipe: Recipe, headroom: CGFloat = 1) throws -> LinearPixels {
        let img = PipelineFixture.linearImage(width: width, height: height) { x, y in
            if x == 300 % width, y == 300 % height { return (.nan, .nan, .nan) }
            if x == 700 % width, y == 600 % height { return (.infinity, .infinity, .infinity) }
            return (0.8, 0.8, 0.8)
        }
        let renderer = Renderer(library: try emptyLibrary())
        return LinearPixels(renderer.apply(recipe, to: img, sourceHeadroom: headroom))
    }

    /// Every 16x16 tile of `p` that holds a non-finite or (near) black pixel only.
    static func darkOrBadTiles(_ p: LinearPixels) -> Int {
        var n = 0
        for ty in stride(from: 0, to: p.height - 15, by: 16) {
            for tx in stride(from: 0, to: p.width - 15, by: 16) {
                var peak: Float = 0
                var finite = true
                for y in ty..<(ty + 16) { for x in tx..<(tx + 16) {
                    let v = p.rgba[(y * p.width + x) * 4 + 1]
                    if v.isFinite { peak = max(peak, v) } else { finite = false }
                } }
                if !finite || peak < 0.01 { n += 1 }
            }
        }
        return n
    }

    /// One NaN and one inf pixel in a bright sky: with highlights set they must stay a pixel, not become a block.
    /// (Measured before the fix on the Mac: the pixel itself stayed NaN, the blur did not spread it, so this
    /// guards the device, where Metal's arithmetic differs.)
    @Test(arguments: [(1000, 1000), (240, 240), (600, 400)])
    func injectedNonFinitePixelsDoNotBlowUpIntoBlocks(size: (Int, Int)) throws {
        for (hl, sh) in [(0.46, 0.0), (-0.6, 0.0), (0.0, 0.5), (0.46, -0.4)] {
            var r = Recipe(); r.highlights = hl; r.shadows = sh; r.texture = 0.4; r.clarity = 0.4
            let p = try Self.render(width: size.0, height: size.1, recipe: r)
            let bad = p.rgba.filter { !$0.isFinite }.count
            #expect(bad == 0, "\(size) hl \(hl) sh \(sh): \(bad) non-finite values")
            #expect(Self.darkOrBadTiles(p) == 0, "\(size) hl \(hl) sh \(sh): dark tiles")
        }
    }

    /// The kernels alone, fed a non-finite blurred base (what a blur of a bad pixel produces) and a non-finite pixel.
    @Test func toneAndDetailKernelsSurviveNonFiniteInput() throws {
        let w = 64, h = 64
        let image = PipelineFixture.linearImage(width: w, height: h) { x, y in
            if x == 10, y == 10 { return (.nan, 0.5, 0.5) }
            if x == 20, y == 20 { return (.infinity, .infinity, .infinity) }
            return (0.8, 0.7, 0.6)
        }
        let base = PipelineFixture.linearImage(width: w, height: h) { x, y in
            (x >= 16 && x < 48 && y >= 16 && y < 48) ? (.nan, .nan, .nan) : (.infinity, 0.8, 0.8)
        }
        let tone = LinearPixels(GradeKernels.applyTone(highlights: 0.46, shadows: 0.3, whites: 0.2, blacks: -0.2, to: image, base: base))
        let detail = LinearPixels(GradeKernels.applyDetail(amount: 1, midtoneWeighted: true, to: image, blurred: base))
        for (name, p) in [("tone", tone), ("detail", detail)] {
            #expect(p.rgba.filter { !$0.isFinite }.isEmpty, "\(name) output has non-finite values")
            // The finite pixels inside the bad-base block keep their colour (fall back to the pixel itself).
            let mid = p.rgba[(32 * w + 32) * 4]
            #expect(mid > 0.5 && mid < 1.2, "\(name) centre \(mid)")
        }
    }

    /// The sanitiser: NaN -> 0, +inf -> headroom, finite (including > 1) untouched.
    @Test func sanitizeKeepsFiniteValuesAndReplacesTheRest() throws {
        let image = PipelineFixture.linearImage(width: 4, height: 1) { x, _ in
            switch x {
            case 0: (.nan, .nan, .nan)
            case 1: (.infinity, -.infinity, 1.7)
            case 2: (1.6, -0.2, 0.001)
            default: (0, 0.5, 1)
            }
        }
        let p = LinearPixels(GradeKernels.applySanitize(limit: 1.7, to: image))
        #expect(p.value(0, 0, 0) == 0 && p.value(0, 0, 1) == 0)
        #expect(abs(p.value(1, 0, 0) - 1.7) < 1e-3 && p.value(1, 0, 1) == 0 && abs(p.value(1, 0, 2) - 1.7) < 1e-3)
        #expect(abs(p.value(2, 0, 0) - 1.6) < 1e-3 && abs(p.value(2, 0, 1) + 0.2) < 1e-3)
    }

    /// The live-preview proxy keeps the source's range: graded with a film, a proxy of an HDR source matches the
    /// source graded at the same size (an 8-bit proxy with the headroom tag kept dimmed the highlights).
    @Test func proxyKeepsSceneRangeAndMatchesTheExport() throws {
        let headroom: CGFloat = 1.7
        let w = 800, h = 400
        let source = PipelineFixture.linearImage(width: w, height: h) { x, y in
            let v = 1.7 * Float(x) / Float(w - 1)
            return (v, v * 0.9, v * 0.8 + 0.02 * Float(y % 3))
        }.withMiraHeadroom(headroom)
        let library = try SyntheticFilms.library([.init(id: "neg", family: .colorNegative)])
        let renderer = Renderer(library: library)
        var recipe = Recipe(); recipe.filmID = "neg"; recipe.highlights = 0.3
        let context = Renderer.makeContext()

        let proxy = PreviewProxy.make(from: source, renderer: renderer, context: context, wanted: 400)
        #expect(proxy.extent.width == 400 && proxy.miraHeadroom == headroom)
        // Scene values above 1 survive the proxy.
        let raw = LinearPixels(proxy, context: context)
        #expect(raw.value(399, 100, 0) > 1.5, "proxy clipped: \(raw.value(399, 100, 0))")

        let viaProxy = LinearPixels(renderer.withPreviewScale(0.5).apply(recipe, to: proxy), context: context)
        let exported = renderer.withPreviewScale(0.5).apply(recipe, to: source)
        let downsized = LinearPixels(renderer.previewImage(from: exported, maxPixelSize: 400), context: context)
        #expect(viaProxy.width == downsized.width && viaProxy.height == downsized.height)
        var worst = 0.0
        for y in stride(from: 4, to: viaProxy.height - 4, by: 7) { for x in stride(from: 4, to: viaProxy.width - 4, by: 5) {
            worst = max(worst, abs(viaProxy.luma(x, y) - downsized.luma(x, y)))
        } }
        #expect(worst < 0.03, "preview vs export differ by \(worst)")
    }
}

@Suite(.serialized) struct DevelopSweepTests {
    static let urls = [RawSamples.iphoneXS, RawSamples.iphone12Pro, RawSamples.sony].compactMap { $0 }

    @Test(arguments: urls)
    func everySliderStaysFiniteAndNeverBlacksOutATile(url: URL) throws {
        let develop = try #require(RawDevelop(url: url))
        let library = try SyntheticFilms.library([.init(id: "neg", family: .colorNegative)])
        let renderer = Renderer(library: library)
        let scale: Float = 0.12
        var failures: [String] = []
        var cases = 0

        func render(_ raw: RawSettings, _ recipe: Recipe, film: Bool) throws -> LinearPixels {
            let d = try #require(develop.develop(raw, filmApplied: film, draft: true, scale: scale))
            let out = renderer.apply(recipe, to: d.image)
            return LinearPixels(out, context: RawSamples.context)
        }

        for film in [false, true] {
            var base = Recipe(); if film { base.filmID = "neg" }
            let reference = try render(.identity, base, film: film)
            func check(_ label: String, _ raw: RawSettings, _ recipe: Recipe, tiles: Bool = true) throws {
                cases += 1
                let r = try render(raw, recipe, film: film)
                let a = SweepSupport.audit(r, reference: raw.isIdentity && tiles ? reference : nil)
                if a.nonFinite > 0 || a.blackTiles > 0 { failures.append("\(label) film=\(film): nonFinite \(a.nonFinite), black tiles \(a.blackTiles)") }
            }
            let sliders: [(String, WritableKeyPath<Recipe, Double>)] = [
                ("exposure", \.exposure), ("contrast", \.contrast), ("highlights", \.highlights),
                ("shadows", \.shadows), ("whites", \.whites), ("blacks", \.blacks), ("texture", \.texture),
                ("clarity", \.clarity), ("saturation", \.saturation), ("vibrance", \.vibrance),
                ("warmth", \.warmth), ("tint", \.tint),
            ]
            for (name, path) in sliders {
                for v in [-1.0, 0.46, 1.0] {
                    var r = base; r[keyPath: path] = v
                    try check("\(name)=\(v)", .identity, r, tiles: !["contrast", "blacks", "exposure"].contains(name))
                }
            }
            var all = base
            all.highlights = 1; all.shadows = 1; all.whites = 1; all.blacks = -1; all.texture = 1; all.clarity = 1
            all.saturation = 1; all.vibrance = 1; all.exposure = 2
            try check("everything +", .identity, all, tiles: false)
            all.highlights = -1; all.shadows = -1; all.whites = -1; all.blacks = 1; all.exposure = -2
            try check("everything -", .identity, all, tiles: false)

            var hl = base; hl.highlights = 0.46
            let raws: [(String, RawSettings)] = [
                ("temp 2000", RawSettings(temperature: 2000)), ("temp 50000", RawSettings(temperature: 50000)),
                ("tint -150", RawSettings(temperature: 6500, tint: -150)), ("tint 150", RawSettings(temperature: 6500, tint: 150)),
                ("boost 0", RawSettings(boostAmount: 0)), ("boost 1", RawSettings(boostAmount: 1)),
                ("local tone 0", RawSettings(localToneMapAmount: 0)), ("local tone 1", RawSettings(localToneMapAmount: 1)),
                ("edr 0", RawSettings(extendedDynamicRangeAmount: 0)), ("edr 1", RawSettings(extendedDynamicRangeAmount: 1)),
                ("edr 2", RawSettings(extendedDynamicRangeAmount: 2)),
                ("shadow bias -1", RawSettings(shadowBias: -1)), ("shadow bias 1", RawSettings(shadowBias: 1)),
                ("NR 1", RawSettings(luminanceNoiseReductionAmount: 1, colorNoiseReductionAmount: 1)),
                ("sharp 1 detail 3", RawSettings(sharpnessAmount: 1, detailAmount: 3, moireReductionAmount: 1)),
                ("no lens corr", RawSettings(lensCorrection: false)),
            ]
            for (name, raw) in raws { try check("raw \(name) + highlights 0.46", raw, hl) }
        }
        print("SWEEP \(url.lastPathComponent): \(cases) cases, \(failures.count) failures")
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }
}
