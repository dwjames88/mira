import CoreImage
import Foundation

/// The Core Image Metal kernels for the curves and colour mixer stages. They live in
/// `Kernels/Grade.ci.metal` and ship precompiled as `Resources/Grade.ci.metallib`
/// (see `scripts/build-kernels.sh`).
enum GradeKernels {
    private static let library: Data? = {
        guard let url = Bundle.module.url(forResource: "Grade.ci", withExtension: "metallib") else { return nil }
        return try? Data(contentsOf: url)
    }()

    static let colorMixer: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraColorMixer", fromMetalLibraryData: $0)
    }

    static let curves: CIKernel? = library.flatMap {
        try? CIKernel(functionName: "miraCurves", fromMetalLibraryData: $0)
    }

    static let tone: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraTone", fromMetalLibraryData: $0)
    }

    static let detail: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraDetail", fromMetalLibraryData: $0)
    }

    static let dodgeBurn: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraDodgeBurn", fromMetalLibraryData: $0)
    }

    static let filmExposure: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraFilmExposure", fromMetalLibraryData: $0)
    }

    static let reciprocity: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraReciprocity", fromMetalLibraryData: $0)
    }

    static let highlights: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraHighlights", fromMetalLibraryData: $0)
    }

    static let halationCombine: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraHalationCombine", fromMetalLibraryData: $0)
    }

    static let lut3D: CIKernel? = library.flatMap {
        try? CIKernel(functionName: "miraLUT3D", fromMetalLibraryData: $0)
    }

    static let grain: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraGrain", fromMetalLibraryData: $0)
    }

    static let scan: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraScan", fromMetalLibraryData: $0)
    }

    static let toning: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraToning", fromMetalLibraryData: $0)
    }

    /// Whether all kernels loaded (tests check this; a missing kernel makes its stage a no-op).
    static var isAvailable: Bool {
        colorMixer != nil && curves != nil && tone != nil && detail != nil && dodgeBurn != nil
            && filmExposure != nil && highlights != nil && halationCombine != nil && grain != nil
            && scan != nil && toning != nil && lut3D != nil
    }

    // MARK: Stages

    static func applyColorMixer(_ settings: ColorMixerSettings, to image: CIImage) -> CIImage {
        guard let kernel = colorMixer else { return image }
        func vectors(_ value: (ColorAdjust) -> Double) -> [CIVector] {
            let v = ColorRange.allCases.map { min(max(value(settings[$0]), -1), 1) }
            return [CIVector(x: v[0], y: v[1], z: v[2], w: v[3]), CIVector(x: v[4], y: v[5], z: v[6], w: v[7])]
        }
        let hue = vectors(\.hue), sat = vectors(\.saturation), lum = vectors(\.luminance)
        let args: [Any] = [image, hue[0], hue[1], sat[0], sat[1], lum[0], lum[1]]
        return kernel.apply(extent: image.extent, arguments: args) ?? image
    }

    static func applyCurves(_ settings: CurvesSettings, to image: CIImage) -> CIImage {
        guard let kernel = curves else { return image }
        let size = CurvesSettings.lutSize
        let table = settings.kernelTable(size: size)
        let data = table.withUnsafeBufferPointer { Data(buffer: $0) }
        // No colour space: the table holds raw values, not colours to be managed.
        let lut = CIImage(bitmapData: data, bytesPerRow: size * 16, size: CGSize(width: size, height: 2),
                          format: .RGBAf, colorSpace: nil)
        let useLuma: Float = settings.isIdentity(.luminance) ? 0 : 1
        let lutExtent = lut.extent
        let output = kernel.apply(
            extent: image.extent,
            roiCallback: { index, rect in index == 1 ? lutExtent : rect },
            arguments: [image, lut, useLuma])
        return output ?? image
    }

    /// Highlights, shadows, whites and blacks in one pass. `base` is `image` blurred (the local
    /// luminance the highlight and shadow masks follow); pass `image` itself when those two are 0.
    static func applyTone(highlights: Double, shadows: Double, whites: Double, blacks: Double,
                          to image: CIImage, base: CIImage) -> CIImage {
        guard let kernel = tone else { return image }
        func c(_ v: Double) -> Float { Float(min(max(v, -1), 1)) }
        return kernel.apply(extent: image.extent,
                            arguments: [image, base, c(highlights), c(shadows), c(whites), c(blacks)]) ?? image
    }

    /// Local contrast: `amount` of (image - blur) added to luminance.
    static func applyDetail(amount: Double, midtoneWeighted: Bool, to image: CIImage, blurred: CIImage) -> CIImage {
        guard let kernel = detail else { return image }
        return kernel.apply(extent: image.extent,
                            arguments: [image, blurred, Float(amount), Float(midtoneWeighted ? 1 : 0)]) ?? image
    }

    /// Stops of exposure a fully painted, fully in-range pixel moves by.
    static let dodgeBurnStops: Float = 2

    /// One dodge or burn mask: `mask` is 0...1 where painted (strength already folded in).
    static func applyDodgeBurn(key: DodgeBurnLayerKey, mask: CIImage, to image: CIImage) -> CIImage {
        guard let kernel = dodgeBurn else { return image }
        let range: Float = switch key.range {
        case .shadows: 0
        case .midtones: 1
        case .highlights: 2
        }
        let luma = key.luma.map { $0.map { Float($0) / 1000 } }
        let args: [Any] = [image, mask, key.dodge ? dodgeBurnStops : -dodgeBurnStops, range, key.protect ? 1 : 0,
                           luma == nil ? 0 : 1, luma?[0] ?? 0, luma?[1] ?? 1, luma?[2] ?? 0]
        return kernel.apply(extent: image.extent, arguments: args) ?? image
    }

    // MARK: Film science stages (pipeline 2)

    /// Exposure gain `gain` (linear) with the film's highlight latitude.
    /// `headroom` is the largest linear value the source holds (1 for SDR); see `miraFilmExposure`.
    static func applyFilmExposure(gain: Double, latitude: Double, headroom: Double = 1, to image: CIImage) -> CIImage {
        guard let kernel = filmExposure else { return image }
        return kernel.apply(extent: image.extent, arguments: [image, Float(gain), Float(latitude), Float(max(headroom, 1))]) ?? image
    }

    /// Reciprocity failure (see `miraReciprocity`): per-channel linear `gain`, then a power `contrast` around 18 % grey.
    static func applyReciprocity(gain: (r: Double, g: Double, b: Double), contrast: Double, to image: CIImage) -> CIImage {
        guard let kernel = reciprocity else { return image }
        return kernel.apply(extent: image.extent,
                            arguments: [image, CIVector(x: gain.r, y: gain.g, z: gain.b), Float(contrast)]) ?? image
    }

    /// The part of the image that halation scatters (blur this).
    static func halationHighlights(of image: CIImage) -> CIImage {
        guard let kernel = highlights else { return image }
        return kernel.apply(extent: image.extent, arguments: [image]) ?? image
    }

    /// Share of the scattered light that is taken out of the source (the rest stays: the clipped core sits on
    /// the shoulder of the film curve, so removing light there is invisible on film).
    static let halationCompensation: Float = 0.2

    /// Removes `halationCompensation * amount` of the highlights from `image` and adds `amount` times the
    /// luminance of `blurred` (the blurred highlights), coloured by `tint` (linear RGB, normalised to unit
    /// luminance here).
    static func applyHalation(amount: Double, tint: [Double], to image: CIImage, blurred: CIImage) -> CIImage {
        guard let kernel = halationCombine, tint.count == 3 else { return image }
        let t = CIVector(x: tint[0], y: tint[1], z: tint[2], w: 0)
        return kernel.apply(extent: image.extent, arguments: [image, blurred, Float(amount), t, halationCompensation]) ?? image
    }

    // MARK: Float 3D LUT (pipeline 2)

    /// Applies `lut` (sRGB-encoded cube) to a working-space `image` in float with tetrahedral
    /// interpolation (`miraLUT3D`); `cacheKey` names the cube for the atlas cache ("film:<id>").
    /// Falls back to `CIColorCubeWithColorSpace` if the kernel is missing.
    static func applyLUT3D(_ lut: LUT, cacheKey: String, to image: CIImage) -> CIImage? {
        guard let kernel = lut3D else { return nil }
        let atlas = LUTAtlasCache.shared.atlas(for: lut, key: cacheKey)
        let atlasExtent = atlas.extent
        return kernel.apply(extent: image.extent,
                            roiCallback: { index, rect in index == 1 ? atlasExtent : rect },
                            arguments: [image, atlas, Float(lut.dimension)])
    }

    /// Film grain on an sRGB-encoded `image`. `cell` is the grain cell as a fraction of `diagonal`; `std`
    /// the noise standard deviation (encoded units, before the tonal weight); `shadowGain` scales the weight
    /// below the tonal centre (see `miraGrain`).
    static func applyGrain(std: Double, cell: Double, chroma: Double, tonalCenter: Double,
                           diagonal: Double, shadowGain: Double = 1, to image: CIImage) -> CIImage {
        guard let kernel = grain else { return image }
        let e = image.extent
        let geo = CIVector(x: e.minX, y: e.minY, z: diagonal, w: cell)
        let par = CIVector(x: std, y: chroma, z: tonalCenter, w: shadowGain)
        return kernel.apply(extent: e, arguments: [image, geo, par]) ?? image
    }

    /// Colour and tone transform after the film (see `miraScan`), on an sRGB-encoded `image`.
    static func applyScan(_ p: ScanParameters, to image: CIImage) -> CIImage {
        guard let kernel = scan, !p.isIdentity else { return image }
        let shift = CIVector(x: p.redShift, y: p.blueShift, z: 0, w: 0)
        let par = CIVector(x: p.contrast, y: p.saturation, z: p.blackLift, w: p.highlightSoftness)
        return kernel.apply(extent: image.extent, arguments: [image, shift, par]) ?? image
    }

    /// Split toning of a monochrome picture (see `miraToning`), on an sRGB-encoded `image`.
    static func applyToning(_ toning: Toning, amount: Double, to image: CIImage) -> CIImage {
        guard let kernel = self.toning, let tints = toning.tints, amount > 0 else { return image }
        func v(_ t: [Double]) -> CIVector { CIVector(x: t[0], y: t[1], z: t[2], w: 0) }
        return kernel.apply(extent: image.extent,
                            arguments: [image, v(tints.shadow), v(tints.highlight), Float(min(max(amount, 0), 1))]) ?? image
    }
}

