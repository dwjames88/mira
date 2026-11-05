import CoreGraphics
import Foundation
import MiraCore

/// The aspect crop as pure geometry. Rotation-invariant: the crop is defined on the upright frame, along its long
/// axis, so the finder (upright) and the saved photo (upright by its capture angle) cut the same pixels.
public enum CaptureCrop {
    /// The centred crop of a frame of `frameSize` (any orientation) whose long:short ratio is `aspect`'s, oriented
    /// along the frame's long axis. Normalized 0...1, TOP-LEFT origin. A frame already of that shape gives the whole
    /// rect; a frame less elongated than the aspect loses its long sides' share, a more elongated one its short sides'.
    public static func cropRect(frameSize: CGSize, aspect: CaptureAspect) -> CGRect {
        let whole = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard frameSize.width > 0, frameSize.height > 0, frameSize.width.isFinite, frameSize.height.isFinite else { return whole }
        let landscape = frameSize.width >= frameSize.height
        let long = Double(landscape ? frameSize.width : frameSize.height)
        let short = Double(landscape ? frameSize.height : frameSize.width)
        let have = long / short, want = aspect.longOverShort
        var longFraction = 1.0, shortFraction = 1.0
        if abs(have - want) < 1e-9 { return whole }
        if have > want { longFraction = want / have } else { shortFraction = have / want }
        let w = landscape ? longFraction : shortFraction
        let h = landscape ? shortFraction : longFraction
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// The recipe crop for a saved photo, nil when no crop is wanted (`.fourThree`).
    /// - Parameters:
    ///   - sensorSize: the photo's pixel size in sensor orientation (`photoDimensions`: landscape on an iPhone).
    ///   - rotationAngle: degrees the photo is turned clockwise to be upright (`videoRotationAngleForHorizonLevelCapture`).
    public static func recipeCrop(sensorSize: PixelSize, rotationAngle: Double, aspect: CaptureAspect) -> (rect: CropRect, aspectID: String)? {
        guard aspect != .fourThree else { return nil }
        let sensor = CGSize(width: sensorSize.width, height: sensorSize.height)
        let upright = FinderGeometry.uprightSize(sensorSize: sensor, rotationAngle: rotationAngle)
        let rect = cropRect(frameSize: upright, aspect: aspect)
        let portrait = upright.height > upright.width
        let id: String
        switch aspect {
        case .fourThree: return nil
        case .square: id = CropAspect.square
        case .threeTwo, .sixteenNine, .xpan: id = portrait ? CropAspect.swapped(aspect.rawValue) : aspect.rawValue
        }
        return (CropRect(rect), id)
    }
}
