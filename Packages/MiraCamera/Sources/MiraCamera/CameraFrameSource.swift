#if os(iOS)
import AVFoundation
import CoreImage
import CoreLocation
import CoreMedia
import Foundation
import ImageIO
import MiraCameraKit
import MiraCore
import Synchronization
import UniformTypeIdentifiers

// MARK: - Real frames

/// The video data output as a `FrameSource`. It is the sample buffer delegate: `start()` attaches it to the
/// controller (the session itself is started by the controller), `stop()` detaches it.
/// Callbacks arrive on the finder queue; state is behind a `Mutex`, so the class is plainly `Sendable`.
public final class CameraFrameSource: NSObject, FrameSource, AVCaptureVideoDataOutputSampleBufferDelegate, Sendable {
    private struct State {
        var handler: (@Sendable (FinderFrame) -> Void)?
        var angle: Double = 90
        var index = 0
    }

    private let state = Mutex(State())
    private let controller: CaptureController
    /// The finder's delegate queue.
    public let queue = DispatchQueue(label: "com.fieldframes.mira.camera.finder", qos: .userInteractive)

    public init(controller: CaptureController) {
        self.controller = controller
        super.init()
    }

    public func setHandler(_ handler: @escaping @Sendable (FinderFrame) -> Void) {
        state.withLock { $0.handler = handler }
    }

    /// Feed `CaptureController.rotationAngles` here; the default is portrait (90).
    public func setRotationAngle(_ degrees: Double) {
        state.withLock { $0.angle = degrees }
    }

    public func start() {
        Task { [controller, queue, self] in await controller.setFrameDelegate(self, queue: queue) }
    }

    public func stop() {
        Task { [controller] in await controller.clearFrameDelegate() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let (handler, angle, index) = state.withLock { s -> ((@Sendable (FinderFrame) -> Void)?, Double, Int) in
            s.index += 1
            return (s.handler, s.angle, s.index)
        }
        guard let handler else { return }
        // [VERIFY on device: the sample buffer carries an {Exif} attachment with ExposureTime; if not, fall
        // back to the controller's telemetry duration.]
        let exposure = Self.exposureTime(of: sampleBuffer)
        // The CIImage wraps the camera's pixel buffer; the renderer must finish with it before the pool recycles it.
        let image = CIImage(cvPixelBuffer: pixelBuffer).withMiraExposureTime(exposure)
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        handler(FinderFrame(image: image, rotationAngle: angle, exposureTime: exposure, timestamp: time, index: index))
    }

    private static func exposureTime(of sampleBuffer: CMSampleBuffer) -> Double? {
        guard let attachments = CMCopyDictionaryOfAttachments(
            allocator: kCFAllocatorDefault, target: sampleBuffer, attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any]
        else { return nil }
        let properties = Dictionary(uniqueKeysWithValues: attachments.map { (($0.key as CFString), $0.value) })
        return ImageSource.exposureTime(properties: properties)
    }
}

// MARK: - Fake frames (simulator, snapshots)

/// Emits one picture at 30 Hz with a tiny per-frame variation so nothing downstream caches it.
public final class FakeFrameSource: FrameSource, Sendable {
    private struct State {
        var handler: (@Sendable (FinderFrame) -> Void)?
        var timer: DispatchSourceTimer?
        var index = 0
    }

    public static let exposureTime = 1.0 / 125

    private let state = Mutex(State())
    private let queue = DispatchQueue(label: "com.fieldframes.mira.camera.fakefinder", qos: .userInteractive)
    private let picture: CIImage

    /// `fixtureURL` nil (or unreadable) falls back to a generated gradient.
    public init(fixtureURL: URL? = nil) {
        let loaded = fixtureURL.flatMap { ImageSource.loadDecoded(url: $0) }
        picture = loaded ?? FakeFrameSource.generatedPicture()
    }

