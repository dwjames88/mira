#if os(iOS)
import AVFoundation
import CoreLocation
import CoreMedia
import Foundation
import MiraCameraKit
import Synchronization

// MARK: - Callback hubs (nonisolated, Sendable)

/// Latest exposure values, merged from several KVO callbacks and yielded as one snapshot.
final class TelemetryHub: Sendable {
    private let state = Mutex(ExposureTelemetry())
    let continuation: AsyncStream<ExposureTelemetry>.Continuation

    init(_ continuation: AsyncStream<ExposureTelemetry>.Continuation) { self.continuation = continuation }

    func update(_ change: (inout ExposureTelemetry) -> Void) {
        let snapshot = state.withLock { value -> ExposureTelemetry in
            change(&value)
            return value
        }
        continuation.yield(snapshot)
    }
}

/// Removes its notification observers when the controller goes away. `@unchecked Sendable`: the token list is behind the lock.
final class ObserverTokens: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [any NSObjectProtocol] = []
    func add(_ token: any NSObjectProtocol) { lock.withLock { tokens.append(token) } }
    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}

/// `AVCapturePhotoOutputReadinessCoordinatorDelegate` as a stream. The coordinator holds its delegate weakly,
/// so the controller keeps this alive.
final class ReadinessBridge: NSObject, AVCapturePhotoOutputReadinessCoordinatorDelegate, Sendable {
    let continuation: AsyncStream<ShutterReadiness>.Continuation
    init(_ continuation: AsyncStream<ShutterReadiness>.Continuation) { self.continuation = continuation }

    func readinessCoordinator(
        _ coordinator: AVCapturePhotoOutputReadinessCoordinator, captureReadinessDidChange captureReadiness: AVCapturePhotoOutput.CaptureReadiness
    ) {
        continuation.yield(Self.map(captureReadiness))
    }

    static func map(_ r: AVCapturePhotoOutput.CaptureReadiness) -> ShutterReadiness {
        switch r {
        case .ready: .ready
        case .notReadyMomentarily: .notReadyMomentarily
        case .notReadyWaitingForCapture: .notReadyWaitingForCapture
        case .notReadyWaitingForProcessing: .notReadyWaitingForProcessing
        case .sessionNotRunning: .sessionNotRunning
        @unknown default: .notReadyMomentarily
        }
    }
}

// MARK: - Controller

