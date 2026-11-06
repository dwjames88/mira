import Foundation

/// The interface orientation of the scene the finder is in, independent of UIKit so the mapping can be tested.
public enum PreviewOrientation: String, Sendable, CaseIterable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight

    /// The degrees a back camera's sensor-orientation buffer is turned clockwise to be upright in this interface
    /// orientation (what `RotationCoordinator.videoRotationAngleForHorizonLevelPreview` reports): portrait 90,
    /// landscapeRight 0, landscapeLeft 180, portraitUpsideDown 270.
    public var previewRotationAngle: Double {
        switch self {
        case .portrait: 90
        case .landscapeRight: 0
        case .landscapeLeft: 180
        case .portraitUpsideDown: 270
        }
    }
}
