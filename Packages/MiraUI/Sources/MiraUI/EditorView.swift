import MiraCore
import OSLog
import SwiftUI

private typealias T = FieldFramesTheme

/// The shared editor: the sub-toolbar with its FILMS / DEVELOP / CROP tabs, the canvas, and the
/// panels each tab brings (film strip and film header; histogram and sliders; crop controls).
public struct EditorView<Footer: View>: View {
    @Bindable private var model: EditorModel
    private let host: EditorHostBar?
    private let windowFullScreen: Bool
    private let footer: Footer
    @Environment(\.ffImageCanvas) private var imageCanvas

    /// The right panel's width range in points; the canvas takes everything else.
    static var panelWidth: ClosedRange<CGFloat> { 300...340 }

    /// `host` adds `← LIBRARY`, the status and SAVE (the app); the Photos extension passes nil.
    /// `windowFullScreen` lets F also put the window in macOS full screen (the app); the extension
    /// only hides the panels. `footer` sits under the canvas column.
    public init(model: EditorModel, host: EditorHostBar? = nil, windowFullScreen: Bool = false,
                @ViewBuilder footer: () -> Footer) {
        self.model = model
        self.host = host
        self.windowFullScreen = windowFullScreen
        self.footer = footer()
    }

    public var body: some View {
        VStack(spacing: 0) {
            if !model.isImmersive {
                EditorSubToolbar(model: model, host: host)
            }
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PreviewPane(model: model)
                    if !model.isImmersive {
                        if model.isCropping {
                            FFHairline()
                            CropControls(model: model)
                        }
                        if model.tab == .films {
                            FFHairline()
                            FilmStrip(model: model)
                        }
                        if model.tab == .presets {
                            FFHairline()
                            PresetStrip(model: model)
                        }
                        footer
                    }
                }
                if !model.isImmersive {
                    FFHairline(.vertical)
                    panel
                        .frame(minWidth: Self.panelWidth.lowerBound, idealWidth: 320, maxWidth: Self.panelWidth.upperBound)
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background { if model.isImmersive { T.inkAlways } }
        .fieldFramesWindow()
        .sheet(item: $model.presetSheet) { mode in
            SavePresetSheet(model: model, mode: mode)
        }
        .confirmationDialog(
            "Delete this preset?",
            isPresented: Binding(get: { model.presetPendingDelete != nil },
                                 set: { if !$0 { model.presetPendingDelete = nil } }),
            titleVisibility: .visible, presenting: model.presetPendingDelete
        ) { preset in
            Button("Delete \(preset.displayName)", role: .destructive) { model.deletePreset(preset.id) }
            Button("Cancel", role: .cancel) { model.presetPendingDelete = nil }
        } message: { _ in
            Text("The preset is removed. Photos you already edited with it keep their look.")
        }
        .background {
            if !imageCanvas { EditorKeyHost(model: model, windowFullScreen: windowFullScreen)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true) }
        }
    }

    @ViewBuilder private var panel: some View {
        switch model.tab {
        case .films: FilmsPanel(model: model)
        case .presets: PresetsPanel(model: model)
        case .develop: DevelopPanel(model: model)
        case .crop: CropPanel(model: model)
        }
    }
}

extension EditorView where Footer == EmptyView {
    public init(model: EditorModel, host: EditorHostBar? = nil, windowFullScreen: Bool = false) {
        self.init(model: model, host: host, windowFullScreen: windowFullScreen) { EmptyView() }
    }
}

// MARK: Preview

private struct PreviewPane: View {
    @Bindable var model: EditorModel
    @Environment(\.ffImageCanvas) private var imageCanvas
    @Environment(\.displayScale) private var displayScale
    @State private var paneSize = CGSize.zero
    @State private var panning = false
    @State private var lastTranslation = CGSize.zero

    @ViewBuilder
    private func canvas(_ frame: PreviewFrame) -> some View {
        if imageCanvas, let image = model.displayedImage {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            FrameCanvas(frame: frame)
        }
    }

    /// True when the frame is laid out by the zoom maths (zoomed, or still a zoomed frame on its way
    /// back to fit); a whole-picture frame at fit uses the plain aspect-fit layout.
    private func usesZoomLayout(_ frame: PreviewFrame) -> Bool {
        !model.zoom.isFit || frame.placement != nil
    }

