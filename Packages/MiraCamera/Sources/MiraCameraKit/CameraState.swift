import Foundation

/// Why the capture session was interrupted (mirrors `AVCaptureSession.InterruptionReason` without importing AVFoundation).
public enum CameraInterruption: String, Sendable, Equatable, Codable, CaseIterable {
    case videoDeviceInUseByAnotherClient
    /// Unused by Mira (the camera records no audio), kept so the mapping from AVFoundation is total.
    case audioDeviceInUse
    case videoDeviceNotAvailableInBackground
    case videoDeviceNotAvailableWithMultipleForegroundApps
    case videoDeviceNotAvailableDueToSystemPressure
    case sensitiveContentMitigation
    case unknown

    /// Mono caps copy for the viewfinder.
    public var displayText: String {
        switch self {
        case .videoDeviceInUseByAnotherClient: "CAMERA IN USE BY ANOTHER APP"
        case .audioDeviceInUse: "MICROPHONE IN USE"
        case .videoDeviceNotAvailableInBackground: "CAMERA UNAVAILABLE IN BACKGROUND"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: "CAMERA UNAVAILABLE WITH MULTIPLE APPS"
        case .videoDeviceNotAvailableDueToSystemPressure: "CAMERA PAUSED · DEVICE TOO HOT"
        case .sensitiveContentMitigation: "CAMERA PAUSED · SENSITIVE CONTENT"
        case .unknown: "CAMERA INTERRUPTED"
        }
    }
}

/// The session lifecycle as seen by the UI.
public enum CameraState: Sendable, Equatable {
    case idle
    case starting
    case running
    /// `n` captures are in flight.
    case capturing(Int)
    case interrupted(CameraInterruption)
    case failed(String)
}

/// Inputs to the `CameraState` machine.
public enum CameraEvent: Sendable, Equatable {
    /// Start (or retry after a failure).
    case start
    /// The session reported it is running (also after an interruption ends).
    case sessionStarted
    case stop
    case captureStarted
    case captureFinished
    case interruptionBegan(CameraInterruption)
    case interruptionEnded
    case runtimeError(String)
}

extension CameraState {
    /// Applies an event. Events that make no sense in the current state are ignored.
    public mutating func handle(_ event: CameraEvent) {
        if event == .stop {
            self = .idle
            return
        }
        switch (self, event) {
        case (.idle, .start), (.failed, .start):
            self = .starting
        case (.starting, .sessionStarted):
            self = .running
        case (.starting, .interruptionBegan(let r)), (.running, .interruptionBegan(let r)),
             (.capturing, .interruptionBegan(let r)), (.interrupted, .interruptionBegan(let r)):
            // In-flight captures are the platform layer's to resolve; the state only reports the pause.
            self = .interrupted(r)
        case (.interrupted, .interruptionEnded):
            self = .running
        case (.interrupted, .sessionStarted):
            self = .running
        case (.running, .captureStarted):
            self = .capturing(1)
        case (.capturing(let n), .captureStarted):
            self = .capturing(n + 1)
        case (.capturing(let n), .captureFinished):
            self = n > 1 ? .capturing(n - 1) : .running
        case (.starting, .runtimeError(let m)), (.running, .runtimeError(let m)),
             (.capturing, .runtimeError(let m)), (.interrupted, .runtimeError(let m)):
            self = .failed(m)
        default:
            break
        }
    }

    /// True when a capture may begin (the session is delivering frames).
    public var canCapture: Bool {
        switch self {
        case .running, .capturing: true
        default: false
        }
    }

    /// Captures in flight.
    public var inFlightCount: Int {
        if case .capturing(let n) = self { return n }
        return 0
    }

    /// Mono caps status copy, nil when there is nothing to say.
    public var statusText: String? {
        switch self {
        case .interrupted(let r): r.displayText
        case .failed: "CAMERA FAILED · TAP TO RETRY"
        default: nil
        }
    }
}
