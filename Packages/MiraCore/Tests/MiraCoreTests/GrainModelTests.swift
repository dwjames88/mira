import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

/// A tiny deterministic generator for the Boolean-model reference.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func gauss() -> Double {
        let u = max(uniform(), 1e-12), v = uniform()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// Reference Boolean model (Design/GRAIN.md 6.5): discs with log-normal radii, Poisson count from the density, on a
/// 256 x 256 um patch; the transmittance is read through a Gaussian aperture and converted to density.
private enum BooleanReference {
    /// Density map (1 um cells) of the interior of the patch at density `d`, grains from the RMS granularity `rms`.
    static func densityMap(d: Double, rms: Double, readout: Double, seed: UInt64) -> (map: [Double], size: Int) {
        var rng = SplitMix(state: seed)
        let cv = 0.35, sig2 = log(1 + cv * cv), sig = sig2.squareRoot()
        // Mean radius from a_eff = E[a^2] / E[a] = rms^2 * 1810 / 0.4343 (um^2).
        let target = rms * rms * 1810 / 0.4343
        var s1 = 0.0, s2 = 0.0
        let probe = 20000
        var probeRng = SplitMix(state: 99)
        for _ in 0..<probe { let r = exp(sig * probeRng.gauss() - sig2 / 2); let a = .pi * r * r; s1 += a; s2 += a * a }
        let mu = (target / (s2 / s1)).squareRoot()
        let meanArea = s1 / Double(probe) * mu * mu
        let margin = 24.0, side = 256.0 + 2 * margin
        let lambda = log(10.0) * d / meanArea
        let mean = lambda * side * side
        let count = Int(max(0, (mean + mean.squareRoot() * rng.gauss()).rounded()))
        let cell = 0.25, n = Int(side / cell)
        var cover = [UInt8](repeating: 0, count: n * n)
        for _ in 0..<count {
            let x = rng.uniform() * side, y = rng.uniform() * side
            let r = mu * exp(sig * rng.gauss() - sig2 / 2)
            let x0 = Int((x - r) / cell), x1 = Int((x + r) / cell), y0 = Int((y - r) / cell), y1 = Int((y + r) / cell)
            if x1 < 0 || y1 < 0 || x0 >= n || y0 >= n { continue }
            for j in max(0, y0)...min(n - 1, y1) {
                let dy = (Double(j) + 0.5) * cell - y
                for i in max(0, x0)...min(n - 1, x1) {
                    let dx = (Double(i) + 0.5) * cell - x
                    if dx * dx + dy * dy <= r * r { cover[j * n + i] = 1 }
                }
            }
        }
        // 4 x 4 block average to 1 um cells of transmittance, then the Gaussian read-out.
        let m = n / 4
        var t = [Double](repeating: 0, count: m * m)
        for j in 0..<m { for i in 0..<m {
            var s = 0
            for b in 0..<4 { for a in 0..<4 { s += Int(cover[(j * 4 + b) * n + i * 4 + a]) } }
            t[j * m + i] = 1 - Double(s) / 16
        } }
        let radius = Int((3 * readout).rounded(.up))
        var kern = (-radius...radius).map { exp(-Double($0 * $0) / (2 * readout * readout)) }
        let ks = kern.reduce(0, +); kern = kern.map { $0 / ks }
        var tmp = t
        for j in 0..<m { for i in radius..<(m - radius) {
            var s = 0.0
            for k in -radius...radius { s += kern[k + radius] * t[j * m + i + k] }
            tmp[j * m + i] = s
        } }
        var out = tmp
        for j in radius..<(m - radius) { for i in 0..<m {
            var s = 0.0
            for k in -radius...radius { s += kern[k + radius] * tmp[(j + k) * m + i] }
            out[j * m + i] = s
        } }
        // Interior: the central 200 um (the margin absorbs the filter edge and the finite patch).
        let lo = Int(margin) + 28, hi = m - lo
        var map: [Double] = []
        for j in lo..<hi { for i in lo..<hi { map.append(-log10(max(out[j * m + i], 1e-6))) } }
        return (map, hi - lo)
    }
}

