import Foundation

/// The shutter's availability (mirrors `AVCapturePhotoOutputReadinessCoordinator`).
public enum ShutterReadiness: Sendable, Equatable {
    case ready
    case notReadyMomentarily
    case notReadyWaitingForCapture
    case notReadyWaitingForProcessing
    case sessionNotRunning

    /// Only these two dim the shutter; the others are brief and the button stays lit.
    public var dimsShutter: Bool {
        switch self {
        case .notReadyWaitingForProcessing, .sessionNotRunning: true
        default: false
        }
    }

    /// Whether a press should start a capture. Responsive capture accepts a press while a previous
    /// capture is still in flight; a momentary stall does not.
    public var acceptsPress: Bool {
        switch self {
        case .ready, .notReadyWaitingForCapture: true
        default: false
        }
    }
}

/// Phases of a hardware shutter event (volume button, Action button, Camera Control).
public enum HardwareShutterPhase: Sendable, Equatable {
    case began, ended, cancelled
}

public enum HardwareShutter {
    /// Fire on release only, so a press that turns into a cancel (or a system gesture) takes no photo.
    public static func shouldFire(phase: HardwareShutterPhase) -> Bool { phase == .ended }
}