    @ViewBuilder
    private func zoomedCanvas(_ frame: PreviewFrame) -> some View {
        if let r = model.paneRect(of: frame) {
            let s = displayScale
            canvas(frame)
                .frame(width: r.width / s, height: r.height / s)
                .position(x: r.midX / s, y: r.midY / s)
        }
    }

    var body: some View {
        ZStack {
            // The photograph sits on plain ink: no grain, no veil over it.
            (model.isImmersive ? T.inkAlways : T.ink)
            if let frame = model.displayedFrame {
                if usesZoomLayout(frame) {
                    zoomedCanvas(frame)
                        .accessibilityLabel(model.showOriginal ? "Original photo" : "Edited photo")
                } else {
                    canvas(frame)
                        .aspectRatio(frame.pixelSize, contentMode: .fit)
                        .padding(T.cells(3))
                        .accessibilityLabel(model.showOriginal ? "Original photo" : "Edited photo")
                }
                if model.isCropping {
                    CropOverlay(model: model)
                        .padding(T.cells(3))
                }
            } else {
                Text("Developing").ffLabel()
            }
        }
        .clipped()
        .overlay(alignment: .topLeading) {
            if let name = model.hoverPreviewName, !model.isImmersive {
                Text("Preview \u{00B7} \(name)")
                    .ffLabel(color: T.onPhoto)
                    .lineLimit(1)
                    .padding(.horizontal, T.cells(1))
                    .padding(.vertical, 4)
                    .background(T.onPhotoVeil)
                    .padding(T.cells(2))
                    .allowsHitTesting(false)
                    .accessibilityLabel("Previewing \(name)")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !model.isCropping, !model.isImmersive {
                CompareButton(model: model)
                    .padding(T.cells(2))
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let readout = model.zoomReadout {
                Text(readout)
                    .ffLabel(color: T.onPhoto)
                    .padding(.horizontal, T.cells(1))
                    .padding(.vertical, 4)
                    .background(T.onPhotoVeil)
                    .padding(T.cells(2))
                    .allowsHitTesting(false)
                    .transition(.opacity)
                    .accessibilityLabel("Zoom \(readout)")
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.zoomReadout)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            paneSize = size
            // The picture area is the pane minus its padding; previews are rendered at that size in pixels.
            let inset = T.cells(3) * 2
            let fit = CGSize(width: max(1, size.width - inset) * displayScale,
                             height: max(1, size.height - inset) * displayScale)
            model.setCanvas(pixels: fit)
            model.setViewport(pane: CGSize(width: size.width * displayScale, height: size.height * displayScale),
                              fitArea: fit)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let p): model.pointerInPane = CGPoint(x: p.x * displayScale, y: p.y * displayScale)
            case .ended: model.pointerInPane = nil
            }
        }
        .contentShape(Rectangle())
        .gesture(navigation, isEnabled: model.canZoom && !model.eyedropperActive)
        .gesture(
            SpatialTapGesture().onEnded { tap in
                let pane = CGPoint(x: tap.location.x * displayScale, y: tap.location.y * displayScale)
                guard let frame = model.displayedFrame, let r = model.paneRect(of: frame) ?? fitRect(frame),
                      r.width > 0, r.height > 0, r.contains(pane) else {
                    model.eyedropperActive = false
                    return
                }
                model.sampleRange(atImagePoint: CGPoint(x: (pane.x - r.minX) / r.width, y: (pane.y - r.minY) / r.height))
            },
            isEnabled: model.eyedropperActive && !model.isCropping)
        .pointerStyle(pointer)
        .background(TrackpadZoomPan(model: model, scale: displayScale))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(model.canZoom ? "Click to zoom to 200%, drag or scroll to pan, pinch to zoom" : "")
    }

    /// The aspect-fit rectangle of a whole-picture frame at fit, in device pixels (used when the zoom
    /// maths has no viewport yet).
    private func fitRect(_ frame: PreviewFrame) -> CGRect? {
        let inset = T.cells(3) * displayScale
        let area = CGRect(x: inset, y: inset, width: paneSize.width * displayScale - 2 * inset,
                          height: paneSize.height * displayScale - 2 * inset)
        guard area.width > 0, area.height > 0 else { return nil }
        return CropGeometry.aspectFit(contentSize: frame.pixelSize, in: area)
    }