    public func setHandler(_ handler: @escaping @Sendable (FinderFrame) -> Void) {
        state.withLock { $0.handler = handler }
    }

    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.tick() }
        let previous = state.withLock { s -> DispatchSourceTimer? in
            let old = s.timer
            s.timer = timer
            return old
        }
        previous?.cancel()
        timer.resume()
    }

    public func stop() {
        state.withLock { s -> DispatchSourceTimer? in
            let old = s.timer
            s.timer = nil
            return old
        }?.cancel()
    }

    private func tick() {
        let (handler, index) = state.withLock { s -> ((@Sendable (FinderFrame) -> Void)?, Int) in
            s.index += 1
            return (s.handler, s.index)
        }
        guard let handler else { return }
        // A brightness wobble far below visibility.
        let wobble = 0.0004 * sin(Double(index) * 0.7)
        let varied = picture.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: wobble])
            .cropped(to: picture.extent)
            .withMiraExposureTime(Self.exposureTime)
        handler(FinderFrame(image: varied, rotationAngle: 0, exposureTime: Self.exposureTime,
                            timestamp: ProcessInfo.processInfo.systemUptime, index: index))
    }

    deinit { state.withLock { $0.timer }?.cancel() }

    /// A portrait gradient (3:4) for when no fixture is available.
    static func generatedPicture() -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: 1536, height: 2048)
        let gradient = CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: 0, y: rect.height),
            "inputColor0": CIColor(red: 0.18, green: 0.30, blue: 0.45), "inputColor1": CIColor(red: 0.92, green: 0.72, blue: 0.48),
        ])?.outputImage
        return (gradient ?? CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))).cropped(to: rect)
    }
}

// MARK: - Fake device

