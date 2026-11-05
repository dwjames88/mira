import CoreImage
import Foundation
import ImageIO

/// A developed photo together with the largest linear value it holds (1 for SDR; a RAW decoded with
/// extended dynamic range reports its measured peak, capped at 8). The renderer's exposure stage
/// maps `headroom` to white through the film's shoulder instead of clipping.
public struct DevelopedSource: @unchecked Sendable {
    public var image: CIImage
    public var headroom: CGFloat

    public init(image: CIImage, headroom: CGFloat = 1) {
        self.image = image.withMiraHeadroom(headroom)
        self.headroom = max(1, headroom)
    }
}

extension CIImage {
    static let miraHeadroomKey = "MiraSourceHeadroom"

    /// The headroom this image was tagged with (`DevelopedSource`, `ImageSource.developedSource`);
    /// 1 when untagged. The tag survives transforms and crops, so every `Renderer.apply` sees it
    /// without the caller passing it along; `Renderer.apply(sourceHeadroom:)` overrides it.
    public var miraHeadroom: CGFloat {
        if let v = properties[Self.miraHeadroomKey] as? Double { return max(1, CGFloat(v)) }
        return 1
    }

    /// A copy tagged with `headroom` (an untagged copy for headroom <= 1).
    func withMiraHeadroom(_ headroom: CGFloat) -> CIImage {
        guard headroom > 1 || miraHeadroom > 1 else { return self }
        return settingProperties(properties.merging([Self.miraHeadroomKey: Double(max(1, headroom))]) { $1 })
    }

    static let miraExposureTimeKey = "MiraSourceExposureTime"

    /// The photo's EXIF exposure time in seconds, as tagged by `ImageSource` when it loaded the file; nil when
    /// the file has none. Like the headroom tag it survives transforms and crops.
    public var miraExposureTime: Double? {
        guard let v = properties[Self.miraExposureTimeKey] as? Double, v.isFinite, v > 0 else { return nil }
        return v
    }

    /// A copy tagged with `seconds` (unchanged for nil or a non-positive value).
    public func withMiraExposureTime(_ seconds: Double?) -> CIImage {
        guard let seconds, seconds.isFinite, seconds > 0 else { return self }
        return settingProperties(properties.merging([Self.miraExposureTimeKey: seconds]) { $1 })
    }
}

extension ImageSource {
    /// The photo as the recipe wants it developed: a RAW file is decoded with `recipe.raw`
    /// (automatic boost and extended range resolve for `recipe.filmID != nil`), anything else is
    /// loaded normally. Always upright. `draft` is for on-screen previews (fast, reduced size);
    /// export and share pass false. Use this wherever a file is loaded for rendering.
    /// The image carries its headroom (`CIImage.miraHeadroom`).
    public static func developedSource(
        url: URL, orientation: CGImagePropertyOrientation? = nil, recipe: Recipe, draft: Bool
    ) -> CIImage? {
        developedSourceWithHeadroom(url: url, orientation: orientation, recipe: recipe, draft: draft)?.image
    }

    /// Like `developedSource`, with the headroom as a value.
    public static func developedSourceWithHeadroom(
        url: URL, orientation: CGImagePropertyOrientation? = nil, recipe: Recipe, draft: Bool
    ) -> DevelopedSource? {
        guard isRAW(url: url), let develop = RawDevelop(url: url, orientation: orientation) else {
            return load(url: url, orientation: orientation).map { DevelopedSource(image: $0) }
        }
        let scale = draft ? develop.previewScale() : 1
        let result = develop.develop(recipe.raw, filmApplied: recipe.filmID != nil, draft: draft, scale: scale)
            ?? load(url: url, orientation: orientation).map { DevelopedSource(image: $0) }
        guard var developed = result else { return nil }
        developed.image = developed.image.withMiraExposureTime(exposureTime(url: url))
        return developed
    }
}