    private var pointer: PointerStyle {
        if model.eyedropperActive { return .rectSelection }
        guard model.canZoom else { return .default }
        return model.zoom.isFit ? .zoomIn : (panning ? .grabActive : .grabIdle)
    }

    /// One drag gesture does both: a press that barely moves is a click (zoom in or back to fit), a
    /// drag pans the zoomed picture. Space held makes any movement a pan.
    private var navigation: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                let moved = hypot(drag.translation.width, drag.translation.height)
                if !panning, !model.zoom.isFit, moved >= Self.clickSlop || model.isSpaceHeld {
                    panning = true
                    lastTranslation = .zero
                }
                guard panning else { return }
                let step = CGSize(width: (drag.translation.width - lastTranslation.width) * displayScale,
                                  height: (drag.translation.height - lastTranslation.height) * displayScale)
                lastTranslation = drag.translation
                model.zoomPan(byPane: step)
            }
            .onEnded { drag in
                let moved = hypot(drag.translation.width, drag.translation.height)
                if !panning, moved < Self.clickSlop, !model.isSpaceHeld {
                    model.zoomClick(atPane: CGPoint(x: drag.location.x * displayScale, y: drag.location.y * displayScale))
                }
                panning = false
            }
    }

    private static let clickSlop: CGFloat = 3
}

@MainActor
private func holdToCompare(_ model: EditorModel) -> some Gesture {
    DragGesture(minimumDistance: 0)
        .onChanged { _ in if !model.showOriginal { model.showOriginal = true } }
        .onEnded { _ in model.showOriginal = false }
}

private struct CompareButton: View {
    @Bindable var model: EditorModel

    var body: some View {
        FFButtonChrome(pressed: model.showOriginal) {
            Text("Hold to compare")
        }
        .background(T.backdrop)
        .gesture(holdToCompare(model))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Compare")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Press and hold to show the original")
    }
}

// MARK: Film strip

private struct FilmStrip: View {
    @Bindable var model: EditorModel

    private var tabs: [(value: FilmFamily?, title: String)] {
        [(nil, "All")] + FilmFamily.allCases.map { (Optional($0), $0.displayName) }
    }

    var body: some View {
        let _ = PerfCounters.filmStrip += 1
        VStack(alignment: .leading, spacing: 0) {
            FFTabBar(tabs, selection: $model.familyFilter)
                .padding(.horizontal, T.cells(2))
            FFHairline()
            FFScrollView(.horizontal) {
                HStack(alignment: .top, spacing: T.cells(1)) {
                    FilmCard(
                        title: "Original", caption: "No film",
                        image: model.thumbnails[EditorModel.originalTileID],
                        isSelected: model.selectedFilmID == nil,
                        onHoverChange: { hover($0, nil) }
                    ) { model.selectFilm(nil) }

                    ForEach(model.visibleFilms) { film in
                        FilmCard(
                            title: film.displayName,
                            caption: caption(for: film),
                            image: model.thumbnails[film.id],
                            isSelected: model.selectedFilmID == film.id,
                            onHoverChange: { hover($0, film.id) }
                        ) { model.selectFilm(film.id) }
                    }
                }
                .padding(.horizontal, T.cells(2) - 4)
                .padding(.vertical, T.rows(1) / 2)
            }
            .frame(height: T.rows(9))
        }
        .ffPanel()
    }

    /// Enter previews the card; exit only ends the hover if no other card has taken over, so the
    /// exit/enter order between neighbours does not matter.
    private func hover(_ inside: Bool, _ id: String?) {
        let target: EditorModel.HoverTarget = id.map(EditorModel.HoverTarget.film) ?? .original
        if inside {
            model.hoverFilm(id)
        } else if model.hoveredTarget == target {
            model.endHover()
        }
    }

    private func caption(for film: Film) -> String {
        film.iso > 0 ? "\(film.brand) \u{00B7} \(film.iso)" : film.brand
    }
}

// MARK: Scroll and pinch

/// Two-finger scroll and the scroll wheel pan the zoomed picture; pinch zooms. A local event monitor
/// scoped to this view's rect, so it works under SwiftUI's own hit testing. At fit, scroll passes
/// through untouched.
private struct TrackpadZoomPan: NSViewRepresentable {
    let model: EditorModel
    let scale: CGFloat