/// The numbers behind a scan profile and push / pull contrast and black lift, all in sRGB-encoded units.
struct ScanParameters: Equatable {
    var redShift: Double = 0
    var blueShift: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var blackLift: Double = 0
    var highlightSoftness: Double = 0

    var isIdentity: Bool { self == ScanParameters() }

    /// Our own authored profiles (not measurements of any scanner): Frontier-like is slightly cool
    /// (blue +0.015, red -0.010 in the mids), a little more contrast (+0.08) and saturation (+0.06),
    /// blacks lifted by 0.015. Noritsu-like is slightly warm (red +0.012, blue -0.012), flatter
    /// (contrast -0.06, saturation -0.03) with the highlights softened above 0.85.
    static func profile(_ p: ScanProfile) -> ScanParameters {
        switch p {
        case .neutral: ScanParameters()
        case .frontier: ScanParameters(redShift: -0.010, blueShift: 0.015, contrast: 0.08, saturation: 0.06, blackLift: 0.015)
        case .noritsu: ScanParameters(redShift: 0.012, blueShift: -0.012, contrast: -0.06, saturation: -0.03, highlightSoftness: 0.5)
        }
    }
}

extension Toning {
    /// Shadow and highlight tint colours (encoded RGB, normalised to unit luma by the kernel).
    /// Selenium: cool purple-brown shadows, neutral highlights. Sepia: warm brown, strongest in the
    /// highlights. Cyanotype: cyan-blue throughout. Copper: red-brown.
    var tints: (shadow: [Double], highlight: [Double])? {
        switch self {
        case .none: nil
        case .selenium: ([1.0, 0.88, 1.06], [1, 1, 1])
        case .sepia: ([1.04, 1.0, 0.92], [1.2, 1.0, 0.7])
        case .cyanotype: ([0.7, 0.9, 1.15], [0.8, 1.0, 1.1])
        case .copper: ([1.1, 0.9, 0.8], [1.25, 0.95, 0.75])
        }
    }
}

