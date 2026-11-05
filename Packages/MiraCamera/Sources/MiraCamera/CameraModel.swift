#if os(iOS)
import AVFoundation
import CoreLocation
import CoreImage
import Foundation
import MiraCameraKit
import MiraCore
import Observation
import Photos
import SwiftUI
import Synchronization
import UIKit

public enum CameraAuthorization: Sendable, Equatable { case authorized, denied, notDetermined }

/// What the frame handler learned from the frames (it runs on the finder queue).
struct FrameReport: Sendable, Equatable {
    var aspect: Double
    var angle: Double
    var first: Bool
}

/// Commands to the device, run one at a time in the order the UI gave them.
enum DeviceCommand: Sendable {
    case exposure(Double)
    case zoom(Double, ramp: Bool)
    case focus(CGPoint, lock: Bool)
    case unlockFocus
    case whiteBalance(WhiteBalanceState)
}

/// All the camera screen's state. Main actor; every device, Photos, Metal and CoreLocation callback hops here
/// through a `@Sendable` closure made in a nonisolated context (see the `make...Handler` helpers).
@MainActor @Observable
public final class CameraModel {
    // MARK: State for the views

    public var state: CameraState = .idle
    public var authorization: CameraAuthorization = .notDetermined
    public var readiness: ShutterReadiness = .sessionNotRunning
    public var lenses: [Lens] = []
    public var selectedLens: Lens?
    /// The device zoom factor as last set (the base a pinch starts from).
    public var zoom: Double = 1
    /// Millimeters shown while pinching, nil otherwise.
    public var pinchMM: Int?
    public var evBias: Double = 0
    public var needle: Double = 0
    public var readoutText = "\u{2014}"
    public var latitude = LatitudeReadout(reading: nil)
    public var aeAfLocked = false
    /// Where the focus mark is, in the finder view's coordinates.
    public var focusPoint: CGPoint?
    public var developingCount = 0
    public var lastFrame: UIImage?
    public var lastAssetID: String?
    public var notice: String?
    /// True for one beat after the shutter fires (the ink blink).
    public var blink = false
    public var showingOriginal = false {
        didSet { if showingOriginal != oldValue { finder?.update { [showingOriginal] in $0.showingOriginal = showingOriginal } } }
    }
    public var stats: FinderStats?
    public var silentShutterSupported = false
    /// Upright width / height of the frames on screen (what the finder aspect-fits).
    public var frameAspect: Double = 3.0 / 4.0
    /// Degrees the sensor image is rotated to be upright (90 = portrait phone). Drives the readouts' rotation.
    public var rotationAngle: Double = 90
    public var cardThumbnails: [String: CGImage] = [:]
    public var wb = WhiteBalanceState() {
        didSet {
            guard wb != oldValue else { return }
            settings.whiteBalanceKelvin = wb.kelvin
            send(.whiteBalance(wb))
        }
    }
    /// The user's recipe. Pushes to the finder and is what a capture saves (no finder-only fields).
    public var recipe: Recipe {
        didSet {
            guard recipe != oldValue else { return }
            finder?.update { [recipe] in $0.recipe = recipe }
            settings.lastRecipe = recipe
            settings.lastFilmID = recipe.filmID
        }
    }
    private var lastManualKelvin: Int?
    public var settings: CameraSettings {
        didSet { settingsChanged(from: oldValue) }
    }

    public let statsEnabled = ProcessInfo.processInfo.environment["MIRA_CAMERA_STATS"] == "1"
    public var statusText: String? { state.statusText }
    /// Degrees to turn the readouts so they stay upright in the world when the interface stays portrait
    /// (orientation lock) and the phone is turned: the frame angle's difference from portrait (90).
    /// The fake source reports 0 as "upright", so it never rotates. [VERIFY on device: sign.]
    public var readoutRotation: Double { CameraBackend.usesFakes ? 0 : rotationAngle - 90 }
    public var lowestZoom: Double { lenses.first?.zoomFactor ?? 1 }
    public var highestZoom: Double { (lenses.last?.zoomFactor ?? 1) * 2 }

