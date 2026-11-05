#if os(iOS)
import AVKit
import MiraCameraKit
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// Resolves the single finger on the finder into tap, hold-to-compare and AE/AF lock (see `FinderTouchTracker`).
@MainActor
final class FinderTouchDriver {
    private var tracker = FinderTouchTracker()
    private var began: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    private let clock = ContinuousClock()

    func changed(_ drag: DragGesture.Value, size: CGSize, model: CameraModel) {
        if tracker.phase == .idle {
            tracker.begin(at: drag.location)
            began = clock.now
            timer = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(Int(FinderTouchTracker.showOriginalAfter * 1000)))
                guard !Task.isCancelled, let self else { return }
                self.act(self.tracker.held(for: FinderTouchTracker.showOriginalAfter), size: size, model: model)
                try? await Task.sleep(for: .milliseconds(Int((FinderTouchTracker.lockAfter - FinderTouchTracker.showOriginalAfter) * 1000)))
                guard !Task.isCancelled else { return }
                self.act(self.tracker.held(for: FinderTouchTracker.lockAfter), size: size, model: model)
            }
        } else {
            act(tracker.move(to: drag.location), size: size, model: model)
            if tracker.phase == .cancelled { timer?.cancel() }
        }
    }

    func ended(size: CGSize, model: CameraModel) {
        timer?.cancel()
        let elapsed = began.map { clock.now - $0 } ?? .zero
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        act(tracker.end(after: seconds), size: size, model: model)
        began = nil
    }

    /// A second finger arrived.
    func cancel(size: CGSize, model: CameraModel) {
        timer?.cancel()
        act(tracker.cancel(), size: size, model: model)
    }

    private func act(_ action: FinderTouchTracker.Action, size: CGSize, model: CameraModel) {
        switch action {
        case .none: break
        case .tapFocus(let p): model.tapFocus(at: p, in: size)
        case .showOriginal(let on): model.showingOriginal = on
        case .lock(let p):
            model.showingOriginal = false
            model.lockFocus(at: p, in: size)
        }
    }
}

/// The two doors that slide up over the lower chrome (the settings stay a sheet).
enum CameraDoor: String, Identifiable {
    case film, wb
    var id: String { rawValue }
}

/// What the app's door views get from the camera: a way to close the door and the most height it may take.
public struct CameraDoorContext {
    public let close: () -> Void
    public let maxHeight: CGFloat
}

/// The camera screen: header, meter, finder, lens chips, EV dial, shutter row. Portrait stacks them; landscape
/// gives the finder the long side with the meter, lens chips and EV dial on the left and the shutter column on the right.
/// The film and white balance doors are supplied by the app (`filmDoor`, `wbDoor`) and slide up as a bottom panel
/// over the lower chrome, the finder staying visible above.
public struct CameraView<FilmDoor: View, WBDoor: View>: View {
    @Bindable var model: CameraModel
    let filmName: String?
    let onClose: () -> Void
    let filmDoor: (CameraDoorContext) -> FilmDoor
    let wbDoor: (CameraDoorContext) -> WBDoor
    /// Layout tests report the finder's frame in the camera's coordinate space.
    var onLayout: (@MainActor @Sendable ([String: CGRect]) -> Void)?

    @State private var door: CameraDoor?
    @State private var settingsShown = false
    @State private var touch = FinderTouchDriver()
    @Environment(\.scenePhase) private var scenePhase

    public init(
        model: CameraModel, filmName: String?, onClose: @escaping () -> Void,
        @ViewBuilder filmDoor: @escaping (CameraDoorContext) -> FilmDoor, @ViewBuilder wbDoor: @escaping (CameraDoorContext) -> WBDoor
    ) {
        self.model = model
        self.filmName = filmName
        self.onClose = onClose
        self.filmDoor = filmDoor
        self.wbDoor = wbDoor
    }

