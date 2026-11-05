import Foundation

/// Pixel dimensions (CoreMedia's `CMVideoDimensions` without the import).
public struct PixelSize: Sendable, Hashable, Codable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
    public var pixelCount: Int { width * height }
    public var megapixels: Double { Double(pixelCount) / 1_000_000 }
}

/// What the photo output supports, mirrored from the device.
public struct CaptureCapabilities: Sendable, Equatable {
    public var supportedPhotoDimensions: [PixelSize]
    public var isProRAWSupported: Bool
    public var isShutterSoundSuppressionSupported: Bool
    public var isZeroShutterLagSupported: Bool

    public init(
        supportedPhotoDimensions: [PixelSize] = [],
        isProRAWSupported: Bool = false,
        isShutterSoundSuppressionSupported: Bool = false,
        isZeroShutterLagSupported: Bool = true
    ) {
        self.supportedPhotoDimensions = supportedPhotoDimensions
        self.isProRAWSupported = isProRAWSupported
        self.isShutterSoundSuppressionSupported = isShutterSoundSuppressionSupported
        self.isZeroShutterLagSupported = isZeroShutterLagSupported
    }
}

/// Mirrors `AVCapturePhotoOutput.QualityPrioritization`.
public enum CapturePrioritization: String, Sendable, Equatable, Codable {
    case speed, balanced, quality
}

/// How a capture is made.
public struct CaptureFormat: Sendable, Equatable {
    /// ProRAW DNG plus HEIC (otherwise HEIC only).
    public var useProRAW: Bool
    public var maxDimensions: PixelSize
    public var prioritization: CapturePrioritization
    public var suppressShutterSound: Bool
    public var zeroShutterLag: Bool
    /// The recipe is developed from the DNG (`MiraAdjustment` `rawBase`).
    public var rawBase: Bool

    public init(
        useProRAW: Bool, maxDimensions: PixelSize, prioritization: CapturePrioritization = .balanced,
        suppressShutterSound: Bool, zeroShutterLag: Bool, rawBase: Bool
    ) {
        self.useProRAW = useProRAW
        self.maxDimensions = maxDimensions
        self.prioritization = prioritization
        self.suppressShutterSound = suppressShutterSound
        self.zeroShutterLag = zeroShutterLag
        self.rawBase = rawBase
    }
}

public enum CaptureFormatPolicy {
    /// Roll 1 captures at 12 MP: the largest supported size at or under this many pixels.
    public static let twelveMegapixelLimit = 12_200_000
    public static let fallbackDimensions = PixelSize(width: 4032, height: 3024)

    public static func format(for caps: CaptureCapabilities, settings: CameraSettings) -> CaptureFormat {
        CaptureFormat(
            useProRAW: caps.isProRAWSupported,
            maxDimensions: twelveMegapixelDimensions(in: caps.supportedPhotoDimensions),
            prioritization: .balanced,
            suppressShutterSound: settings.silentShutter && caps.isShutterSoundSuppressionSupported,
            zeroShutterLag: caps.isZeroShutterLagSupported,
            rawBase: caps.isProRAWSupported
        )
    }

    /// Largest dimensions with at most 12.2 MP (4032 x 3024 when offered); the smallest if all are bigger.
    static func twelveMegapixelDimensions(in sizes: [PixelSize]) -> PixelSize {
        guard !sizes.isEmpty else { return fallbackDimensions }
        let fitting = sizes.filter { $0.pixelCount <= twelveMegapixelLimit }
        if let best = fitting.max(by: { $0.pixelCount < $1.pixelCount }) {
            return fitting.contains(fallbackDimensions) && best.pixelCount == fallbackDimensions.pixelCount
                ? fallbackDimensions : best
        }
        return sizes.min { $0.pixelCount < $1.pixelCount } ?? fallbackDimensions
    }
}
