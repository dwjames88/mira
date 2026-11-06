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
    /// The image carries the file's EXIF exposure time (`CIImage.miraExposureTime`).
    public static func load(url: URL, orientation: CGImagePropertyOrientation? = nil) -> CIImage? {
        guard let loaded = Perf.interval("source load", { loadUntraced(url: url, orientation: orientation) }) else { return nil }
        // A RAW develop is already tagged with the file's exposure time (`RawDevelop.init` read it with the
        // same function), so the file is not opened a second time to tag it again.
        return loaded.tagged ? loaded.image : loaded.image.withMiraExposureTime(exposureTime(url: url))
    }

    /// The EXIF exposure time of the file in seconds (RAW files included); nil when it has none.
    public static func exposureTime(url: URL) -> Double? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        return exposureTime(properties: props)
    }

    /// `kCGImagePropertyExifExposureTime` of an ImageIO properties dictionary; nil when absent or not positive.
    public static func exposureTime(properties: [CFString: Any]) -> Double? {
        guard let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let t = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue,
              t.isFinite, t > 0 else { return nil }
        return t
    }

    /// `tagged` is true when the image already carries the exposure-time tag (a RAW develop).
    private static func loadUntraced(
        url: URL, orientation: CGImagePropertyOrientation?
    ) -> (image: CIImage, tagged: Bool)? {
        if isRAW(url: url), let develop = RawDevelop(url: url, orientation: orientation),
           let out = develop.apply(.identity, filmApplied: false, draft: false) {
            return (out, true)
        }
        return loadNonRAW(url: url, orientation: orientation).map { ($0, false) }
    }

    /// Decodes a non-RAW file into memory now (full resolution, upright), so later renders never
    /// touch the file. RAW files go through `load`, which stays lazy.
    public static func loadDecoded(url: URL, orientation: CGImagePropertyOrientation? = nil) -> CIImage? {
        if isRAW(url: url) { return load(url: url, orientation: orientation) }
        return Perf.interval("source load") {
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, options)
            else { return loadUntraced(url: url, orientation: orientation)?.image }
            return upright(cg, from: src, override: orientation)
        }
    }

    /// `cg` oriented upright and tagged with the exposure time; the source's properties are copied once
    /// for both (`orientation` overrides the file's own).
    private static func upright(
        _ cg: CGImage, from src: CGImageSource, override orientation: CGImagePropertyOrientation?
    ) -> CIImage {
        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
        return CIImage(cgImage: cg).oriented(effectiveOrientation(props, override: orientation))
            .withMiraExposureTime(props.flatMap(exposureTime(properties:)))
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
            return upright(cg, from: src, override: orientation)
        }
    }

    /// The preview JPEG a camera writes into its RAW file (ARW, NEF, CR2/3, DNG preview ...), upright, no
    /// RAW decode: a few milliseconds. The placeholder shown while the draft decode runs. nil when the
    /// file has no embedded preview or is not RAW. It is ImageIO's thumbnail (embedded image used when
    /// present; ImageIO may decode when absent, so callers run it off the main actor).
    public static func loadEmbeddedPreview(
        url: URL, orientation: CGImagePropertyOrientation? = nil, maxPixelSize: CGFloat = 1600
    ) -> CIImage? {
        guard isRAW(url: url), let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        return upright(cg, from: src, override: orientation)
    }

    /// Pixel size of the first image after orientation, read from the header only.
    public static func orientedPixelSize(url: URL, orientation: CGImagePropertyOrientation? = nil) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
        let o = effectiveOrientation(props, override: orientation)
        return o.rawValue >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    private static func effectiveOrientation(
        _ props: [CFString: Any]?, override: CGImagePropertyOrientation?
    ) -> CGImagePropertyOrientation {
        if let override { return override }
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