/// Lag (in samples, interpolated) where the horizontal autocorrelation of `v` (size x size) first drops below 1/e.
private func correlationLength(_ v: [Double], size: Int) -> Double {
    let mu = mean(v)
    var ac = [Double](repeating: 0, count: size / 2)
    for lag in 0..<(size / 2) {
        var s = 0.0, c = 0.0
        for j in 0..<size { for i in 0..<(size - lag) { s += (v[j * size + i] - mu) * (v[j * size + i + lag] - mu); c += 1 } }
        ac[lag] = s / c
    }
    let norm = ac[0]
    for lag in 1..<ac.count where ac[lag] / norm < exp(-1.0) {
        let a = ac[lag - 1] / norm, b = ac[lag] / norm
        return Double(lag - 1) + (a - exp(-1.0)) / (a - b)
    }
    return Double(ac.count)
}

@Suite struct GrainModelTests {
    let context = Renderer.sharedContext

    @Test func sliderLawAndFootprint() {
        #expect(GrainModel.gain(slider: 0) == 0)
        #expect(abs(GrainModel.gain(slider: 0.5) - 1) < 1e-12)
        #expect(abs(GrainModel.gain(slider: 1) - 2.462) < 0.01)
        // Exporting smaller (bigger pitch) lowers the per-pixel amplitude and widens the correlation.
        let c = FilmCharacter.generic
        let big = GrainModel.parameters(for: c, sliderAmount: 0.5, sizeSlider: 0.5, pitch: 6)
        let small = GrainModel.parameters(for: c, sliderAmount: 0.5, sizeSlider: 0.5, pitch: 24)
        #expect(small.amplitude < big.amplitude && small.tau > big.tau)
        #expect(big.lattice == small.lattice)
    }

    /// The GPU Gaussian field against a Boolean-model reference, at three densities (slide shape, whose g is the
    /// Boolean model's sqrt(D)): the std of the density within +-25%, the correlation length within +-30%.
    @Test func fieldMatchesBooleanReference() throws {
        let rms = 17.0, s = 3.0, pitch = 2.0
        let sigmaF = GrainModel.footprintSigma(pitch: pitch)
        let tau = (s * s + sigmaF * sigmaF).squareRoot()
        let amp = rms / 1000 * ((s * s + 144) / (tau * tau)).squareRoot()
        let params = GrainModel.Parameters(tau: tau, lattice: 1.5 * (s * s + 25).squareRoot(), amplitude: amp, pitch: pitch)
        var gpuLen = 0.0, refLen = 0.0
        for (k, d) in [0.4, 1.0, 1.4].enumerated() {
            let y = Float(pow(10.0, -d))
            let flat = PipelineFixture.linearImage(width: 600, height: 600) { _, _ in (y, y, y) }
            let out = LinearPixels(GradeKernels.applyGrain(params, seed: 11, clumping: 0, layerCorrelation: 1,
                                                           shape: .slide, to: flat), context: context)
            var gpu: [Double] = []
            for j in 0..<600 { for i in 0..<600 { gpu.append(-log10(max(out.value(i, j, 1), 1e-6))) } }
            let ref = BooleanReference.densityMap(d: d, rms: rms / 1000, readout: tau, seed: UInt64(1000 + k))
            let ratio = stddev(gpu) / stddev(ref.map)
            print("GRAINREF D=\(d) gpu \(stddev(gpu)) boolean \(stddev(ref.map)) ratio \(ratio)")
            #expect(ratio > 0.75 && ratio < 1.25, "D=\(d): gpu \(stddev(gpu)) vs Boolean \(stddev(ref.map)) ratio \(ratio)")
            if k == 1 {
                gpuLen = correlationLength(gpu, size: 600) * pitch
                refLen = correlationLength(ref.map, size: ref.size) * 1.0
            }
        }
        #expect(gpuLen / refLen > 0.7 && gpuLen / refLen < 1.3, "correlation length gpu \(gpuLen) um vs Boolean \(refLen) um")
        // And both near the analytic 2 tau.
        #expect(abs(gpuLen / (2 * tau) - 1) < 0.3, "gpu \(gpuLen) vs 2 tau \(2 * tau)")
    }

