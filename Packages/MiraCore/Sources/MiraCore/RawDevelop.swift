import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO

// MARK: - Filter surface (a protocol so the settings mapping is testable without a RAW file)

/// The `CIRAWFilter` properties Mira drives. `CIRAWFilter` conforms; tests use a mock.
public protocol RawFilterControls: AnyObject {
    var isDraftModeEnabled: Bool { get set }
    var scaleFactor: Float { get set }
    var neutralChromaticity: CGPoint { get set }
    var neutralTemperature: Float { get set }
    var neutralTint: Float { get set }
    var boostAmount: Float { get set }
    var shadowBias: Float { get set }
    var localToneMapAmount: Float { get set }
    var extendedDynamicRangeAmount: Float { get set }
    var luminanceNoiseReductionAmount: Float { get set }
    var colorNoiseReductionAmount: Float { get set }
    var sharpnessAmount: Float { get set }
    var detailAmount: Float { get set }
    var moireReductionAmount: Float { get set }
    var isLensCorrectionEnabled: Bool { get set }

    var isLocalToneMapSupported: Bool { get }
    var isLuminanceNoiseReductionSupported: Bool { get }
    var isColorNoiseReductionSupported: Bool { get }
    var isSharpnessSupported: Bool { get }
    var isDetailSupported: Bool { get }
    var isMoireReductionSupported: Bool { get }
    var isLensCorrectionSupported: Bool { get }
}

extension CIRAWFilter: RawFilterControls {}

/// The decoder's own starting values for one file (white balance as shot, default boost, ...).
/// `nil` in `RawSettings` restores these. `baselineExposure` is never touched, so a ProRAW / DNG
/// opens at the brightness the camera intended.
public struct RawInitialValues: Equatable, Sendable {
    public var chromaticity: CGPoint
    public var temperature: Float
    public var tint: Float
    public var boost: Float
    public var shadowBias: Float
    public var localToneMap: Float
    public var extendedDynamicRange: Float
    public var luminanceNoiseReduction: Float
    public var colorNoiseReduction: Float
    public var sharpness: Float
    public var detail: Float
    public var moireReduction: Float
    public var lensCorrection: Bool

    public init(of f: some RawFilterControls) {
        chromaticity = f.neutralChromaticity
        temperature = f.neutralTemperature
        tint = f.neutralTint
        boost = f.boostAmount
        shadowBias = f.shadowBias
        localToneMap = f.localToneMapAmount
        extendedDynamicRange = f.extendedDynamicRangeAmount
        luminanceNoiseReduction = f.luminanceNoiseReductionAmount
        colorNoiseReduction = f.colorNoiseReductionAmount
        sharpness = f.sharpnessAmount
        detail = f.detailAmount
        moireReduction = f.moireReductionAmount
        lensCorrection = f.isLensCorrectionEnabled
    }
}

/// Which controls a file's decoder supports, and their ranges (from the CIRAWFilter header).
public struct RawSupportedControls: Equatable, Sendable {
    public var localToneMap = false
    public var luminanceNoiseReduction = false
    public var colorNoiseReduction = false
    public var sharpness = false
    public var detail = false
    public var moireReduction = false
    public var lensCorrection = false

    public static let temperatureRange: ClosedRange<Double> = 2000...50000
    public static let tintRange: ClosedRange<Double> = -150...150
    public static let boostRange: ClosedRange<Double> = 0...1
    public static let extendedDynamicRange: ClosedRange<Double> = 0...2
    public static let detailRange: ClosedRange<Double> = 0...3
    public static let unitRange: ClosedRange<Double> = 0...1

    public init() {}

    public init(of f: some RawFilterControls) {
        localToneMap = f.isLocalToneMapSupported
        luminanceNoiseReduction = f.isLuminanceNoiseReductionSupported
        colorNoiseReduction = f.isColorNoiseReductionSupported
        sharpness = f.isSharpnessSupported
        detail = f.isDetailSupported
        moireReduction = f.isMoireReductionSupported
        lensCorrection = f.isLensCorrectionSupported
    }
}

/// Resolves `RawSettings` against a filter. Pure: everything it needs is passed in.
public enum RawSettingsMapper {
    /// Highest `extendedDynamicRangeAmount` the filter accepts.
    public static let maxExtendedDynamicRange: Float = 2

    /// Boost: explicit value, else 0 with a film (its own curve does the look and the image stays
    /// scene-referred), else the decoder default.
    public static func resolvedBoost(_ s: RawSettings, filmApplied: Bool, initial: RawInitialValues) -> Float {
        if let b = s.boostAmount { return clamp(b, RawSupportedControls.boostRange) }
        return filmApplied ? 0 : initial.boost
    }

