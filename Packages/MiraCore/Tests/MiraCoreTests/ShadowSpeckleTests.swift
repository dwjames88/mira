import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

enum ShadowSpeckle {
    static let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    /// A deep-shadow wide-gamut test card: dark rock-like content in Display P3: saturated near-black reds, greens, oranges, browns with per-pixel noise.
    static func darkP3(size: Int, seed: UInt64 = 7) -> CIImage {
        var rng = seed
        func rnd() -> Double { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Double((rng >> 33) & 0xFFFFFF) / Double(0x1000000) }
        let tiles: [(Double, Double, Double)] = [
            (0.16, 0.0, 0.0), (0.0, 0.14, 0.0), (0.2, 0.06, 0.0), (0.14, 0.07, 0.04), (0.0, 0.1, 0.12), (0.1, 0.0, 0.16),
            (0.12, 0.05, 0.03), (0.08, 0.08, 0.0), (0.05, 0.03, 0.02), (0.22, 0.02, 0.02), (0.0, 0.0, 0.0), (0.03, 0.0, 0.01),
        ]
        var px = [UInt16](repeating: 0xFFFF, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let t = tiles[((y / 32) * 4 + x / 32) % tiles.count]
            let n = (rnd() - 0.5) * 0.04
            let i = (y * size + x) * 4
            func q(_ v: Double) -> UInt16 { UInt16(max(0, min(1, v + n * (0.5 + rnd()))) * 65535) }
            px[i] = q(t.0); px[i + 1] = q(t.1); px[i + 2] = q(t.2)
        } }
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) }
        return CIImage(bitmapData: data, bytesPerRow: size * 8, size: CGSize(width: size, height: size), format: .RGBA16, colorSpace: p3)
    }

    struct Stats { var outliers = 0, nonFinite = 0, worstChroma: Float = 0, worstAt = (0, 0), worstPix = (0, 0, 0) as (Float, Float, Float) }

    static func measure(_ image: CIImage, context: CIContext, chroma: Float = 0.25, dark: Float = 0.05) -> Stats {
        let r = image.extent
        let w = Int(r.width), h = Int(r.height)
        var f = [Float](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &f, rowBytes: w * 16, bounds: r, format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        var s = Stats()
        for v in f where !v.isFinite { s.nonFinite += 1 }
        var u = [UInt8](repeating: 0, count: w * h * 4)
        context.render(image, toBitmap: &u, rowBytes: w * 4, bounds: r, format: .RGBA8, colorSpace: srgb)
        func lum(_ x: Int, _ y: Int) -> Float {
            let i = (y * w + x) * 4
            return (0.2126 * Float(u[i]) + 0.7152 * Float(u[i + 1]) + 0.0722 * Float(u[i + 2])) / 255
        }
        for y in 2..<(h - 2) { for x in 2..<(w - 2) {
            var m: Float = 0
            for dy in -2...2 { for dx in -2...2 { m += lum(x + dx, y + dy) } }
            m /= 25
            let i = (y * w + x) * 4
            let c = (Float(max(u[i], u[i + 1], u[i + 2])) - Float(min(u[i], u[i + 1], u[i + 2]))) / 255
            if m < dark && c > chroma {
                s.outliers += 1
                if c > s.worstChroma { s.worstChroma = c; s.worstAt = (x, y); s.worstPix = (Float(u[i]), Float(u[i + 1]), Float(u[i + 2])) }
            }
        } }
        return s
    }
}

extension ShadowSpeckle {
    /// Near-black linear light with independent per-channel chroma noise, some channels negative (what a dark
    /// saturated Display P3 colour, or sensor chroma noise, looks like in extended linear sRGB).
    static func chromaNoise(size: Int) -> CIImage {
        var rng: UInt64 = 5
        func rnd() -> Float { rng = rng &* 6364136223846793005 &+ 1442695040888963407; return Float((rng >> 33) & 0xFFFFFF) / Float(0x1000000) }
        return PipelineFixture.linearImage(width: size, height: size) { _, _ in
            (0.004 * rnd() - 0.0005, 0.003 * rnd() - 0.0010, 0.003 * rnd() - 0.0015)
        }
    }

    static var controls: [(String, (inout Recipe) -> Void)] { [
        ("lift", { $0.shadows = 1; $0.blacks = 1; $0.whites = 1; $0.highlights = -1 }),
        ("detail+", { $0.texture = 1; $0.clarity = 1; $0.exposure = 1; $0.warmth = 1 }),
        ("curves", { var c = CurvesSettings(); c.luminance = [CurvePoint(x: 0, y: 0.2), CurvePoint(x: 0.5, y: 0.7), CurvePoint(x: 1, y: 1)]
                     $0.curves = c; $0.shadows = 0.5; $0.warmth = -1 }),
        ("crush", { $0.shadows = -1; $0.blacks = -1; $0.whites = -1; $0.texture = -1; $0.clarity = -1; $0.exposure = -1 }),
    ] }
}

/// Deep shadows must not grow saturated speckles. Several kernels change luminance by scaling the colour by
/// y2 / y; with a tiny (or cancelling, mixed-sign) y, a shadow lift multiplied a near-black colour's chroma by
/// hundreds and it became a saturated orange or green pixel (iPhone beach photo, rock shadows).
@Suite(.serialized) struct ShadowSpeckleTests {
    static let films = ["kodak-portra-400", "fuji-provia-100f", "kodak-kodachrome-64", "agfa-apx-100", "fuji-fp-100c",
                        "vision3-500t", "cinema-print"]