    /// `onLayout` receives the frames of the parts (header, meter, finder, lenses, ev, bottom, shutter, thumb) for layout tests.
    public init(
        model: CameraModel, filmName: String?, onClose: @escaping () -> Void,
        onLayout: (@MainActor @Sendable ([String: CGRect]) -> Void)?,
        @ViewBuilder filmDoor: @escaping (CameraDoorContext) -> FilmDoor, @ViewBuilder wbDoor: @escaping (CameraDoorContext) -> WBDoor
    ) {
        self.init(model: model, filmName: filmName, onClose: onClose, filmDoor: filmDoor, wbDoor: wbDoor)
        self.onLayout = onLayout
    }

    public var body: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            GeometryReader { geo in
                if model.authorization == .denied {
                    denied
                } else if geo.size.width > geo.size.height {
                    landscape
                } else {
                    portrait
                }
            }
            doorPanel
        }
        .coordinateSpace(name: CameraSpace.name)
        .onPreferenceChange(CameraFrameKey.self) { frames in
            MainActor.assumeIsolated { onLayout?(frames) }
        }
        .foregroundStyle(T.paper)
        .tint(T.lichen)
        .task { await model.start() }
        .onAppear {
            // Headless snapshots: MIRA_SNAPSHOT_SHEET=filmdoor|wbdoor opens a door without a tap.
            let env = ProcessInfo.processInfo.environment
            guard env["MIRA_SNAPSHOT"] == "1" else { return }
            switch env["MIRA_SNAPSHOT_SHEET"] {
            case "filmdoor": door = .film
            case "wbdoor": door = .wb
            default: break
            }
        }
        .onDisappear { Task { await model.stop() } }
        .onChange(of: scenePhase) { _, phase in model.scenePhaseChanged(phase) }
        .onCameraCaptureEvent { event in
            // Volume buttons, Action button, Camera Control. Every phase is handled; only a release fires.
            let phase: HardwareShutterPhase = switch event.phase {
            case .began: .began
            case .ended: .ended
            default: .cancelled
            }
            if HardwareShutter.shouldFire(phase: phase) { model.shutter() }
        }
        .sheet(isPresented: $settingsShown) {
            CameraSettingsSheet(model: model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackground(T.inkSoft)
                .presentationCornerRadius(0)
                .preferredColorScheme(.dark)
        }
    }

    // MARK: Doors

    private func closeDoor() { withAnimation(.snappy(duration: 0.22)) { door = nil } }

    private func openDoor(_ which: CameraDoor) { withAnimation(.snappy(duration: 0.22)) { door = which } }

    /// The open door as a bottom panel over the lower chrome (square, ink-soft, hairline on top).
    private var doorPanel: some View {
        GeometryReader { geo in
            if let door {
                let context = CameraDoorContext(close: closeDoor, maxHeight: geo.size.height * 0.5 - 32)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    FFHairline()
                    Group {
                        switch door {
                        case .film: filmDoor(context)
                        case .wb: wbDoor(context)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .background(T.inkSoft)
                }
                .transition(.move(edge: .bottom))
            }
        }
    }

    // MARK: Portrait

    private var portrait: some View {
        VStack(spacing: 0) {
            CameraHeader(filmName: filmName, developing: model.developingCount, onBack: onClose) { settingsShown = true }
                .reportFrame("header")
            FFHairline()
            MeterView(needle: model.needle, readout: model.readoutText, latitude: model.latitude)
                .reportFrame("meter")
            finder.reportFrame("finder")
            LensChips(lenses: model.lenses, selected: model.selectedLens) { model.selectLens($0) }
                .frame(height: 34)
                .reportFrame("lenses")
            FFHairline()
            EVDial(value: model.evBias) { model.setEV($0) }.reportFrame("ev")
            FFHairline()
            ZStack {
                HStack {
                    LastFrameThumb(image: model.lastFrame) { model.openLastFrame() }.reportFrame("thumb")
                    Spacer()
                    doors
                }
                ShutterButton(readiness: model.readiness) { model.shutter() }.reportFrame("shutter")
            }
            .padding(.horizontal, T.cells(2))
            .frame(height: 92)
            .reportFrame("bottom")
        }
    }

    // MARK: Landscape

    private var landscape: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                CameraHeader(filmName: filmName, developing: 0, onBack: onClose, onSettings: { settingsShown = true }, showsFilmName: false)
                    .reportFrame("header")
                FFHairline()
                if let filmName, !filmName.isEmpty {
                    Text(filmName).font(T.display(17)).lineLimit(1).minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, T.cells(2)).padding(.top, 4)
                }
                MeterView(needle: model.needle, readout: model.readoutText, latitude: model.latitude, stacked: true).reportFrame("meter")
                Spacer(minLength: 0)
                LensChips(lenses: model.lenses, selected: model.selectedLens) { model.selectLens($0) }
                    .frame(height: 34).reportFrame("lenses")
                FFHairline()
                EVDial(value: model.evBias) { model.setEV($0) }.reportFrame("ev")
            }
            .frame(width: 210)
            FFHairline(.vertical)
            finder.reportFrame("finder")
            FFHairline(.vertical)
            VStack(spacing: 8) {
                if model.developingCount > 0 {
                    Text("DEVELOPING \(model.developingCount)").ffLabel(size: 9, color: T.paperDim).padding(.top, 8)
                }
                Spacer(minLength: 0)
                ShutterButton(readiness: model.readiness) { model.shutter() }.reportFrame("shutter")
                Spacer(minLength: 0)
                LastFrameThumb(image: model.lastFrame) { model.openLastFrame() }.reportFrame("thumb")
                doors
            }
            .padding(.vertical, 8)
            .frame(width: 104)
        }
    }

    private var doors: some View {
        VStack(alignment: .trailing, spacing: 0) {
            DoorButton(title: "FILM", label: "Choose film") { openDoor(.film) }
            DoorButton(title: "WB", label: "White balance") { openDoor(.wb) }
        }
    }

    // MARK: Denied

    private var denied: some View {
        VStack(spacing: 0) {
            CameraHeader(filmName: nil, developing: 0, onBack: onClose, onSettings: {}).opacity(1)
            FFHairline()
            FFEmptyState(title: "Camera", subtitle: "CAMERA ACCESS IS OFF", buttonTitle: "OPEN SETTINGS") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
    }

    // MARK: Finder

    private var finder: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                T.inkAlways
                if let renderer = model.finder { FinderView(renderer: renderer) { model.previewLayerChanged($0) } }
                if let p = model.focusPoint { FocusMark(point: p, locked: model.aeAfLocked, bounds: size) }
                overlays(size: size)
                T.inkAlways.opacity(model.blink ? 1 : 0).allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { touch.changed($0, size: size, model: model) }
                    .onEnded { _ in touch.ended(size: size, model: model) })
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        touch.cancel(size: size, model: model)
                        model.pinch(scale: Double(value.magnification))
                    }
                    .onEnded { _ in model.pinchEnded() })
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Viewfinder")
            .accessibilityHint("Double-tap to focus. Touch and hold to see the scene without the film.")
            .accessibilityAddTraits(.isImage)
            .accessibilityAction(named: "Focus at center") { model.tapFocus(at: CGPoint(x: size.width / 2, y: size.height / 2), in: size) }
            .accessibilityAction(named: "Lock exposure and focus at center") {
                model.lockFocus(at: CGPoint(x: size.width / 2, y: size.height / 2), in: size)
            }
            .accessibilityAction(named: "Unlock exposure and focus") { model.unlockFocus() }
        }
    }

    @ViewBuilder private func overlays(size: CGSize) -> some View {
        VStack {
            HStack {
                if model.showingOriginal { FinderCaption(text: "ORIGINAL") }
                Spacer()
            }
            .padding(8)
            Spacer()
            if let mm = model.pinchMM { FinderCaption(text: "\(mm) MM") }
            if let notice = model.notice { FinderCaption(text: notice.uppercased(), color: T.onPhotoAccent).multilineTextAlignment(.center) }
        }
        .padding(.bottom, 8)
        if let status = model.statusText {
            Button { Task { await model.retry() } } label: {
                FinderCaption(text: status)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: Layout facts

struct CameraFrameKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

enum CameraSpace { static let name = "cameraView" }

extension View {
    /// Publishes this view's frame under `id`, relative to the camera view.
    func reportFrame(_ id: String) -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(key: CameraFrameKey.self, value: [id: geo.frame(in: .named(CameraSpace.name))])
            }
        }
    }
}
#endif
