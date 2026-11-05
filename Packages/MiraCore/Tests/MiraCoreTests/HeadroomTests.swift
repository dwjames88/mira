import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

/// Scene-referred headroom before the film (pipeline 2): synthetic HDR ramps, no RAW file needed.
@Suite struct HeadroomTests {
    static let samples = 801  // ramp 0...8 in steps of 0.01

    static func hdrRamp(max: Float = 8) -> CIImage {
        PipelineFixture.linearImage(width: samples, height: 1) { x, _ in
            let v = max * Float(x) / Float(samples - 1)
            return (v, v, v)
        }
    }

    static func library() throws -> FilmLibrary {
        try SyntheticFilms.library([
            .init(id: "neg", family: .colorNegative),
            .init(id: "slide", family: .slide),
        ])
    }

    func kernelRamp(gain: Double, latitude: Double, headroom: Double) -> [Double] {
        let out = LinearPixels(GradeKernels.applyFilmExposure(gain: gain, latitude: latitude, headroom: headroom,
                                                              to: Self.hdrRamp()))
        return (0..<Self.samples).map { out.value($0, 0, 1) }
    }

    // MARK: Maths

    @Test func shoulderIsC1MapsWhiteToOneAndIsMonotone() {
        for (g, h) in [(1.0, 8.0), (2.0, 4.0), (0.5, 8.0), (1.0, 1.5)] {
            let w = g * h
            #expect(abs(FilmMath.exposure(h, gain: g, latitude: 1, headroom: h) - 1) < 1e-12, "g=\(g) H=\(h)")
            let k = FilmMath.shoulderKnee
            // Slope 1 on both sides of the knee.
            let eps = 1e-6
            let below = (FilmMath.exposure((k - eps) / g, gain: g, latitude: 1, headroom: h)
                         - FilmMath.exposure((k - 2 * eps) / g, gain: g, latitude: 1, headroom: h)) / eps
            let above = (FilmMath.exposure((k + 2 * eps) / g, gain: g, latitude: 1, headroom: h)
                         - FilmMath.exposure((k + eps) / g, gain: g, latitude: 1, headroom: h)) / eps
            #expect(abs(below - 1) < 1e-4 && abs(above - 1) < 1e-3, "slope \(below) / \(above), W=\(w)")
            var last = -1.0
            for i in 0...400 {
                let y = FilmMath.exposure(h * Double(i) / 400, gain: g, latitude: 1, headroom: h)
                #expect(y >= last)
                last = y
            }
        }
        // Below the knee it is the plain gain.
        #expect(FilmMath.exposure(0.3, gain: 1, latitude: 1, headroom: 8) == 0.3)
        // No shoulder when gain x headroom stays within range.
        #expect(FilmMath.exposure(0.9, gain: 0.5, latitude: 1, headroom: 2) == 0.45)
        // Negative values stay a plain gain.
        #expect(FilmMath.exposure(-0.2, gain: 1, latitude: 1, headroom: 8) == -0.2)
    }

    @Test func kernelMatchesFilmMathWithHeadroom() {
        for (g, l, h) in [(1.0, 1.0, 8.0), (2.0, 1.0, 4.0), (1.0, 0.15, 8.0), (0.5, 0.6, 6.0), (2.0, 0.5, 1.0)] {
            let ramp = kernelRamp(gain: g, latitude: l, headroom: h)
            for i in stride(from: 0, to: Self.samples, by: 7) {
                let x = 8 * Double(i) / Double(Self.samples - 1)
                let expected = FilmMath.exposure(x, gain: g, latitude: l, headroom: h)
                #expect(abs(ramp[i] - expected) < 2e-3 * max(1, abs(expected)), "g=\(g) L=\(l) H=\(h) x=\(x): \(ramp[i]) vs \(expected)")
            }
        }
    }

    // MARK: SDR unchanged

    @Test func sdrKernelMatchesValuesCapturedBeforeTheChange() {
        // Old maths: x (g + x) / (1 + g x), blended with g x by latitude. Captured from FilmMath before
        // the headroom change: (x, g, latitude) -> y.
        let captured: [(Double, Double, Double, Double)] = [
            (0.25, 2, 1, 0.375), (0.5, 2, 1, 0.625), (1, 2, 1, 1), (0.5, 2, 0.5, 0.8125),
            (0.5, 2, 0, 1), (0.25, 1, 1, 0.25), (0.4, 0.5, 1, 0.2),
        ]
        for (x, g, l, y) in captured {
            #expect(FilmMath.exposure(x, gain: g, latitude: l) == y, "FilmMath x=\(x) g=\(g)")
            let img = PipelineFixture.linearImage(width: 1, height: 1) { _, _ in (Float(x), Float(x), Float(x)) }
            let out = LinearPixels(GradeKernels.applyFilmExposure(gain: g, latitude: l, to: img))
            #expect(abs(out.value(0, 0, 1) - y) < 1e-3, "kernel x=\(x) g=\(g) L=\(l): \(out.value(0, 0, 1))")
        }
    }

