import Foundation
import ImageIO

/// A snapshot of the live exposure, published by the capture controller (KVO on the device).
public struct ExposureTelemetry: Sendable, Equatable {
    /// `exposureTargetOffset`: how far the metered scene is from the target, in EV.
    public var offsetEV: Double
    /// Exposure duration in seconds.
    public var duration: Double
    public var iso: Double
    /// Lens aperture (f-number).
    public var aperture: Double
    public var isAdjustingFocus: Bool

    public init(offsetEV: Double = 0, duration: Double = 0, iso: Double = 0, aperture: Double = 0, isAdjustingFocus: Bool = false) {
        self.offsetEV = offsetEV
        self.duration = duration
        self.iso = iso
        self.aperture = aperture
        self.isAdjustingFocus = isAdjustingFocus
    }
}

/// Signals from a capture in flight (for the ink blink and the haptic).
public enum CaptureSignal: Sendable, Equatable {
    /// The shutter closed (`willCapturePhotoFor`).
    case shutterClosed
}

/// Why a capture produced no frame.
public enum CaptureError: Error, Sendable, Equatable {
    case sessionNotRunning
    case noCamera
    case noProcessedPhoto
    case failed(String)

    /// Mono caps copy for the viewfinder.
    public var monoCopy: String {
        switch self {
        case .sessionNotRunning: "CAMERA NOT RUNNING"
        case .noCamera: "NO CAMERA"
        case .noProcessedPhoto, .failed: "FRAME LOST · TRY AGAIN"
        }
    }
}

/// White balance gains (the device's RGB gains) and their clamping.
public struct WhiteBalanceGains: Sendable, Equatable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Each channel limited to 1...`maxGain` (the device raises an exception outside that range).
    public func clamped(maxGain: Double) -> WhiteBalanceGains {
        let hi = max(1, maxGain)
        func c(_ v: Double) -> Double { v.isFinite ? min(max(v, 1), hi) : 1 }
        return WhiteBalanceGains(red: c(red), green: c(green), blue: c(blue))
    }
}

/// GPS metadata for a capture, as an ImageIO dictionary.
public enum LocationMetadata {
    public static func gpsDictionary(
        latitude: Double, longitude: Double, altitude: Double?, timestamp: Date, horizontalAccuracy: Double? = nil
    ) -> [String: Any] {
        var gps: [String: Any] = [
            kCGImagePropertyGPSLatitude as String: abs(latitude),
            kCGImagePropertyGPSLatitudeRef as String: latitude >= 0 ? "N" : "S",
            kCGImagePropertyGPSLongitude as String: abs(longitude),
            kCGImagePropertyGPSLongitudeRef as String: longitude >= 0 ? "E" : "W",
        ]
        if let altitude {
            gps[kCGImagePropertyGPSAltitude as String] = abs(altitude)
            gps[kCGImagePropertyGPSAltitudeRef as String] = altitude >= 0 ? 0 : 1
        }
        if let horizontalAccuracy, horizontalAccuracy >= 0 {
            gps[kCGImagePropertyGPSHPositioningError as String] = horizontalAccuracy
        }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: timestamp)
        gps[kCGImagePropertyGPSDateStamp as String] = String(
            format: "%04d:%02d:%02d", parts.year ?? 1970, parts.month ?? 1, parts.day ?? 1)
        gps[kCGImagePropertyGPSTimeStamp as String] = String(
            format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        return gps
    }
}

extension LensDescriptor {
    /// Builds a descriptor from raw device values. Constituent fields of view are kept only when they agree
    /// with the switch-over zoom factors (within 20%); a constituent's active format can be cropped or
    /// binned differently from the virtual device, and then deriving them from the zoom factors is safer.
    public static func make(
        fieldOfView: Double, constituentFieldsOfView: [Double], switchOverZoomFactors: [Double],
        displayZoomMultiplier: Double, minZoom: Double, maxZoom: Double, constituentCount: Int
    ) -> LensDescriptor {
        let fovs = constituentFieldsOfView.count == constituentCount && consistent(constituentFieldsOfView, switchOverZoomFactors)
            ? constituentFieldsOfView : []
        return LensDescriptor(
            fieldOfViewDegrees: fieldOfView, constituentFieldsOfView: fovs,
            switchOverZoomFactors: switchOverZoomFactors, displayZoomMultiplier: displayZoomMultiplier,
            minZoom: minZoom, maxZoom: maxZoom, constituentCount: max(1, constituentCount))
    }

    static func consistent(_ fovs: [Double], _ switchOver: [Double]) -> Bool {
        guard let first = fovs.first, first > 0, fovs.allSatisfy({ $0 > 0 && $0 < 180 }) else { return false }
        guard switchOver.count >= fovs.count - 1 else { return false }
        let base = tan(first * .pi / 360)
        for (i, fov) in fovs.enumerated().dropFirst() {
            let ratio = base / tan(fov * .pi / 360)
            let expected = switchOver[i - 1]
            guard expected > 0, abs(ratio - expected) / expected <= 0.2 else { return false }
        }
        return true
    }
}