/// Float cube atlases (width `dim * dim`, height `dim`; texel (r, g, b) at x = b * dim + r, y = g), one per
/// film or print look id, so a cube is rearranged and uploaded once. Bounded (least recently used goes
/// first) and thread safe, like the LUT cache in `FilmLibrary`. An entry is reused only while the cube it
/// was built from still looks the same (size and a strided fingerprint), so a reloaded library with new
/// data under the same id never serves a stale atlas.
final class LUTAtlasCache: @unchecked Sendable {
    static let shared = LUTAtlasCache()
    static let limit = 64

    private struct Entry { var fingerprint: [Float]; var image: CIImage }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var order: [String] = []

    var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    func atlas(for lut: LUT, key: String) -> CIImage {
        let print = Self.fingerprint(lut)
        lock.lock()
        if let hit = entries[key], hit.fingerprint == print {
            touch(key)
            lock.unlock()
            return hit.image
        }
        lock.unlock()
        let made = Self.makeAtlas(lut)   // built outside the lock
        lock.lock(); defer { lock.unlock() }
        entries[key] = Entry(fingerprint: print, image: made)
        touch(key)
        while order.count > Self.limit { entries[order.removeFirst()] = nil }
        return made
    }

    private func touch(_ key: String) {
        if let i = order.lastIndex(of: key) { order.remove(at: i) }
        order.append(key)
    }