    // MARK: Parts

    public let finder: FinderRenderer?
    let device: any CameraDevice
    let frames: any FrameSource
    let saver: CaptureSaver
    let queue: PrintQueue
    private let library: any PhotoLibraryWriting
    private let requestLibraryAccess: @Sendable () async -> LibraryAccess
    private let store: CameraSettingsStore
    private let onOpenFrame: @MainActor (String) -> Void
    private let location = CameraLocation()
    private let filmLibrary: FilmLibrary?

    @ObservationIgnored private var format = CaptureFormat(
        useProRAW: false, maxDimensions: CaptureFormatPolicy.fallbackDimensions, prioritization: .balanced,
        suppressShutterSound: false, zeroShutterLag: true, rawBase: false)
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var startInFlight = false
    @ObservationIgnored private var frameHandlerInstalled = false
    @ObservationIgnored private var deferredStartDone = false
    @ObservationIgnored private var latestEV = 0.0
    @ObservationIgnored private var pinchBase: Double?
    @ObservationIgnored private var focusToken = 0
    @ObservationIgnored private var noticeToken = 0
    private let commandsOut: AsyncStream<DeviceCommand>.Continuation
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    @ObservationIgnored private let impact = UIImpactFeedbackGenerator(style: .rigid)
    @ObservationIgnored private let selection = UISelectionFeedbackGenerator()
    @ObservationIgnored private let notification = UINotificationFeedbackGenerator()

    // MARK: Init

    /// - Parameters:
    ///   - printWriter: attaches the recipe to a saved frame (the app backs it with the editor's `AssetEditSession`).
    ///   - renderer: the film renderer the finder and the baker use (the bundled films when nil).
    ///   - backend: the device and frame source; `CameraBackend.make` (real on a phone, fake elsewhere) when nil.
    ///   - fixtureURL: the picture the fake backend shows.
    ///   - printQueue: the app's shared print queue (it drains at launch, even with the camera closed); built here when nil.
    ///   - onOpenFrame: opens the asset with this local identifier in the editor.
    public init(
        printWriter: any PrintWriting,
        renderer: Renderer? = nil,
        initialRecipe: Recipe? = nil,
        fixtureURL: URL? = nil,
        backend: (device: any CameraDevice, frames: any FrameSource)? = nil,
        library: any PhotoLibraryWriting = PhotoKitLibraryWriter(),
        baker: (any PrintBaking)? = nil,
        requestLibraryAccess: @escaping @Sendable () async -> LibraryAccess = { await PhotoKitLibraryWriter.requestAccess() },
        settingsStore: CameraSettingsStore = CameraSettingsStore(),
        pendingDirectory: URL? = nil,
        printQueue: PrintQueue? = nil,
        onOpenFrame: @escaping @MainActor (String) -> Void = { _ in }
    ) {
        let made = backend ?? CameraBackend.make(fixtureURL: fixtureURL)
        device = made.device
        frames = made.frames
        self.library = library
        self.requestLibraryAccess = requestLibraryAccess
        store = settingsStore
        self.onOpenFrame = onOpenFrame
        let loaded = settingsStore.load()
        settings = loaded
        recipe = initialRecipe ?? loaded.lastRecipe ?? Recipe()
        filmLibrary = renderer?.library
        finder = FinderRenderer(renderer: renderer)
        let directory = pendingDirectory ?? Self.defaultPendingDirectory()
        queue = printQueue ?? PrintQueue(store: PendingPrintStore(directory: directory), writer: printWriter)
        let bakerInUse = baker ?? (renderer?.library).map { PhotoKitBaker(library: $0) } ?? PhotoKitBaker()
        saver = CaptureSaver(library: library, baker: bakerInUse, queue: queue)

        let (commands, commandsOut) = AsyncStream<DeviceCommand>.makeStream(bufferingPolicy: .unbounded)
        self.commandsOut = commandsOut

        finder?.update { [recipe, loaded] state in
            state.recipe = recipe
            state.mode = loaded.finderQuality
            state.grainLive = loaded.finderGrainLive
        }
        wb = WhiteBalanceState(kelvin: loaded.whiteBalanceKelvin)   // restored without a command: start() sends it
        lastManualKelvin = wb.kelvin
        finder?.setLatitudeHandler(Self.makeLatitudeHandler(self))
        finder?.setCardsHandler(Self.makeCardsHandler(self))
        if statsEnabled { finder?.setStatsHandler(Self.makeStatsHandler(self)) }
        startConsumers(commands: commands)
    }