    /// Extended dynamic range: explicit value, else the maximum with a film (highlights above 1.0
    /// reach the film's shoulder), else the decoder default.
    public static func resolvedExtendedDynamicRange(_ s: RawSettings, filmApplied: Bool, initial: RawInitialValues) -> Float {
        if let e = s.extendedDynamicRangeAmount { return clamp(e, RawSupportedControls.extendedDynamicRange) }
        return filmApplied ? maxExtendedDynamicRange : initial.extendedDynamicRange
    }

    /// Writes `settings` to `filter`. Optional controls are only touched when supported.
    public static func apply(
        _ s: RawSettings, filmApplied: Bool, draft: Bool, scale: Float,
        initial: RawInitialValues, to f: some RawFilterControls
    ) {
        f.isDraftModeEnabled = draft
        f.scaleFactor = min(max(scale, 0.01), 1)

        if s.temperature == nil, s.tint == nil {
            f.neutralChromaticity = initial.chromaticity
        } else {
            f.neutralTemperature = s.temperature.map { clamp($0, RawSupportedControls.temperatureRange) } ?? initial.temperature
            f.neutralTint = s.tint.map { clamp($0, RawSupportedControls.tintRange) } ?? initial.tint
        }
        f.boostAmount = resolvedBoost(s, filmApplied: filmApplied, initial: initial)
        f.extendedDynamicRangeAmount = resolvedExtendedDynamicRange(s, filmApplied: filmApplied, initial: initial)
        f.shadowBias = s.shadowBias.map { clamp($0, -1...1) } ?? initial.shadowBias

        if f.isLocalToneMapSupported {
            f.localToneMapAmount = s.localToneMapAmount.map { clamp($0, RawSupportedControls.unitRange) } ?? initial.localToneMap
        }
        if f.isLuminanceNoiseReductionSupported {
            f.luminanceNoiseReductionAmount = s.luminanceNoiseReductionAmount.map { clamp($0, RawSupportedControls.unitRange) }
                ?? initial.luminanceNoiseReduction
        }
        if f.isColorNoiseReductionSupported {
            f.colorNoiseReductionAmount = s.colorNoiseReductionAmount.map { clamp($0, RawSupportedControls.unitRange) }
                ?? initial.colorNoiseReduction
        }
        if f.isSharpnessSupported {
            f.sharpnessAmount = s.sharpnessAmount.map { clamp($0, RawSupportedControls.unitRange) } ?? initial.sharpness
        }
        if f.isDetailSupported {
            f.detailAmount = s.detailAmount.map { clamp($0, RawSupportedControls.detailRange) } ?? initial.detail
        }
        if f.isMoireReductionSupported {
            f.moireReductionAmount = s.moireReductionAmount.map { clamp($0, RawSupportedControls.unitRange) } ?? initial.moireReduction
        }
        if f.isLensCorrectionSupported {
            f.isLensCorrectionEnabled = s.lensCorrection ?? initial.lensCorrection
        }
    }

    private static func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Float {
        Float(min(max(v.isFinite ? v : r.lowerBound, r.lowerBound), r.upperBound))
    }
}

// MARK: - RawDevelop

/// Owns one `CIRAWFilter` for a file and develops it with `RawSettings`.
///
/// The filter is kept for the session: re-developing only changes properties and asks for
/// `outputImage` again, which is lazy and cheap. Calls are serialised with a lock, so one instance
/// may be used from any thread. Preview decodes use draft mode and a reduced `scaleFactor`; export
/// uses neither (see `ImageSource.developedSource`).
public final class RawDevelop: @unchecked Sendable {
    private let filter: CIRAWFilter
    private let lock = NSLock()

    public let initial: RawInitialValues
    public let supported: RawSupportedControls
    /// Pixel size of the full decode (before orientation).
    public let nativeSize: CGSize
    /// Neutral temperature and tint the camera recorded, in kelvin and tint units.
    public var asShot: (temperature: Double, tint: Double) { (Double(initial.temperature), Double(initial.tint)) }

    /// `orientation` (Photos' `fullSizeImageOrientation`) overrides the file's own; nil keeps it.
    public init?(url: URL, orientation: CGImagePropertyOrientation? = nil) {
        guard let f = CIRAWFilter(imageURL: url) else { return nil }
        filter = f
        if let orientation { f.orientation = orientation }
        initial = RawInitialValues(of: f)
        supported = RawSupportedControls(of: f)
        nativeSize = f.nativeSize
    }