    @Test func darkWideGamutShadowsStaySpeckleFree() throws {
        let renderer = Renderer(library: try FilmLibrary(directory: FilmTests.filmsDirectory()))
        let ctx = Renderer.makeContext()
        // The P3 card is itself saturated (and the curves control lifts it three stops), so its limit is looser; the
        // chroma-noise card has no real chroma to lift and is held to 0.3.
        let sources: [(String, CIImage, Float)] = [("chromaNoise", ShadowSpeckle.chromaNoise(size: 128), 0.3),
                                                   ("darkP3", ShadowSpeckle.darkP3(size: 128), 0.8)]
        var failures: [String] = []
        for film in [nil] + Self.films.map(Optional.some) {
            for (grain, hal, bloom) in [(0.5, 0.5, 0.5), (1.0, 1.0, 1.0)] {
                for (cname, set) in ShadowSpeckle.controls {
                    for (sname, src, limit) in sources {
                        if film == nil && grain > 0.5 { continue }
                        // The P3 card is itself saturated: lifted three stops its colours are legitimately saturated
                        // (the luma-ratio scale keeps their saturation), so only the unlifted controls are held to it;
                        // the lifts are held to the chroma-noise card and to the chroma-gain test below.
                        if sname == "darkP3" && (cname == "lift" || cname == "curves") { continue }
                        var r = Recipe(filmID: film, grainAmount: film == nil ? 0 : grain,
                                       halationAmount: film == nil ? 0 : hal, bloomAmount: film == nil ? 0 : bloom)
                        set(&r)
                        let s = ShadowSpeckle.measure(renderer.apply(r, to: src), context: ctx, chroma: limit, dark: 0.6)
                        if s.outliers > 0 || s.nonFinite > 0 {
                            failures.append("\(film ?? "no film") g\(grain) \(cname) \(sname): \(s.outliers) speckles (worst chroma \(s.worstChroma) \(s.worstPix)), \(s.nonFinite) non-finite")
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(8))")
    }

    /// The relight keeps ordinary pixels as they were: a midtone lift scales the colour by the luma ratio.
    @Test func relightOfNormalPixelsIsUnchanged() throws {
        let renderer = Renderer(library: try emptyLibrary())
        let ctx = Renderer.makeContext()
        // Encoded (0.5, 0.4, 0.3) -> linear.
        func lin(_ e: Float) -> Float { pow((e + 0.055) / 1.055, 2.4) }
        let src = PipelineFixture.linearImage(width: 16, height: 16) { _, _ in (lin(0.5), lin(0.4), lin(0.3)) }
        var r = Recipe(); r.whites = 0.5
        let p = LinearPixels(renderer.apply(r, to: src), context: ctx)
        func enc(_ v: Float) -> Float { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        let e = (enc(p.rgba[0]), enc(p.rgba[1]), enc(p.rgba[2]))
        let y: Float = 0.2126 * 0.5 + 0.7152 * 0.4 + 0.0722 * 0.3
        let y2 = y + 0.33 * 0.5 * y * y * y
        let k = y2 / y
        #expect(abs(e.0 - 0.5 * k) < 0.004 && abs(e.1 - 0.4 * k) < 0.004 && abs(e.2 - 0.3 * k) < 0.004, "\(e) vs ratio \(k)")
    }

    /// A legitimately dark, coloured patch (encoded luma ~0.08, non-negative channels) lifted by shadows must keep the
    /// chroma gain of the plain luma-ratio scaling (1.0.0): the speckle guard may only bite for tiny luma.
    @Test func darkColouredPatchKeepsTheRatioChromaGain() throws {
        let renderer = Renderer(library: try emptyLibrary())
        let ctx = Renderer.makeContext()
        func lin(_ e: Float) -> Float { e <= 0.04045 ? e / 12.92 : pow((e + 0.055) / 1.055, 2.4) }
        func enc(_ v: Float) -> Float { v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055 }
        func smooth(_ a: Float, _ b: Float, _ x: Float) -> Float { let t = min(max((x - a) / (b - a), 0), 1); return t * t * (3 - 2 * t) }
        let patches: [(Float, Float, Float)] = [(0.17, 0.10, 0.05), (0.04, 0.13, 0.05), (0.06, 0.09, 0.22), (0.14, 0.04, 0.04)]
        for shadows in [Float(0.5), 1] {
            for p in patches {
                let src = PipelineFixture.linearImage(width: 64, height: 64) { _, _ in (lin(p.0), lin(p.1), lin(p.2)) }
                var r = Recipe(); r.shadows = Double(shadows)
                let out = LinearPixels(renderer.apply(r, to: src), context: ctx)
                let i = (32 * 64 + 32) * 4
                let got = (enc(out.rgba[i]), enc(out.rgba[i + 1]), enc(out.rgba[i + 2]))
                let y = 0.2126 * p.0 + 0.7152 * p.1 + 0.0722 * p.2
                let y2 = y + shadows * (1 - smooth(0.05, 0.65, y)) * 0.3 * (1 - y)
                let k = y2 / y
                let want = (p.0 * k, p.1 * k, p.2 * k)
                func chroma(_ c: (Float, Float, Float)) -> Float { max(c.0, c.1, c.2) - min(c.0, c.1, c.2) }
                let gainWanted = chroma(want) - chroma(p), gainGot = chroma(got) - chroma(p)
                #expect(y > 0.05 && y < 0.12)
                #expect(gainGot >= 0.9 * gainWanted, "shadows \(shadows) patch \(p) luma \(y): chroma gain \(gainGot) vs 1.0.0 \(gainWanted)")
            }
        }
    }
}
