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

    /// Whether both kernels loaded (tests check this; a missing kernel makes its stage a no-op).
    static var isAvailable: Bool { colorMixer != nil && curves != nil }

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
}