    /// For Photos editing input handed over as data; `typeHint` is a UTI such as "com.adobe.raw-image".
    public init?(data: Data, typeHint: String?, orientation: CGImagePropertyOrientation? = nil) {
        guard let f = CIRAWFilter(imageData: data, identifierHint: typeHint) else { return nil }
        filter = f
        if let orientation { f.orientation = orientation }
        initial = RawInitialValues(of: f)
        supported = RawSupportedControls(of: f)
        nativeSize = f.nativeSize
    }

    /// Scale to decode at for an on-screen preview: the long side is capped at
    /// `PreviewSizing.maxSide` and the picture is never upscaled.
    public func previewScale() -> Float {
        let longSide = max(nativeSize.width, nativeSize.height)
        guard longSide > PreviewSizing.maxSide else { return 1 }
        return Float(PreviewSizing.maxSide / longSide)
    }

    /// Longest side of the reduced decode used to measure headroom.
    static let headroomProbeSide: CGFloat = 400
    /// Highest headroom reported.
    public static let maxHeadroom: CGFloat = 8

    private struct HeadroomKey: Hashable {
        var settings: RawSettings
        var filmApplied: Bool
    }
    private var headroomCache: [HeadroomKey: CGFloat] = [:]

    /// The upright image for `settings`. `draft` favours speed (previews); `scale` < 1 decodes smaller.
    /// The image is tagged with its headroom (`CIImage.miraHeadroom`).
    public func apply(
        _ settings: RawSettings, filmApplied: Bool, draft: Bool, scale: Float = 1
    ) -> CIImage? {
        develop(settings, filmApplied: filmApplied, draft: draft, scale: scale)?.image
    }

    /// Like `apply`, also reporting the headroom: the largest linear value the decode holds. It is
    /// 1 unless a film is applied and extended dynamic range is on (explicitly or by the film
    /// default); then it is measured, see `measureHeadroom`.
    public func develop(
        _ settings: RawSettings, filmApplied: Bool, draft: Bool, scale: Float = 1
    ) -> DevelopedSource? {
        lock.lock(); defer { lock.unlock() }
        var headroom: CGFloat = 1
        let edr = RawSettingsMapper.resolvedExtendedDynamicRange(settings, filmApplied: filmApplied, initial: initial)
        if filmApplied, edr > 0 {
            let key = HeadroomKey(settings: settings, filmApplied: filmApplied)
            if let hit = headroomCache[key] {
                headroom = hit
            } else {
                headroom = measureHeadroom(settings, filmApplied: filmApplied)
                headroomCache[key] = headroom
            }
        }
        RawSettingsMapper.apply(settings, filmApplied: filmApplied, draft: draft, scale: scale,
                                initial: initial, to: filter)
        guard let image = filter.outputImage else { return nil }
        return DevelopedSource(image: image, headroom: headroom)
    }

    /// Decodes a reduced draft (long side ~`headroomProbeSide`) with `settings` and returns its
    /// peak linear value (max of R, G, B over the image), clamped to 1...8. CIRAWFilter's
    /// `extendedDynamicRangeAmount` has no documented fixed relation to the peak (it varies with the
    /// file, boost and white balance: see RawIntegrationTests), so it is measured. Caller holds the lock.
    private func measureHeadroom(_ settings: RawSettings, filmApplied: Bool) -> CGFloat {
        let longSide = max(nativeSize.width, nativeSize.height)
        let scale = Float(min(1, Self.headroomProbeSide / max(longSide, 1)))
        RawSettingsMapper.apply(settings, filmApplied: filmApplied, draft: true, scale: scale,
                                initial: initial, to: filter)
        guard let probe = filter.outputImage, !probe.extent.isEmpty, !probe.extent.isInfinite else { return 1 }
        let peak = Self.peak(of: probe)
        return min(max(peak, 1), Self.maxHeadroom)
    }

    /// Maximum of R, G and B over `image`, in extended linear sRGB.
    static func peak(of image: CIImage) -> CGFloat {
        let f = CIFilter.areaMaximum()
        f.inputImage = image
        f.extent = image.extent
        guard let out = f.outputImage else { return 1 }
        var px = [Float](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        Renderer.sharedContext.render(out, toBitmap: &px, rowBytes: 16,
                                      bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        let m = max(px[0], px[1], px[2])
        return m.isFinite ? CGFloat(m) : 1
    }
}

// MARK: - Presets

extension RawSettings {
    /// This photo's settings with a preset's portion merged in. The preset replaces boost, tone
    /// mapping and extended range (nil in the preset means automatic); white balance, noise
    /// reduction and everything else stay the photo's own.
    public func applyingPreset(_ portion: RawSettings) -> RawSettings {
        var r = self
        r.boostAmount = portion.boostAmount
        r.localToneMapAmount = portion.localToneMapAmount
        r.extendedDynamicRangeAmount = portion.extendedDynamicRangeAmount
        return r
    }
}
