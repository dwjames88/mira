import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Loads photos from disk as upright `CIImage`s, decoding camera RAW files with `CIRAWFilter`.
public enum ImageSource {
    /// True when the file's type conforms to `public.camera-raw-image` (DNG included).
    public static func isRAW(url: URL) -> Bool {
        var type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType
        if type == nil || type?.conforms(to: .rawImage) == false {
            // Missing file or a generic type: fall back to the extension.
            if let byExtension = UTType(filenameExtension: url.pathExtension), byExtension.conforms(to: .rawImage) {
                type = byExtension
            }
        }
        return type?.conforms(to: .rawImage) ?? false
    }

    /// Loads the image upright.
    ///
    /// With `orientation` (Photos' `fullSizeImageOrientation`) that orientation is applied to the
    /// file's pixels; without it the file's own metadata orientation is used.
    public static func load(url: URL, orientation: CGImagePropertyOrientation? = nil) -> CIImage? {
        Perf.interval("source load") { loadUntraced(url: url, orientation: orientation) }
    }

    private static func loadUntraced(url: URL, orientation: CGImagePropertyOrientation?) -> CIImage? {
        if isRAW(url: url), let raw = CIRAWFilter(imageURL: url) {
            if let orientation { raw.orientation = orientation }
            if let out = raw.outputImage { return out }
        }
        return loadNonRAW(url: url, orientation: orientation)
    }

    /// The image together with the colour space to export it in (Display P3 for RAW).
    public static func loadWithColorSpace(
        url: URL, orientation: CGImagePropertyOrientation? = nil
    ) -> (image: CIImage, colorSpace: CGColorSpace)? {
        guard let image = load(url: url, orientation: orientation) else { return nil }
        return (image, outputColorSpace(url: url, image: image))
    }

    public static func outputColorSpace(url: URL, image: CIImage) -> CGColorSpace {
        if isRAW(url: url) { return CGColorSpace(name: CGColorSpace.displayP3)! }
        return Renderer.outputColorSpace(for: image.colorSpace)
    }

    private static func loadNonRAW(url: URL, orientation: CGImagePropertyOrientation?) -> CIImage? {
        if let orientation {
            guard let image = CIImage(contentsOf: url) else { return nil }
            return image.oriented(orientation)
        }
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }
}
