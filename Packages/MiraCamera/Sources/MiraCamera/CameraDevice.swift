#if os(iOS)
import CoreLocation
import Foundation
import MiraCameraKit
import QuartzCore

/// A layer handed across actors without retaining it. Only the main actor creates it; the session queue only passes
/// it to `AVCaptureDevice.RotationCoordinator`. `@unchecked Sendable`: the layer is held weakly and only passed on.
public struct PreviewLayerBox: @unchecked Sendable {
    public weak var layer: CALayer?
    /// The interface orientation of the layer's window scene, when known (the fakes derive their angle from it).
    public var orientation: PreviewOrientation?
    public init(_ layer: CALayer?, orientation: PreviewOrientation? = nil) {
        self.layer = layer
        self.orientation = orientation
    }
}

/// The camera as the model drives it: `CaptureDeviceControlling` plus lifecycle, capture and the event streams.
/// `CaptureController` is the real one, `FakeCaptureDevice` the simulator and snapshot stand-in.
/// Each stream has one consumer.
public protocol CameraDevice: CaptureDeviceControlling {
    func start() async
    func stop() async
    /// Applies the settings to the outputs and returns the capture format they resolve to.
    func configure(settings: CameraSettings) async -> CaptureFormat
    func capture(format: CaptureFormat, location: CLLocation?) async throws -> CapturedFrame
    /// The layer that displays the finder, once it is in a window (nil when it leaves). The rotation coordinator
    /// reports 0 degrees without a layer in a view hierarchy, so the preview angle needs it.
    func setPreviewLayer(_ box: PreviewLayerBox?) async
    /// iOS 26+: call after the first finder frame is on screen.
    func runDeferredStartWhenNeeded() async

    nonisolated var telemetry: AsyncStream<ExposureTelemetry> { get }
    nonisolated var events: AsyncStream<CameraEvent> { get }
    nonisolated var readiness: AsyncStream<ShutterReadiness> { get }
    nonisolated var captureSignals: AsyncStream<CaptureSignal> { get }
    /// Degrees for the finder (`videoRotationAngleForHorizonLevelPreview`).
    nonisolated var rotationAngles: AsyncStream<Double> { get }
    nonisolated var thermalLevels: AsyncStream<FinderThermalLevel> { get }
}
#endif
