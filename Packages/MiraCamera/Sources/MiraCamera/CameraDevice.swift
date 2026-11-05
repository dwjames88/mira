#if os(iOS)
import CoreLocation
import Foundation
import MiraCameraKit

/// The camera as the model drives it: `CaptureDeviceControlling` plus lifecycle, capture and the event streams.
/// `CaptureController` is the real one, `FakeCaptureDevice` the simulator and snapshot stand-in.
/// Each stream has one consumer.
public protocol CameraDevice: CaptureDeviceControlling {
    func start() async
    func stop() async
    /// Applies the settings to the outputs and returns the capture format they resolve to.
    func configure(settings: CameraSettings) async -> CaptureFormat
    func capture(format: CaptureFormat, location: CLLocation?) async throws -> CapturedFrame
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
