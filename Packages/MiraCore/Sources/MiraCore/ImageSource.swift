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

    /// Decodes a non-RAW file into memory now (full resolution, upright), so later renders never
    /// touch the file. RAW files go through `load`, which stays lazy.
    public static func loadDecoded(url: URL, orientation: CGImagePropertyOrientation? = nil) -> CIImage? {
        if isRAW(url: url) { return load(url: url, orientation: orientation) }
        return Perf.interval("source load") {
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, options)
            else { return loadUntraced(url: url, orientation: orientation) }
            return CIImage(cgImage: cg).oriented(effectiveOrientation(src, override: orientation))
        }
    }

    /// A fast, small, upright decode for the first on-screen frame: ImageIO decodes JPEG and HEIC
    /// at reduced size, so this is a fraction of a full decode. nil for RAW files and on failure.
    public static func loadThumbnail(
        url: URL, orientation: CGImagePropertyOrientation? = nil, maxPixelSize: CGFloat
    ) -> CIImage? {
        if isRAW(url: url) { return nil }
        return Perf.interval("source load") {
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: false,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            return CIImage(cgImage: cg).oriented(effectiveOrientation(src, override: orientation))
        }
    }

    /// Pixel size of the first image after orientation, read from the header only.
    public static func orientedPixelSize(url: URL, orientation: CGImagePropertyOrientation? = nil) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        let o = effectiveOrientation(src, override: orientation)
        return o.rawValue >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private static func effectiveOrientation(_ src: CGImageSource, override: CGImagePropertyOrientation?) -> CGImagePropertyOrientation {
        if let override { return override }
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        let raw = (props?[kCGImagePropertyOrientation] as? UInt32) ?? 1
        return CGImagePropertyOrientation(rawValue: raw) ?? .up
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