/// A `CameraDevice` with no hardware: 16 Pro lenses, canned telemetry, and a capture that writes the fixture
/// picture as a HEIC (JPEG data if the encoder is unavailable), so the simulator flows work end to end.
public actor FakeCaptureDevice: CameraDevice {
    /// iPhone 16 Pro, as in `Tests/MiraCameraKitTests/Fixtures/lenses-16pro.json` [ASSUMPTION: derived, not recorded].
    public static let sixteenPro = LensDescriptor(
        fieldOfViewDegrees: 106.1797, constituentFieldsOfView: [106.1797, 71.5958, 16.4147],
        switchOverZoomFactors: [2, 10], displayZoomMultiplier: 0.5, minZoom: 1, maxZoom: 60, constituentCount: 3)

    public nonisolated let telemetry: AsyncStream<ExposureTelemetry>
    public nonisolated let events: AsyncStream<CameraEvent>
    public nonisolated let readiness: AsyncStream<ShutterReadiness>
    public nonisolated let captureSignals: AsyncStream<CaptureSignal>
    public nonisolated let rotationAngles: AsyncStream<Double>
    public nonisolated let thermalLevels: AsyncStream<FinderThermalLevel>

    private nonisolated let telemetryOut: AsyncStream<ExposureTelemetry>.Continuation
    private nonisolated let eventsOut: AsyncStream<CameraEvent>.Continuation
    private nonisolated let readinessOut: AsyncStream<ShutterReadiness>.Continuation
    private nonisolated let signalsOut: AsyncStream<CaptureSignal>.Continuation
    private nonisolated let rotationOut: AsyncStream<Double>.Continuation
    private nonisolated let thermalOut: AsyncStream<FinderThermalLevel>.Continuation

    private let fixtureURL: URL?
    private var bias = 0.0
    private var zoom = 1.0

    public init(fixtureURL: URL? = nil) {
        self.fixtureURL = fixtureURL
        (telemetry, telemetryOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (events, eventsOut) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (readiness, readinessOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (captureSignals, signalsOut) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (rotationAngles, rotationOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (thermalLevels, thermalOut) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    public func start() async {
        eventsOut.yield(.sessionStarted)
        readinessOut.yield(.ready)
        rotationOut.yield(0)
        thermalOut.yield(.nominal)
        telemetryOut.yield(ExposureTelemetry(offsetEV: 0.3, duration: FakeFrameSource.exposureTime, iso: 64, aperture: 1.78))
    }

    public func stop() async { readinessOut.yield(.sessionNotRunning) }
    public func runDeferredStartWhenNeeded() async {}
    public func setPreviewLayer(_ box: PreviewLayerBox?) async {}

    public func configure(settings: CameraSettings) async -> CaptureFormat {
        CaptureFormatPolicy.format(for: await capabilities(), settings: settings)
    }

    public func capabilities() async -> CaptureCapabilities {
        CaptureCapabilities(supportedPhotoDimensions: [PixelSize(width: 4032, height: 3024)], isProRAWSupported: false,
                            isShutterSoundSuppressionSupported: false, isZeroShutterLagSupported: true)
    }

    public func setExposureBias(_ ev: Double) async -> Double {
        bias = ExposureModel.clamp(ExposureModel.snapToThird(ev), min: ExposureModel.minEV, max: ExposureModel.maxEV)
        telemetryOut.yield(ExposureTelemetry(offsetEV: bias, duration: FakeFrameSource.exposureTime, iso: 64, aperture: 1.78))
        return bias
    }

    public func focusAndMeter(at point: CGPoint, lock: Bool) async {}
    public func unlockFocusAndExposure() async {}
    public func setWhiteBalance(_ state: WhiteBalanceState) async {}
    public func setZoom(_ factor: Double, ramp: Bool) async { zoom = factor }
    public func lenses() async -> [Lens] { LensCatalog.lenses(for: Self.sixteenPro) }

    public func capture(format: CaptureFormat, location: CLLocation?) async throws -> CapturedFrame {
        signalsOut.yield(.shutterClosed)
        let url = fixtureURL
        let frame = try await Task.detached(priority: .userInitiated) { try Self.writeFixture(url) }.value
        return frame
    }

    private nonisolated static func writeFixture(_ fixtureURL: URL?) throws -> CapturedFrame {
        let directory = FileManager.default.temporaryDirectory.appending(path: "MiraCamera", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let context = CIContext()
        let picture = fixtureURL.flatMap { ImageSource.loadDecoded(url: $0) } ?? FakeFrameSource.generatedPicture()
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let cg = context.createCGImage(picture, from: picture.extent, format: .RGBA8, colorSpace: space) else {
            throw CaptureError.failed("The picture could not be rendered")
        }
        let name = UUID().uuidString
        var url = directory.appending(path: "\(name).heic")
        let properties = [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, cg, properties)
            if CGImageDestinationFinalize(destination) { return CapturedFrame(heicURL: url, pixelSize: PixelSize(width: cg.width, height: cg.height), exposureTime: FakeFrameSource.exposureTime) }
        }
        // No HEIC encoder (some simulators): JPEG data under a .jpg name.
        url = directory.appending(path: "\(name).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw CaptureError.failed("The picture could not be encoded")
        }
        CGImageDestinationAddImage(destination, cg, properties)
        guard CGImageDestinationFinalize(destination) else { throw CaptureError.failed("The picture could not be encoded") }
        return CapturedFrame(heicURL: url, pixelSize: PixelSize(width: cg.width, height: cg.height), exposureTime: FakeFrameSource.exposureTime)
    }
}

// MARK: - Backend

/// Chooses the real camera or the fakes.
public enum CameraBackend {
    /// Fake when `MIRA_CAMERA_FAKE=1`, `MIRA_SNAPSHOT=1`, or the device has no back camera (the simulator).
    /// `fixtureURL` is the picture the fakes show and "capture" (a generated gradient when nil).
    public static func make(fixtureURL: URL? = nil) -> (device: any CameraDevice, frames: any FrameSource) {
        if usesFakes {
            return (FakeCaptureDevice(fixtureURL: fixtureURL), FakeFrameSource(fixtureURL: fixtureURL))
        }
        let controller = CaptureController()
        let source = CameraFrameSource(controller: controller)
        // Keep the source's rotation current from the controller's stream.
        let angles = controller.rotationAngles
        Task { [weak source] in
            for await angle in angles { source?.setRotationAngle(angle) }
        }
        return (controller, source)
    }

    public static var usesFakes: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["MIRA_CAMERA_FAKE"] == "1" || env["MIRA_SNAPSHOT"] == "1" { return true }
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        return !types.contains { AVCaptureDevice.default($0, for: .video, position: .back) != nil }
    }
}
#endif
