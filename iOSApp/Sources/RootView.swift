import MiraCore
import MiraUI
import PhotosUI
import SwiftUI

enum EditorTab: Hashable, CaseIterable { case crop, films, develop, dodgeBurn }

struct RootView: View {
    @State private var model = EditorViewModel()
    @State private var tab: EditorTab = .films
    @State private var pickerItem: PhotosPickerItem?
    @State private var showCamera = false
    private let launch = CameraLaunch.shared
    private let snapshotMode = ProcessInfo.processInfo.environment["MIRA_SNAPSHOT"] == "1"

    private let hub = PresetHub.shared
    private var snapshotFocus: String {
        snapshotMode ? (ProcessInfo.processInfo.environment["MIRA_SNAPSHOT_FOCUS"] ?? "exposure") : "exposure"
    }

    var body: some View {
        content
            .presetPresentations(hub: hub, model: model, enabled: !cameraOpen)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { _ = hub.store.reloadIfChanged(); hub.refresh(); CameraPrints.drain() }
            }
            .onChange(of: launch.cameraRequested) { _, requested in
                if requested { openRequestedCamera() }
            }
            .onAppear {
                CameraPrints.drain()
                if launch.cameraRequested { openRequestedCamera() }
            }
    }

    @Environment(\.scenePhase) private var scenePhase

    /// The camera screen carries its own preset presentations (bound to its film door), so the editor's step aside.
    private var cameraOpen: Bool {
        snapshotMode ? ProcessInfo.processInfo.environment["MIRA_SNAPSHOT_TAB"] == "camera" : showCamera && !model.hasPhoto
    }

    /// The Home Screen quick action: show the camera over whatever is open (the editor closes first).
    private func openRequestedCamera() {
        launch.cameraRequested = false
        if model.hasPhoto { close() }
        showCamera = true
    }

    @ViewBuilder private var content: some View {
        if snapshotMode {
            if ProcessInfo.processInfo.environment["MIRA_SNAPSHOT_TAB"] == "camera" {
                CameraScreen(editor: model, onClose: {})
                    .foregroundStyle(FieldFramesTheme.paper)
                    .tint(FieldFramesTheme.lichen)
            } else {
                editor
            }
        } else {
            // The gallery stays alive under the editor so the NavigationStack path (the user's place
            // in the album list) survives opening and closing a photo.
            ZStack {
                GalleryView(editor: model, onCamera: { showCamera = true })
                    .foregroundStyle(FieldFramesTheme.paper)
                    .tint(FieldFramesTheme.lichen)
                    .allowsHitTesting(!model.hasPhoto && !showCamera)
                    .accessibilityHidden(model.hasPhoto || showCamera)
                // Layered like the editor, so the gallery (and its album path) stays alive underneath.
                if showCamera, !model.hasPhoto {
                    CameraScreen(editor: model, onClose: { showCamera = false })
                        .foregroundStyle(FieldFramesTheme.paper)
                        .tint(FieldFramesTheme.lichen)
                        .transition(.identity)
                }
                if model.hasPhoto { editor.transition(.identity) }
            }
        }
    }

    private var editor: some View {
        EditorScaffold(model: model, tab: $tab, onClose: close) {
            canvas
        } panel: {
            controls
        }
        .foregroundStyle(FieldFramesTheme.paper)
        .tint(FieldFramesTheme.lichen)
        .onChange(of: tab) { old, new in
            if new == .crop { model.beginCrop() }
            else if old == .crop { model.commitCrop() }
        }
        .task {
            let env = ProcessInfo.processInfo.environment
            guard env["MIRA_SNAPSHOT"] == "1" else { return }
            await model.loadSnapshotFixture()
            if env["MIRA_SNAPSHOT_TAB"] == "films" {
                model.select(PhotoEngine.filmList.first?.id)
                tab = .films
                // Seed one preset so the PRESETS group has a card (headless; no taps).
                if hub.presets.isEmpty {
                    _ = try? hub.save(nickname: "Last Summer", recipe: model.recipe, filmName: model.currentFilmName)
                }
                if env["MIRA_SNAPSHOT_SHEET"] == "savepreset" { hub.sheet = .save }
                if env["MIRA_SNAPSHOT_DETAIL"] == "1" { model.filmsDetail = true }
            } else {
                tab = .develop
            }
            if env["MIRA_SNAPSHOT_HIDDEN"] == "1" { model.panelHidden[tab] = true }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await model.pick(item) }
        }
    }

    private func close() { tab = .films; model.closePhoto() }

    @GestureState private var holding = false
    @State private var pinchBase: CGFloat = 1
    @State private var panBase: CGSize = .zero

    @ViewBuilder private var canvas: some View {
        Group {
            if model.hasPhoto {
                GeometryReader { geo in
                    MetalPreviewView(live: model.live, recipe: model.liveRecipe, zoom: model.zoom,
                                     offset: model.offset, showingOriginal: model.showingOriginal,
                                     cropping: model.isCropping)
                        .overlay { if model.isCropping { CropOverlayView(model: model) } }
                        .contentShape(Rectangle())
                        .gesture(model.isCropping ? nil : canvasGestures(size: geo.size))
                }
                .padding(.horizontal, 2)
                .onChange(of: holding) { _, now in model.showingOriginal = now && !model.isCropping }
            } else {
                FFEmptyState(title: "Mira", subtitle: "CHOOSE A PHOTO TO BEGIN")
                    .overlay(alignment: .bottom) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Text("CHOOSE PHOTO")
                        }
                        .buttonStyle(.ffProminent)
                        .padding(.bottom, FieldFramesTheme.rows(2))
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func canvasGestures(size: CGSize) -> some Gesture {
        let pinch = MagnificationGesture()
            .onChanged { value in
                let z = min(max(pinchBase * value, 1), 6)
                model.zoom = z
                model.offset = clamped(model.offset, zoom: z, size: size)
            }
            .onEnded { _ in
                pinchBase = model.zoom
                model.live.updateProxyTarget(zoom: model.zoom)
            }
        let pan = DragGesture(minimumDistance: 4)
            .onChanged { value in
                guard model.zoom > 1 else { return }
                let next = CGSize(width: panBase.width + value.translation.width,
                                  height: panBase.height + value.translation.height)
                model.offset = clamped(next, zoom: model.zoom, size: size)
            }
            .onEnded { _ in panBase = model.offset }
        let hold = LongPressGesture(minimumDuration: 0.25, maximumDistance: 12)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
        return pinch.simultaneously(with: pan).simultaneously(with: hold)
    }

    private func clamped(_ o: CGSize, zoom: CGFloat, size: CGSize) -> CGSize {
        let mx = size.width * (zoom - 1) / 2, my = size.height * (zoom - 1) / 2
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }

    @ViewBuilder private var controls: some View {
        switch tab {
        case .crop: CappedScroll { CropTab(model: model) }
        case .films: FilmsPanel(model: model)
        case .develop: DevelopPanel(model: model, focus: snapshotFocus)
        case .dodgeBurn: CappedScroll { DodgeBurnTab(model: model) }
        }
    }
}

struct ChooseLabel: View {
    var body: some View { Text("CHOOSE").ffLabel(size: 11) }
}
