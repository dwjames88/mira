import CoreGraphics
import CoreImage
import Foundation
import Metal

/// The downscaled, materialised copy of a source that the iOS live preview grades every frame
/// (the Mac `PreviewEngine` builds the same thing as half-float pyramid levels).
public enum PreviewProxy {
    static let linearSpace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    /// A proxy of `source` with a long side of `wanted` pixels, or `source` itself when `wanted` reaches its size.
    ///
    /// The proxy is a half-float bitmap in extended linear sRGB, the context's own working format, so it holds
    /// exactly what the export would see: scene values above 1 (a RAW developed with headroom) survive, and so
    /// does the headroom tag the exposure shoulder reads. (An 8-bit proxy clipped everything above 1 yet kept a
    /// headroom of, say, 1.7, so the shoulder mapped a white point that no longer existed.) Non-finite pixels
    /// are replaced on the way in. Falls back to the lazy scaled image when the context cannot render it.
    public static func make(from source: CIImage, renderer: Renderer, context: CIContext, wanted: CGFloat) -> CIImage {
        let longest = max(source.extent.width, source.extent.height)
        if wanted >= longest { return source }
        let headroom = source.miraHeadroom
        let scaled = GradeKernels.applySanitize(limit: Double(headroom),
                                                to: renderer.previewImage(from: source, maxPixelSize: wanted))
        guard let cg = context.createCGImage(scaled, from: scaled.extent, format: .RGBAh, colorSpace: linearSpace) else {
            return scaled.withMiraExposureTime(source.miraExposureTime).withMiraHeadroom(headroom)
        }
        // A bitmap-backed image has no properties: carry the source's EXIF exposure time and headroom over
        // so the reciprocity and exposure stages see them on the proxy too.
        return CIImage(cgImage: cg, options: [.colorSpace: linearSpace])
            .withMiraExposureTime(source.miraExposureTime)
            .withMiraHeadroom(headroom)
    }
}

extension Renderer {
    /// The context for a Metal queue the host owns (the iOS live preview renders to its drawable through it):
    /// same working space and format as `makeContext`, with intermediates cached across frames.
    public static func makeContext(commandQueue: MTLCommandQueue, cacheIntermediates: Bool = true) -> CIContext {
        CIContext(mtlCommandQueue: commandQueue, options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: cacheIntermediates,
            .name: "Mira",
        ])
    }
}