/// Owns the capture session. An actor whose executor is the session queue, so every `AVCaptureSession` and
/// `AVCaptureDevice` call runs on the one serial queue AVFoundation expects, and never on the main thread.
///
/// AVFoundation callbacks (KVO, notifications, photo and readiness delegates) are built in `nonisolated`
/// statics and capture only `Sendable` continuations; they never touch actor state. The few that need the
/// actor hop with a `Task`.
public actor CaptureController: CameraDevice {
    public static let sessionQueueLabel = "com.fieldframes.mira.camera.session"

    nonisolated let sessionQueue = DispatchSerialQueue(label: CaptureController.sessionQueueLabel, qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { sessionQueue.asUnownedSerialExecutor() }

    // Streams (one consumer each).
    public nonisolated let telemetry: AsyncStream<ExposureTelemetry>
    public nonisolated let events: AsyncStream<CameraEvent>
    public nonisolated let readiness: AsyncStream<ShutterReadiness>
    public nonisolated let captureSignals: AsyncStream<CaptureSignal>
    public nonisolated let rotationAngles: AsyncStream<Double>
    public nonisolated let thermalLevels: AsyncStream<FinderThermalLevel>

    private nonisolated let telemetryHub: TelemetryHub
    private nonisolated let eventsOut: AsyncStream<CameraEvent>.Continuation
    private nonisolated let readinessBridge: ReadinessBridge
    private nonisolated let signalsOut: AsyncStream<CaptureSignal>.Continuation
    private nonisolated let rotationOut: AsyncStream<Double>.Continuation
    private nonisolated let thermalOut: AsyncStream<FinderThermalLevel>.Continuation
    private nonisolated let notificationTokens = ObserverTokens()

    // Session state (isolated to the session queue).
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var device: AVCaptureDevice?
    private var readinessCoordinator: AVCapturePhotoOutputReadinessCoordinator?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var observations: [NSKeyValueObservation] = []
    private var rotationObservation: NSKeyValueObservation?
    private var previewLayer: PreviewLayerBox?
    private var configured = false
    private var wantsRunning = false

    public init() {
        let (telemetry, telemetryOut) = AsyncStream<ExposureTelemetry>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (events, eventsOut) = AsyncStream<CameraEvent>.makeStream(bufferingPolicy: .unbounded)
        let (readiness, readinessOut) = AsyncStream<ShutterReadiness>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (signals, signalsOut) = AsyncStream<CaptureSignal>.makeStream(bufferingPolicy: .unbounded)
        let (rotation, rotationOut) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let (thermal, thermalOut) = AsyncStream<FinderThermalLevel>.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.telemetry = telemetry
        self.events = events
        self.readiness = readiness
        self.captureSignals = signals
        self.rotationAngles = rotation
        self.thermalLevels = thermal
        self.telemetryHub = TelemetryHub(telemetryOut)
        self.eventsOut = eventsOut
        self.readinessBridge = ReadinessBridge(readinessOut)
        self.signalsOut = signalsOut
        self.rotationOut = rotationOut
        self.thermalOut = thermalOut
    }

    /// Ends every stream, so the model's consumer tasks finish with the controller instead of waiting forever.
    deinit {
        telemetryHub.continuation.finish()
        eventsOut.finish()
        readinessBridge.continuation.finish()
        signalsOut.finish()
        rotationOut.finish()
        thermalOut.finish()
    }

    // MARK: Lifecycle

    /// Starts the session (configuring it on first use). Never call from the main thread's own work:
    /// `await` it, it runs on the session queue.
    public func start() async {
        wantsRunning = true
        if !configured { configureSession() }
        guard configured, !session.isRunning else { return }
        session.startRunning()
        if !session.isRunning { eventsOut.yield(.runtimeError("The camera did not start")) }
    }

    public func stop() async {
        wantsRunning = false
        if session.isRunning { session.stopRunning() }
    }

    /// iOS 26+: runs the work `automaticallyRunsDeferredStart = false` postponed. Call after the first finder
    /// frame has been presented. [VERIFY on device: name and behavior on the iOS 26/27 SDK.]
    public func runDeferredStartWhenNeeded() async {
        if #available(iOS 26, *) { session.runDeferredStartWhenNeeded() }
    }

    /// Hands the video frames to the finder. `delegate` is called on `queue`.
    public func setFrameDelegate(_ delegate: AVCaptureVideoDataOutputSampleBufferDelegate & Sendable, queue: DispatchQueue) {
        videoOutput.setSampleBufferDelegate(delegate, queue: queue)
    }

    public func clearFrameDelegate() {
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
    }

    private func configureSession() {
        guard let device = Self.backCamera() else {
            eventsOut.yield(.runtimeError("No camera"))
            return
        }
        guard let input = try? AVCaptureDeviceInput(device: device) else {
            eventsOut.yield(.runtimeError("The camera is not available"))
            return
        }
        session.beginConfiguration()
        session.sessionPreset = .photo
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            eventsOut.yield(.runtimeError("The camera is not available"))
            return
        }
        session.addInput(input)
        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
        // [VERIFY on device: 32BGRA vs 420f (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange): which renders
        // cheaper through Core Image on A18. BGRA is the default here; Apple gives no recommendation.]
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if #available(iOS 26, *) { session.automaticallyRunsDeferredStart = false }
        session.commitConfiguration()

        self.device = device
        readinessCoordinator = AVCapturePhotoOutputReadinessCoordinator(photoOutput: photoOutput)
        readinessCoordinator?.delegate = readinessBridge
        observations = Self.makeObservations(device: device, telemetry: telemetryHub, thermalOut: thermalOut)
        rebuildRotationCoordinator()
        installNotificationObservers()
        configured = true
    }

    /// The finder's layer is in a window (or left it). Rebuilds the rotation coordinator around it.
    public func setPreviewLayer(_ box: PreviewLayerBox?) async {
        previewLayer = box
        if configured { rebuildRotationCoordinator() }
    }

    /// `previewLayer: nil` makes the coordinator answer 0 degrees for the preview ("if a layer was not specified at
    /// initialization, the layer is not in a view hierarchy ..."), so the preview angle is only streamed while a layer
    /// is set; until then the frame source keeps its portrait default. The capture angle does not need the layer.
    private func rebuildRotationCoordinator() {
        rotationObservation = nil
        guard let device else { return }
        let layer = previewLayer?.layer
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
        rotationCoordinator = coordinator
        if layer != nil { rotationObservation = Self.observePreviewAngle(coordinator, rotationOut: rotationOut) }
    }

    private nonisolated static func observePreviewAngle(
        _ coordinator: AVCaptureDevice.RotationCoordinator, rotationOut: AsyncStream<Double>.Continuation
    ) -> NSKeyValueObservation {
        coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { coordinator, _ in
            rotationOut.yield(Double(coordinator.videoRotationAngleForHorizonLevelPreview))
        }
    }

    private static func backCamera() -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) { return device }
        }
        return nil
    }

    // MARK: Format

    /// Enables ProRAW, 12 MP, `.balanced`, zero shutter lag and responsive capture as the settings and device allow.
    public func configure(settings: CameraSettings) async -> CaptureFormat {
        if !configured { configureSession() }
        let caps = currentCapabilities()
        let format = CaptureFormatPolicy.format(for: caps, settings: settings)
        guard configured else { return format }
        session.beginConfiguration()
        if photoOutput.isAppleProRAWSupported { photoOutput.isAppleProRAWEnabled = format.useProRAW }
        photoOutput.maxPhotoDimensions = CMVideoDimensions(width: Int32(format.maxDimensions.width), height: Int32(format.maxDimensions.height))
        photoOutput.maxPhotoQualityPrioritization = Self.avPrioritization(format.prioritization)
        if photoOutput.isZeroShutterLagSupported { photoOutput.isZeroShutterLagEnabled = format.zeroShutterLag }
        // [VERIFY on device: responsive capture may be unsupported together with ProRAW or at some sizes.]
        if photoOutput.isResponsiveCaptureSupported { photoOutput.isResponsiveCaptureEnabled = true }
        session.commitConfiguration()
        return format
    }

    public func capabilities() async -> CaptureCapabilities {
        if !configured { configureSession() }
        return currentCapabilities()
    }

    private func currentCapabilities() -> CaptureCapabilities {
        guard let device else { return CaptureCapabilities() }
        let sizes = device.activeFormat.supportedMaxPhotoDimensions.map { PixelSize(width: Int($0.width), height: Int($0.height)) }
        return CaptureCapabilities(
            supportedPhotoDimensions: sizes,
            isProRAWSupported: photoOutput.isAppleProRAWSupported,
            isShutterSoundSuppressionSupported: photoOutput.isShutterSoundSuppressionSupported,
            isZeroShutterLagSupported: photoOutput.isZeroShutterLagSupported)
    }

    private static func avPrioritization(_ p: CapturePrioritization) -> AVCapturePhotoOutput.QualityPrioritization {
        switch p {
        case .speed: .speed
        case .balanced: .balanced
        case .quality: .quality
        }
    }

    // MARK: Exposure, focus, white balance

    public func setExposureBias(_ ev: Double) async -> Double {
        guard let device else { return 0 }
        let clamped = ExposureModel.clamp(
            ExposureModel.snapToThird(ev), min: Double(device.minExposureTargetBias), max: Double(device.maxExposureTargetBias))
        guard (try? device.lockForConfiguration()) != nil else { return Double(device.exposureTargetBias) }
        device.setExposureTargetBias(Float(clamped), completionHandler: nil)
        device.unlockForConfiguration()
        return clamped
    }

    /// `point` is in the device's coordinate space (0...1, landscape sensor orientation, the space
    /// `AVCaptureVideoPreviewLayer.captureDevicePointConverted(fromLayerPoint:)` produces).
    /// With `lock`, focus and exposure are held once focusing settles (AF/AE lock).
    public func focusAndMeter(at point: CGPoint, lock: Bool) async {
        guard let device else { return }
        let p = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
            device.focusPointOfInterest = p
            device.focusMode = .autoFocus
        }
        if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposurePointOfInterest = p
            device.exposureMode = .continuousAutoExposure
        }
        device.unlockForConfiguration()
        guard lock else { return }
        await waitForFocus(device)
        guard (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
        if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
        device.unlockForConfiguration()
    }

    /// Waits (at most 2 s) for the focus motor to settle. Suspends on the session queue, which stays free.
    private func waitForFocus(_ device: AVCaptureDevice) async {
        try? await Task.sleep(for: .milliseconds(120))   // let the adjustment begin
        for _ in 0..<36 where device.isAdjustingFocus {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    public func unlockFocusAndExposure() async {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.unlockForConfiguration()
    }

    public func setWhiteBalance(_ state: WhiteBalanceState) async {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        guard let kelvin = state.kelvin else {
            if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { device.whiteBalanceMode = .continuousAutoWhiteBalance }
            return
        }
        guard device.isLockingWhiteBalanceWithCustomDeviceGainsSupported else { return }
        let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(kelvin), tint: 0)
        let gains = device.deviceWhiteBalanceGains(for: values)
        let clamped = WhiteBalanceGains(red: Double(gains.redGain), green: Double(gains.greenGain), blue: Double(gains.blueGain))
            .clamped(maxGain: Double(device.maxWhiteBalanceGain))
        device.setWhiteBalanceModeLocked(
            with: AVCaptureDevice.WhiteBalanceGains(
                redGain: Float(clamped.red), greenGain: Float(clamped.green), blueGain: Float(clamped.blue)),
            completionHandler: nil)
    }

    // MARK: Lenses and zoom

    public func lenses() async -> [Lens] {
        if !configured { configureSession() }
        guard let descriptor = lensDescriptor() else { return [] }
        return LensCatalog.lenses(for: descriptor)
    }

    /// The device as a `LensDescriptor` (for the pinch readout through `LensCatalog.equivalent(atZoom:)`).
    public func lensDescriptor() -> LensDescriptor? {
        guard let device else { return nil }
        // [VERIFY on device: `activeFormat.videoFieldOfView` is the widest camera's horizontal FOV at zoom 1,
        // and each constituent's FOV agrees with the switch-over factors (otherwise `make` derives them).]
        let constituents = device.constituentDevices.map { Double($0.activeFormat.videoFieldOfView) }.sorted(by: >)
        return LensDescriptor.make(
            fieldOfView: Double(device.activeFormat.videoFieldOfView),
            constituentFieldsOfView: constituents,
            switchOverZoomFactors: device.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue },
            displayZoomMultiplier: Double(device.displayVideoZoomFactorMultiplier),
            minZoom: Double(device.minAvailableVideoZoomFactor),
            maxZoom: Double(min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor)),
            constituentCount: max(1, device.constituentDevices.count))
    }

    /// `ramp` glides (focal-length chips); otherwise the factor is set directly (pinch).
    public func setZoom(_ factor: Double, ramp: Bool) async {
        guard let device, (try? device.lockForConfiguration()) != nil else { return }
        defer { device.unlockForConfiguration() }
        let z = CGFloat(min(max(factor, Double(device.minAvailableVideoZoomFactor)),
                            Double(min(device.maxAvailableVideoZoomFactor, device.activeFormat.videoMaxZoomFactor))))
        if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
        if ramp {
            device.ramp(toVideoZoomFactor: z, withRate: 6)
        } else {
            device.videoZoomFactor = z
        }
    }

    // MARK: Capture

    /// One photo. The processed HEIC (and the ProRAW DNG when enabled) are written to the temp folder.
    /// `location` is written into the metadata when given; asking for permission is the UI's job.
    public func capture(format: CaptureFormat, location: CLLocation? = nil) async throws -> CapturedFrame {
        guard configured else { throw CaptureError.noCamera }
        guard session.isRunning else { throw CaptureError.sessionNotRunning }
        let settings = makePhotoSettings(format: format)
        let snapshot = location.map {
            LocationSnapshot(
                latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                altitude: $0.verticalAccuracy >= 0 ? $0.altitude : nil, timestamp: $0.timestamp,
                horizontalAccuracy: $0.horizontalAccuracy)
        }
        let delegate = PhotoCaptureDelegate(signals: signalsOut, location: snapshot)
        var angle = 90.0
        if let connection = photoOutput.connection(with: .video) {
            angle = Double(connection.videoRotationAngle)
            if let wanted = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture, connection.isVideoRotationAngleSupported(wanted) {
                connection.videoRotationAngle = wanted
                angle = Double(wanted)
            }
        }
        readinessCoordinator?.startTrackingCaptureRequest(using: settings)
        var frame: CapturedFrame = try await withCheckedThrowingContinuation { continuation in
            delegate.begin(continuation)
            photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
        frame.rotationAngle = angle
        return frame
    }

    private func makePhotoSettings(format: CaptureFormat) -> AVCapturePhotoSettings {
        let settings: AVCapturePhotoSettings
        let proRAW = photoOutput.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
        if format.useProRAW, photoOutput.isAppleProRAWEnabled, let proRAW {
            settings = AVCapturePhotoSettings(
                rawPixelFormatType: proRAW, rawFileType: .dng,
                processedFormat: [AVVideoCodecKey: AVVideoCodecType.hevc], processedFileType: .heic)
        } else if photoOutput.availablePhotoCodecTypes.contains(.hevc) {
            settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        } else {
            settings = AVCapturePhotoSettings()
        }
        settings.maxPhotoDimensions = CMVideoDimensions(width: Int32(format.maxDimensions.width), height: Int32(format.maxDimensions.height))
        settings.photoQualityPrioritization = Self.avPrioritization(format.prioritization)
        settings.flashMode = .off
        if format.suppressShutterSound, photoOutput.isShutterSoundSuppressionSupported {
            settings.isShutterSoundSuppressionEnabled = true
        }
        return settings
    }

    // MARK: Interruptions

    private func installNotificationObservers() {
        let tokens = Self.makeNotificationObservers(session: session, events: eventsOut) { [weak self] in
            Task { await self?.restartAfterMediaServicesReset() }
        }
        for token in tokens { notificationTokens.add(token) }
    }

    private func restartAfterMediaServicesReset() {
        guard wantsRunning, !session.isRunning else { return }
        session.startRunning()
    }

    // MARK: Callback builders (nonisolated: nothing here touches actor state)

    private nonisolated static func makeObservations(
        device: AVCaptureDevice, telemetry hub: TelemetryHub, thermalOut: AsyncStream<FinderThermalLevel>.Continuation
    ) -> [NSKeyValueObservation] {
        var tokens: [NSKeyValueObservation] = []
        tokens.append(device.observe(\.exposureTargetOffset, options: [.initial, .new]) { device, _ in
            let v = Double(device.exposureTargetOffset)
            hub.update { $0.offsetEV = v }
        })
        tokens.append(device.observe(\.exposureDuration, options: [.initial, .new]) { device, _ in
            let v = device.exposureDuration.seconds
            hub.update { $0.duration = v.isFinite ? v : 0 }
        })
        tokens.append(device.observe(\.iso, options: [.initial, .new]) { device, _ in
            let v = Double(device.iso)
            hub.update { $0.iso = v }
        })
        tokens.append(device.observe(\.lensAperture, options: [.initial, .new]) { device, _ in
            let v = Double(device.lensAperture)
            hub.update { $0.aperture = v }
        })
        tokens.append(device.observe(\.isAdjustingFocus, options: [.initial, .new]) { device, _ in
            let v = device.isAdjustingFocus
            hub.update { $0.isAdjustingFocus = v }
        })
        tokens.append(device.observe(\.systemPressureState, options: [.initial, .new]) { device, _ in
            thermalOut.yield(thermalLevel(device.systemPressureState.level))
        })
        return tokens
    }

    private nonisolated static func thermalLevel(_ level: AVCaptureDevice.SystemPressureState.Level) -> FinderThermalLevel {
        switch level {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        default: .critical   // .critical, .shutdown
        }
    }

    private nonisolated static func makeNotificationObservers(
        session: AVCaptureSession, events: AsyncStream<CameraEvent>.Continuation, onMediaServicesReset: @escaping @Sendable () -> Void
    ) -> [any NSObjectProtocol] {
        let center = NotificationCenter.default
        let began = center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { @Sendable note in
            let raw = (note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber)?.intValue
            events.yield(.interruptionBegan(interruption(rawReason: raw)))
        }
        let ended = center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { @Sendable _ in
            events.yield(.interruptionEnded)
        }
        let started = center.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil) { @Sendable _ in
            events.yield(.sessionStarted)
        }
        let failed = center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { @Sendable note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            if error?.code == AVError.mediaServicesWereReset.rawValue {
                onMediaServicesReset()
            } else {
                events.yield(.runtimeError(error?.localizedDescription ?? "The camera failed"))
            }
        }
        return [began, ended, started, failed]
    }

    private nonisolated static func interruption(rawReason: Int?) -> CameraInterruption {
        guard let rawReason, let reason = AVCaptureSession.InterruptionReason(rawValue: rawReason) else { return .unknown }
        switch reason {
        case .videoDeviceNotAvailableInBackground: return .videoDeviceNotAvailableInBackground
        case .audioDeviceInUseByAnotherClient: return .audioDeviceInUse
        case .videoDeviceInUseByAnotherClient: return .videoDeviceInUseByAnotherClient
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return .videoDeviceNotAvailableWithMultipleForegroundApps
        case .videoDeviceNotAvailableDueToSystemPressure: return .videoDeviceNotAvailableDueToSystemPressure
        default: return .unknown
        }
    }
}
#endif