    private static func fingerprint(_ lut: LUT) -> [Float] {
        let floats = lut.data.count / 4
        var out: [Float] = [Float(lut.dimension), Float(floats)]
        guard floats > 0 else { return out }
        lut.data.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: Float.self)
            let step = max(1, floats / 509)
            var i = 0
            while i < floats { out.append(p[i]); i += step }
            out.append(p[floats - 1])
        }
        return out
    }

    static func makeAtlas(_ lut: LUT) -> CIImage {
        let n = lut.dimension
        var out = [Float](repeating: 0, count: n * n * n * 4)
        lut.data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Float.self)
            let width = n * n
            for b in 0..<n {
                for g in 0..<n {
                    // CIImage row 0 is the top, so cube row g goes to bitmap row n - 1 - g.
                    let row = (n - 1 - g) * width
                    for r in 0..<n {
                        let from = ((b * n + g) * n + r) * 4
                        let to = (row + b * n + r) * 4
                        out[to] = src[from]; out[to + 1] = src[from + 1]
                        out[to + 2] = src[from + 2]; out[to + 3] = 1
                    }
                }
            }
        }
        let data = out.withUnsafeBufferPointer { Data(buffer: $0) }
        // No colour space: the cube holds raw values. Nearest sampling so reads at texel centres are exact.
        return CIImage(bitmapData: data, bytesPerRow: n * n * 16, size: CGSize(width: n * n, height: n),
                       format: .RGBAf, colorSpace: nil).samplingNearest()
    }
}
