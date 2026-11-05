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

    static let highlights: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraHighlights", fromMetalLibraryData: $0)
    }

    static let halationCombine: CIColorKernel? = library.flatMap {
        try? CIColorKernel(functionName: "miraHalationCombine", fromMetalLibraryData: $0)
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
            && scan != nil && toning != nil
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

    /// The part of the image that halation scatters (blur this).
    static func halationHighlights(of image: CIImage) -> CIImage {
        guard let kernel = highlights else { return image }
        return kernel.apply(extent: image.extent, arguments: [image]) ?? image
    }

    /// Removes `amount` of the highlights from `image` and adds the same luminance back from `blurred`
    /// (the blurred highlights), coloured by `tint` (linear RGB, normalised to unit luminance here).
    static func applyHalation(amount: Double, tint: [Double], to image: CIImage, blurred: CIImage) -> CIImage {
        guard let kernel = halationCombine, tint.count == 3 else { return image }
        let t = CIVector(x: tint[0], y: tint[1], z: tint[2], w: 0)
        return kernel.apply(extent: image.extent, arguments: [image, blurred, Float(amount), t]) ?? image
    }

    /// Film grain on an sRGB-encoded `image`. `cell` is the grain cell as a fraction of `diagonal`; `std`
    /// the noise standard deviation (encoded units, before the tonal weight).
    static func applyGrain(std: Double, cell: Double, chroma: Double, tonalCenter: Double,
                           diagonal: Double, to image: CIImage) -> CIImage {
        guard let kernel = grain else { return image }
        let e = image.extent
        let geo = CIVector(x: e.minX, y: e.minY, z: diagonal, w: cell)
        let par = CIVector(x: std, y: chroma, z: tonalCenter, w: 0)
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