    func makeNSView(context: Context) -> TrackpadMonitorView { TrackpadMonitorView() }

    func updateNSView(_ view: TrackpadMonitorView, context: Context) {
        view.model = model
        view.backingScale = scale
    }
}

private let zoomLog = Logger(subsystem: "com.fieldframes.mira", category: "zoom")

@MainActor
final class TrackpadMonitorView: NSView {
    weak var model: EditorModel?
    var backingScale: CGFloat = 2
    private var monitor: Any?
    private var lastLog: [String: Date] = [:]

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { [weak self] event in
            // Only plain values cross into the main actor; NSEvent itself is not Sendable.
            nonisolated(unsafe) let event = event
            let consumed = MainActor.assumeIsolated { self?.handle(Input(event: event)) ?? false }
            return consumed ? nil : event
        }
    }

    isolated deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    struct Input: Sendable {
        var isMagnify: Bool
        /// Where the event happened, in Cocoa screen coordinates (bottom-left origin). Scroll events
        /// posted at the HID tap can carry a window number of 0 and a screen-space
        /// `locationInWindow`, so the window is never trusted for containment.
        var screenPoint: CGPoint
        var magnification: Double
        var dx: CGFloat
        var dy: CGFloat
        var precise: Bool

        init(isMagnify: Bool, screenPoint: CGPoint, magnification: Double, dx: CGFloat, dy: CGFloat, precise: Bool) {
            self.isMagnify = isMagnify; self.screenPoint = screenPoint; self.magnification = magnification
            self.dx = dx; self.dy = dy; self.precise = precise
        }

        @MainActor init(event: NSEvent) {
            let point: CGPoint
            if let cg = event.cgEvent, let primary = NSScreen.screens.first {
                // Global display coordinates: top-left origin on the primary display.
                point = CGPoint(x: cg.location.x, y: primary.frame.height - cg.location.y)
            } else if let w = event.window {
                point = w.convertPoint(toScreen: event.locationInWindow)
            } else {
                point = NSEvent.mouseLocation
            }
            if event.type == .magnify {
                self.init(isMagnify: true, screenPoint: point, magnification: Double(event.magnification),
                          dx: 0, dy: 0, precise: true)
            } else {
                self.init(isMagnify: false, screenPoint: point, magnification: 0, dx: event.scrollingDeltaX,
                          dy: event.scrollingDeltaY, precise: event.hasPreciseScrollingDeltas)
            }
        }
    }

    /// One debug line per reason, at most one a second.
    private func reject(_ reason: String, _ detail: String = "") -> Bool {
        let now = Date()
        if let t = lastLog[reason], now.timeIntervalSince(t) < 1 { return false }
        lastLog[reason] = now
        zoomLog.debug("scroll rejected: \(reason, privacy: .public) \(detail, privacy: .public)")
        return false
    }

    /// True when the event was used and must not travel on.
    func handle(_ e: Input) -> Bool {
        guard let model else { return reject("no model") }
        guard model.canZoom else { return reject("cannot zoom") }
        guard !model.eyedropperActive else { return reject("eyedropper active") }
        guard let window else { return reject("no window") }
        let inWindow = window.convertPoint(fromScreen: e.screenPoint)
        let local = convert(inWindow, from: nil)
        guard bounds.contains(local) else {
            return reject("outside view", "local=\(local) bounds=\(bounds) screen=\(e.screenPoint)")
        }
        let pane = CGPoint(x: local.x * backingScale, y: local.y * backingScale)
        if e.isMagnify {
            model.zoomPinch(by: 1 + e.magnification, atPane: pane)
            return true
        }
        guard !model.zoom.isFit else { return reject("at fit") }
        // Points for a trackpad; a wheel reports lines, about ten points each. The system has
        // already applied the natural-direction setting, so the picture follows the fingers.
        let unit: CGFloat = e.precise ? 1 : 10
        model.zoomPan(byPane: CGSize(width: e.dx * unit * backingScale, height: e.dy * unit * backingScale))
        zoomLog.debug("scroll pan dx=\(e.dx, privacy: .public) dy=\(e.dy, privacy: .public) precise=\(e.precise, privacy: .public)")
        return true
    }
}