    public static func defaultPendingDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("MiraCamera", isDirectory: true)
    }

    /// Lets the commands consumer end when the camera closes (the other streams end with the device).
    deinit { commandsOut.finish() }

    // MARK: Streams (each has exactly one consumer, a main-actor task)

    private func startConsumers(commands: AsyncStream<DeviceCommand>) {
        let telemetry = device.telemetry, events = device.events, readiness = device.readiness
        let signals = device.captureSignals, thermal = device.thermalLevels, developed = saver.developedFrames
        // The frame source's rotation is fed by `CameraBackend.make` from `rotationAngles`, which has a single
        // consumer; the readouts take the angle from the frames instead (`FrameReport`).
        tasks = [
            Task { @MainActor [weak self] in for await t in telemetry { self?.apply(t) } },
            Task { @MainActor [weak self] in for await e in events { self?.state.handle(e) } },
            Task { @MainActor [weak self] in for await r in readiness { self?.readiness = r } },
            Task { @MainActor [weak self] in for await s in signals { if s == .shutterClosed { await self?.blinkOnce() } } },
            Task { @MainActor [weak self] in for await l in thermal { self?.finder?.setThermal(l) } },
            Task { @MainActor [weak self] in for await id in developed { self?.frameDeveloped(id) } },
            Task { @MainActor [weak self] in for await c in commands { await self?.run(c) } },
        ]
    }

    private func apply(_ t: ExposureTelemetry) {
        readoutText = t.duration > 0 ? ExposureReadout.text(duration: t.duration, iso: t.iso, aperture: t.aperture) : "\u{2014}"
        needle = ExposureModel.needle(offsetEV: t.offsetEV)
    }

    private func blinkOnce() async {
        blink = true
        try? await Task.sleep(for: .milliseconds(60))
        blink = false
    }

    // MARK: Handlers for callbacks off the main actor
    // Built in a nonisolated context and `@Sendable`, so no main-actor-isolated closure is ever called on a
    // Metal, AVFoundation or Photos queue.

    private nonisolated static func makeLatitudeHandler(_ model: CameraModel) -> @Sendable (LatitudeReading?) -> Void {
        { [weak model] reading in Task { @MainActor in model?.latitude = LatitudeReadout(reading: reading) } }
    }

    private nonisolated static func makeCardsHandler(_ model: CameraModel) -> @Sendable ([String: CGImage]) -> Void {
        { [weak model] cards in Task { @MainActor in model?.cardThumbnails.merge(cards) { _, new in new } } }
    }

    private nonisolated static func makeStatsHandler(_ model: CameraModel) -> @Sendable (FinderStats) -> Void {
        { [weak model] stats in Task { @MainActor in model?.stats = stats } }
    }

    /// The frame handler: renders each frame, and reports the first frame and any change in aspect or rotation.
    private nonisolated static func makeFrameHandler(finder: FinderRenderer?, model: CameraModel) -> @Sendable (FinderFrame) -> Void {
        let last = Mutex<FrameReport?>(nil)
        return { [weak model] frame in
            finder?.consume(frame)
            let size = frame.image.extent.size
            let report = FrameReport(
                aspect: FinderGeometry.uprightAspect(sensorSize: size, rotationAngle: frame.rotationAngle),
                angle: frame.rotationAngle, first: false)
            let send: FrameReport? = last.withLock { (previous: inout FrameReport?) -> FrameReport? in
                guard let old = previous else {
                    var first = report
                    first.first = true
                    previous = report
                    return first
                }
                guard abs(old.aspect - report.aspect) > 0.001 || old.angle != report.angle else { return nil }
                previous = report
                return report
            }
            if let send { Task { @MainActor in model?.apply(send) } }
        }
    }

    private func apply(_ report: FrameReport) {
        frameAspect = report.aspect
        rotationAngle = report.angle
        guard report.first, !deferredStartDone else { return }
        deferredStartDone = true
        // iOS 26+: the work the session postponed runs once the first finder frame is up.
        Task { [device] in await device.runDeferredStartWhenNeeded() }
    }

    // MARK: Lifecycle

    /// Opens the camera: permission, kernel warm-up, session start (off the main actor), print queue drain.
    public func start() async {
        wantsRunning = true
        guard !startInFlight, startable else { return }
        startInFlight = true
        defer { startInFlight = false }

        authorization = await resolveAuthorization()
        guard authorization == .authorized else { wantsRunning = false; return }

        state.handle(.start)
        impact.prepare()
        selection.prepare()
        let films = filmLibrary
        Task.detached(priority: .utility) { Self.warmUp(films) }

        if !frameHandlerInstalled {
            frameHandlerInstalled = true
            frames.setHandler(Self.makeFrameHandler(finder: finder, model: self))
        }
        deferredStartDone = false
        format = await device.configure(settings: settings)
        finder?.update { [format] in $0.captureLongSide = Double(max(format.maxDimensions.width, format.maxDimensions.height)) }
        silentShutterSupported = await device.capabilities().isShutterSoundSuppressionSupported
        let found = await device.lenses()
        lenses = found
        if selectedLens == nil {
            let main = found.first { !$0.isCrop && $0.equivalentMM >= 18 } ?? found.first
            selectedLens = main
            zoom = main?.zoomFactor ?? 1
            if let main { send(.zoom(main.zoomFactor, ramp: false)) }
        }
        if let kelvin = wb.kelvin { send(.whiteBalance(WhiteBalanceState(kelvin: kelvin))) }   // the stored value reaches the device
        location.setEnabled(settings.addLocation)
        frames.start()
        await device.start()
        Task { await queue.drain() }
    }

    private nonisolated static func warmUp(_ library: FilmLibrary?) {
        guard let library = library ?? FilmLibrary.bundled(in: .main) else { return }
        PreviewEngine.warmUp(library: library)
    }

    private var startable: Bool {
        if case .failed = state { return true }
        return state == .idle
    }

    private func resolveAuthorization() async -> CameraAuthorization {
        if CameraBackend.usesFakes { return .authorized }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .authorized
        case .notDetermined: return await Self.requestCameraAccess() ? .authorized : .denied
        default: return .denied
        }
    }

    private nonisolated static func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Closes the camera (leaving the screen).
    public func stop() async {
        wantsRunning = false
        await halt()
    }

    private func halt() async {
        state.handle(.stop)
        location.setEnabled(false)
        frames.stop()
        await device.stop()
    }

    /// Tap on "CAMERA FAILED" retries the start.
    public func retry() async {
        guard case .failed = state else { return }
        state = .idle
        await start()
    }

    /// Stop when the app leaves the foreground, start again (and finish pending prints) when it returns.
    public func scenePhaseChanged(_ phase: ScenePhase) {
        if phase == .active {
            Task { await queue.drain() }
            if wantsRunning, state == .idle { Task { await start() } }
        } else if wantsRunning, state != .idle {
            Task { await halt() }
        }
    }

    // MARK: Shutter

    public func shutter() {
        guard authorization == .authorized, state.canCapture, readiness.acceptsPress,
              developingCount < CaptureSaver.maxInFlight else { return }
        impact.impactOccurred()
        developingCount += 1
        let recipe = self.recipe
        let there = settings.addLocation ? location.latest : nil
        Task { await capture(recipe: recipe, location: there) }
    }

    private func capture(recipe: Recipe, location there: CLLocation?) async {
        defer { developingCount = max(0, developingCount - 1) }
        if await library.access() == .notDetermined { _ = await requestLibraryAccess() }
        await saver.captureStarted()
        state.handle(.captureStarted)
        let frame: CapturedFrame
        do {
            frame = try await device.capture(format: format, location: there)
        } catch {
            state.handle(.captureFinished)
            await saver.captureFailed()
            show(notice: (error as? CaptureError)?.monoCopy ?? "FRAME LOST \u{00B7} TRY AGAIN")
            return
        }
        state.handle(.captureFinished)
        do {
            let outcome = try await saver.save(frame, recipe: recipe)
            handle(outcome)
        } catch {
            show(notice: (error as? CaptureSaveError)?.monoCopy ?? "FRAME NOT SAVED")
        }
    }

    private func handle(_ outcome: SaveOutcome) {
        lastAssetID = outcome.assetID
        refreshThumbnail(for: outcome.assetID)
        switch outcome {
        case .bakedCopy(let text, _, _), .originalOnly(_, let text): show(notice: text)
        case .developed, .printPending: break
        }
    }

    private func frameDeveloped(_ id: String) {
        notification.notificationOccurred(.success)
        if id == lastAssetID { refreshThumbnail(for: id) }
    }

    private func refreshThumbnail(for id: String) {
        Task {
            let image = await Self.loadThumbnail(assetID: id, side: 160 * UIScreen.main.scale)
            if lastAssetID == id, let image { lastFrame = image }
        }
    }

    /// Photos' thumbnail for the asset, nil when Photos has none (or no access).
    private nonisolated static func loadThumbnail(assetID: String, side: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let once = Mutex(false)
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: side, height: side), contentMode: .aspectFill, options: options
            ) { @Sendable image, _ in
                let first = once.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: image) }
            }
        }
    }

    private func show(notice text: String) {
        notice = text
        noticeToken += 1
        let token = noticeToken
        Task {
            try? await Task.sleep(for: .seconds(5))
            if token == noticeToken { notice = nil }
        }
    }

    /// Opens the last frame in the editor.
    public func openLastFrame() {
        guard let id = lastAssetID else { return }
        onOpenFrame(id)
    }

    // MARK: Exposure, lenses, zoom, white balance

    public func setEV(_ ev: Double) {
        let target = ExposureModel.snapToThird(ev)
        guard target != evBias else { return }
        if ExposureModel.detentsCrossed(from: evBias, to: target) > 0 { selection.selectionChanged() }
        evBias = target
        latestEV = target
        send(.exposure(target))
    }

    /// Sets the white balance (nil is AUTO), one selection haptic per 100 K step.
    public func setWB(_ kelvin: Int?) {
        let target = WhiteBalanceState(kelvin: kelvin)
        guard target != wb else { return }
        if target.kelvin != nil, wb.kelvin != nil { selection.selectionChanged() }
        wb = target
        if let k = target.kelvin { lastManualKelvin = k }
    }

    /// A drag ended: snap to a preset within 150 K.
    public func commitWB() {
        guard let k = wb.kelvin else { return }
        let snapped = WhiteBalanceModel.snapped(k)
        if snapped != k { impact.impactOccurred() }
        setWB(snapped)
    }

    /// AUTO to the last manual value (5500 K the first time), or back to AUTO.
    public func toggleAutoWB() {
        selection.selectionChanged()
        setWB(wb.kelvin == nil ? (lastManualKelvin ?? WhiteBalanceModel.startKelvin) : nil)
    }

    public func selectLens(_ lens: Lens) {
        selection.selectionChanged()
        selectedLens = lens
        zoom = lens.zoomFactor
        pinchMM = nil
        send(.zoom(lens.zoomFactor, ramp: true))
    }

    /// `scale` is the gesture's cumulative magnification; the zoom at the first call is the base.
    public func pinch(scale: Double) {
        let base = pinchBase ?? zoom
        pinchBase = base
        let z = min(max(base * scale, lowestZoom), highestZoom)
        zoom = z
        pinchMM = Self.millimeters(atZoom: z, lenses: lenses)
        let near = lenses.last { $0.zoomFactor <= z + 0.01 }
        if near?.id != selectedLens?.id {
            selectedLens = near
            selection.selectionChanged()
        }
        send(.zoom(z, ramp: false))
    }

    public func pinchEnded() {
        pinchBase = nil
        Task {
            try? await Task.sleep(for: .milliseconds(900))
            if pinchBase == nil { pinchMM = nil }
        }
    }

    /// 35 mm equivalent at a zoom factor, scaled from the nearest lens below it.
    public nonisolated static func millimeters(atZoom z: Double, lenses: [Lens]) -> Int? {
        guard let base = lenses.last(where: { $0.zoomFactor <= z + 0.001 }) ?? lenses.first, base.zoomFactor > 0 else { return nil }
        return Int((Double(base.equivalentMM) * z / base.zoomFactor).rounded())
    }

    // MARK: Focus

    /// Tap: focus and meter at the point (view coordinates inside a finder of `size`). Unlocks AE/AF first.
    public func tapFocus(at point: CGPoint, in size: CGSize) {
        if aeAfLocked { unlockFocus() }
        focus(at: point, in: size, lock: false)
    }

    /// Long press: lock AE and AF at the point.
    public func lockFocus(at point: CGPoint, in size: CGSize) {
        impact.impactOccurred()
        aeAfLocked = true
        focus(at: point, in: size, lock: true)
    }

    public func unlockFocus() {
        aeAfLocked = false
        focusPoint = nil
        send(.unlockFocus)
    }

    private func focus(at point: CGPoint, in size: CGSize, lock: Bool) {
        focusPoint = point
        focusToken += 1
        let token = focusToken
        // The device wants sensor coordinates: undo the aspect-fit and the rotation.
        let devicePoint = FinderGeometry.devicePoint(viewPoint: point, viewSize: size, uprightAspect: frameAspect, rotationAngle: rotationAngle)
        send(.focus(devicePoint, lock: lock))
        guard !lock else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(1400))
            if token == focusToken, !aeAfLocked { focusPoint = nil }
        }
    }

    // MARK: Film door support

    /// Film IDs the door wants thumbnails of (the finder renders them from the live frame, each published as it is done, refreshed at about 2 Hz); empty when closed.
    public func setWantedCardIDs(_ ids: [String]) {
        finder?.update { $0.cardFilmIDs = ids }
        if ids.isEmpty { cardThumbnails = [:] }
    }

    // MARK: Settings

    private func settingsChanged(from old: CameraSettings) {
        store.save(settings)
        if settings.finderQuality != old.finderQuality || settings.finderGrainLive != old.finderGrainLive {
            finder?.update { [settings] in
                $0.mode = settings.finderQuality
                $0.grainLive = settings.finderGrainLive
            }
        }
        if settings.addLocation != old.addLocation, wantsRunning { location.setEnabled(settings.addLocation) }
        if settings.silentShutter != old.silentShutter {
            Task { format = await device.configure(settings: settings) }
        }
    }

    // MARK: Device commands

    private func send(_ command: DeviceCommand) { commandsOut.yield(command) }

    private func run(_ command: DeviceCommand) async {
        switch command {
        case .exposure(let ev):
            let applied = await device.setExposureBias(ev)
            // Only the latest request updates the dial (a stale answer would make it jump back mid-drag).
            if ev == latestEV, applied != evBias { evBias = applied }
        case .zoom(let z, let ramp): await device.setZoom(z, ramp: ramp)
        case .focus(let p, let lock): await device.focusAndMeter(at: p, lock: lock)
        case .unlockFocus: await device.unlockFocusAndExposure()
        case .whiteBalance(let s): await device.setWhiteBalance(s)
        }
    }
}
#endif