    @Test func grainSpectrumMatchesAcrossExportSizes() throws {
        let r = Renderer(library: try emptyLibrary())
        let recipe = Recipe(grainAmount: 0.7)
        func stdAtCommonSize(_ w: Int, _ h: Int) -> Double {
            let out = r.apply(recipe, to: PipelineFixture.flat(0.45, width: w, height: h))
            let small = Pixels(r.previewImage(from: out, maxPixelSize: 600), context: context)
            return stddev(small.channel(1))
        }
        let a = stdAtCommonSize(3600, 2400), b = stdAtCommonSize(1800, 1200)
        #expect(a > 0.0005, "grain survives downsampling: \(a)")
        #expect(a / b > 0.8 && a / b < 1.25, "3600 px \(a) vs 1800 px \(b)")
    }

    @Test func blackAndClearStayClean() throws {
        let r = Renderer(library: try emptyLibrary())
        for gray: CGFloat in [0, 0.004] {
            let out = Pixels(r.apply(Recipe(grainAmount: 1), to: PipelineFixture.flat(gray, width: 600, height: 600)), context: context)
            let ch = out.channel(1)
            let expected = Double(gray)
            #expect((ch.max() ?? 1) - expected <= 1.5 / 255, "gray \(gray): max \(ch.max() ?? 1)")
            #expect(expected - (ch.min() ?? 0) <= 1.5 / 255)
        }
        // A dark shadow never gets bright specks.
        let dark = Pixels(r.apply(Recipe(grainAmount: 1), to: PipelineFixture.flat(0.03, width: 600, height: 600)), context: context)
        #expect((dark.channel(1).max() ?? 1) < 0.03 + 3.0 / 255)
    }

    @Test func clumpingAddsCoarseStructure() throws {
        let params = GrainModel.Parameters(tau: 6, lattice: 9, amplitude: 0.05, pitch: 2)
        let flat = PipelineFixture.linearImage(width: 500, height: 500) { _, _ in (0.2, 0.2, 0.2) }
        func len(_ clump: Double) -> Double {
            let o = LinearPixels(GradeKernels.applyGrain(params, seed: 5, clumping: clump, layerCorrelation: 1,
                                                         shape: .blackAndWhite, to: flat), context: context)
            var v: [Double] = []
            for j in 0..<500 { for i in 0..<500 { v.append(o.value(i, j, 1)) } }
            return correlationLength(v, size: 500)
        }
        #expect(len(0.4) > len(0) * 1.15)
    }

    /// 24 MP grain stage on the GPU (flat input so the kernel is the only cost); the time is printed for the report.
    @Test func grainStageTimeAt24MP() throws {
        let ctx = Renderer.makeContext()
        let w = 6000, h = 4000
        let params = GrainModel.parameters(for: .generic, sliderAmount: 0.5, sizeSlider: 0.5,
                                           pitch: GrainModel.pitch(uncroppedLongSidePixels: Double(w)))
        let flat = PipelineFixture.flat(0.45, width: w, height: h)
        let grained = GradeKernels.applyGrain(params, seed: 3, clumping: 0.3, layerCorrelation: 0.88, shape: .negative, to: flat)
        var buf = [UInt16](repeating: 0, count: w * h * 4)
        func once() -> Double {
            let t = DispatchTime.now().uptimeNanoseconds
            buf.withUnsafeMutableBytes { p in
                ctx.render(grained, toBitmap: p.baseAddress!, rowBytes: w * 8, bounds: grained.extent, format: .RGBAh,
                           colorSpace: PipelineFixture.linear)
            }
            return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
        }
        _ = once()
        let flatOnly = { () -> Double in
            let t = DispatchTime.now().uptimeNanoseconds
            buf.withUnsafeMutableBytes { p in
                ctx.render(flat, toBitmap: p.baseAddress!, rowBytes: w * 8, bounds: flat.extent, format: .RGBAh,
                           colorSpace: PipelineFixture.linear)
            }
            return Double(DispatchTime.now().uptimeNanoseconds - t) / 1e6
        }
        _ = flatOnly()
        let times = (0..<5).map { _ in once() }.sorted()
        let base = (0..<5).map { _ in flatOnly() }.sorted()
        print("GRAIN 24MP stage: median \(times[2]) ms (flat render alone \(base[2]) ms, difference \(times[2] - base[2]) ms)")
        #expect(times[2] < 1000)
    }
}