    @Test func sdrRenderIsBitIdenticalWithDefaultAndExplicitHeadroom() throws {
        let r = Renderer(library: try Self.library())
        let src = Fixture.gradientAndPatches(size: 128)
        for ev in [0.0, 1.0] {
            let recipe = Recipe(filmID: "neg", exposure: ev)
            let a = LinearPixels(r.apply(recipe, to: src))
            let b = LinearPixels(r.apply(recipe, to: src, sourceHeadroom: 1))
            let c = LinearPixels(r.grade(recipe, cropped: src))
            #expect(a.rgba == b.rgba && a.rgba == c.rgba, "exposure \(ev)")
        }
    }

    // MARK: HDR through the renderer

    @Test func negativeKeepsHighlightGradationUpTo8() throws {
        let r = Renderer(library: try Self.library())
        let ramp = Self.hdrRamp()
        let hdr = LinearPixels(r.apply(Recipe(filmID: "neg"), to: ramp, sourceHeadroom: 8))
        let clipped = LinearPixels(r.apply(Recipe(filmID: "neg"), to: ramp))
        let out = (0..<Self.samples).map { hdr.value($0, 0, 1) }
        #expect(out.allSatisfy { $0 <= 1.0005 })
        for i in 1..<Self.samples { #expect(out[i] >= out[i - 1] - 1e-4) }
        let at = { (v: Double) in out[Int((v * 100).rounded())] }
        #expect(at(2) < at(4) && at(4) < at(8) && at(8) <= 1.0005)
        #expect(at(2) < 0.999 && at(4) < 0.999)
        #expect(at(4) - at(2) > 0.01 && at(8) - at(4) > 0.005)
        // Without headroom everything above 1 clips flat.
        #expect(abs(clipped.value(200, 0, 1) - clipped.value(800, 0, 1)) < 1e-4)
    }

    @Test func preLUTRampBelowOneForColourNegative() {
        let ramp = kernelRamp(gain: 1, latitude: 1, headroom: 8)
        #expect(ramp.allSatisfy { $0 <= 1.0005 })
        for i in 1..<ramp.count { #expect(ramp[i] >= ramp[i - 1]) }
        #expect(ramp[200] < ramp[400] && ramp[400] < ramp[800])
    }

    @Test func slideStillClipsHard() throws {
        let r = Renderer(library: try Self.library())
        let ramp = Self.hdrRamp()
        let slideLatitude = try #require(r.library.film(id: "slide")?.resolvedCharacter.latitude)
        #expect(slideLatitude <= 0.2)
        // Pre-LUT: most of 1...8 stays above white (the LUT then clips it).
        let pre = kernelRamp(gain: 1, latitude: slideLatitude, headroom: 8)
        let above = (100..<Self.samples).filter { pre[$0] > 1 }.count
        #expect(Double(above) / Double(Self.samples - 100) > 0.8)
        // Rendered: flat at white from x = 2.
        let out = LinearPixels(r.apply(Recipe(filmID: "slide"), to: ramp, sourceHeadroom: 8))
        let flat = (200..<Self.samples).filter { out.value($0, 0, 1) > 0.999 }.count
        #expect(Double(flat) / Double(Self.samples - 200) > 0.9)
    }

    @Test func taggedSourceCarriesHeadroom() throws {
        let r = Renderer(library: try Self.library())
        let tagged = DevelopedSource(image: Self.hdrRamp(), headroom: 8)
        #expect(tagged.image.miraHeadroom == 8)
        #expect(tagged.image.transformed(by: .init(scaleX: 2, y: 2)).miraHeadroom == 8)
        let a = LinearPixels(r.apply(Recipe(filmID: "neg"), to: tagged.image))
        let b = LinearPixels(r.apply(Recipe(filmID: "neg"), to: Self.hdrRamp(), sourceHeadroom: 8))
        #expect(a.rgba == b.rgba)
        #expect(Self.hdrRamp().miraHeadroom == 1)
    }
}
