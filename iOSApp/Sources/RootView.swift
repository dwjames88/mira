import MiraCore
import MiraUI
import PhotosUI
import SwiftUI

enum EditorTab: Hashable { case films, develop, crop }

struct RootView: View {
    @State private var model = EditorViewModel()
    @State private var tab: EditorTab = .films
    @State private var pickerItem: PhotosPickerItem?
    private let snapshotMode = ProcessInfo.processInfo.environment["MIRA_SNAPSHOT"] == "1"

    private let hub = PresetHub.shared

    var body: some View {
        content
            .presetPresentations(hub: hub, model: model)
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { _ = hub.store.reloadIfChanged(); hub.refresh() }
            }
    }

    @Environment(\.scenePhase) private var scenePhase

    @ViewBuilder private var content: some View {
        if snapshotMode {
            editor
        } else {
            // The gallery stays alive under the editor so the NavigationStack path (the user's place
            // in the album list) survives opening and closing a photo.
            ZStack {
                GalleryView(editor: model)
                    .foregroundStyle(FieldFramesTheme.paper)
                    .tint(FieldFramesTheme.lichen)
                    .allowsHitTesting(!model.hasPhoto)
                    .accessibilityHidden(model.hasPhoto)
                if model.hasPhoto { editor.transition(.identity) }
            }
        }
    }

    private var editor: some View {
        ZStack {
            FFGroundBackground(grain: 0.07).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                FFHairline()
                canvas
                FFHairline()
                tabBar
                FFHairline()
                controls
            }
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
            } else {
                tab = .develop
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await model.pick(item) }
        }
    }

    @State private var confirmClose = false

    /// Back affordance (chevron + LIBRARY) on the left, status in the middle, Save state on the right.
    private var header: some View {
        HStack(spacing: FieldFramesTheme.cells(1)) {
            Button {
                if model.hasUnsavedEdits { confirmClose = true } else { close() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                    Text("LIBRARY").ffLabel(size: 11)
                }
                .foregroundStyle(FieldFramesTheme.paper)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to library")
            Spacer(minLength: 0)
            Text(model.status).ffLabel(size: 9, color: FieldFramesTheme.paperDim).lineLimit(1)
            saveButton
        }
        .padding(.horizontal, FieldFramesTheme.cells(2))
        .frame(height: 48)
        .confirmationDialog("Discard unsaved edits?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Discard and go back", role: .destructive) { close() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private func close() { tab = .films; model.closePhoto() }

    /// UNSAVED = prominent lichen SAVE; SAVING = inert; SAVED = dim, inert.
    @ViewBuilder private var saveButton: some View {
        switch model.saveState {
        case .unsaved:
            Button { Task { await model.save() } } label: {
                Text(model.saveTitle).padding(.vertical, 6).frame(minWidth: 44)
            }
            .buttonStyle(.ffProminent)
            .disabled(!model.hasPhoto)
        case .saving:
            Text(model.saveTitle).ffLabel(size: 10, color: FieldFramesTheme.paperMid, weight: .medium)
                .padding(.horizontal, FieldFramesTheme.cells(2)).frame(minHeight: 44)
        case .saved:
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold))
                Text(model.saveTitle).ffLabel(size: 10, color: FieldFramesTheme.paperDim)
            }
            .foregroundStyle(FieldFramesTheme.paperDim)
            .padding(.horizontal, FieldFramesTheme.cells(1)).frame(minHeight: 44)
            .accessibilityElement(children: .combine)
        }
    }

    /// Equal-width 48pt tabs, hairline-underlined; the photo keeps the rest of the screen.
    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach([(EditorTab.films, "FILMS"), (.develop, "DEVELOP"), (.crop, "CROP")], id: \.0) { item in
                let selected = tab == item.0
                Button { tab = item.0 } label: {
                    Text(item.1)
                        .ffLabel(size: 11, color: selected ? FieldFramesTheme.paper : FieldFramesTheme.paperDim,
                                 weight: selected ? .medium : .regular)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? FieldFramesTheme.lichen : .clear).frame(height: 2)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

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
                let scale = UIScreen.main.scale
                model.live.updateProxyTarget(
                    pixelSize: CGSize(width: size.width * scale, height: size.height * scale), zoom: model.zoom)
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
        case .films: FilmsPanel(model: model)
        case .develop: DevelopPanel(model: model)
        case .crop: CropTab(model: model)
        }
    }
}

struct FilmsPanel: View {
    @Bindable var model: EditorViewModel
    @State private var optionsOpen = false
    private let hub = PresetHub.shared

    private var familyTabs: [(value: FilmFamily?, title: String)] {
        [(value: nil, title: "ALL")] + model.availableFamilies.map { (value: Optional($0), title: $0.displayName.uppercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Family tabs: ALL plus the families that have stocks, scrolling sideways when they overflow.
            ScrollView(.horizontal, showsIndicators: false) {
                FFTabBar(familyTabs, selection: $model.familyFilter, spacing: FieldFramesTheme.cells(2))
                    .padding(.horizontal, FieldFramesTheme.cells(2))
            }
            .frame(height: FieldFramesTheme.rows(2))
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: FieldFramesTheme.cells(3)) {
                    // PRESETS always show; the family tab only narrows FILMS.
                    PresetGroup(model: model, hub: hub)
                    StripGroup(title: "FILMS", count: model.visibleStocks.count + 1) {
                        FilmCard(title: "Original", caption: "NO LOOK", image: model.thumbnails["__original"],
                                 isSelected: model.filmID == nil) { model.select(nil) }
                            .task(id: model.thumbEpoch) { await model.requestThumbnail(nil) }
                        ForEach(model.visibleStocks) { film in
                            FilmCard(title: film.displayName, caption: "\(film.brand.uppercased()) · ISO \(film.iso)",
                                     image: model.thumbnails[film.id], isSelected: model.selectedStockID == film.id) {
                                model.select(film.id)
                            }
                            .task(id: model.thumbEpoch) { await model.requestThumbnail(film.id) }
                        }
                    }
                }
                .padding(.horizontal, FieldFramesTheme.cells(2))
                .padding(.vertical, FieldFramesTheme.rows(0.5))
            }
            variantRow
            HStack(spacing: FieldFramesTheme.cells(1)) {
                Button { withAnimation(.snappy(duration: 0.2)) { optionsOpen.toggle() } } label: {
                    Text(optionsOpen ? "OPTIONS \u{2212}" : "OPTIONS +").padding(.vertical, 4)
                }
                .buttonStyle(.ff)
                .disabled(model.filmID == nil)
                Spacer(minLength: 0)
                Button { hub.importerShown = true } label: { Text("IMPORT").padding(.vertical, 4) }
                    .buttonStyle(.ff)
                Button { hub.sheet = .save } label: { Text("SAVE PRESET").padding(.vertical, 4) }
                    .buttonStyle(.ff)
                    .disabled(!model.hasPhoto)
            }
            .padding(.horizontal, FieldFramesTheme.cells(2))
            if optionsOpen, model.filmID != nil { FilmOptions(model: model) }
            // STRENGTH is the one slider in focus; double-tap resets it to full strength.
            FFSlider("STRENGTH", value: $model.strength, in: 0...1, default: 1)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { model.strength = 1 })
                .padding(.horizontal, FieldFramesTheme.cells(2))
                .disabled(model.filmID == nil)
        }
        .padding(.bottom, FieldFramesTheme.rows(0.5))
    }

    /// Base, -1, +1, Cold +1 ... for the applied film's stock; absent when the stock has no variants.
    @ViewBuilder private var variantRow: some View {
        let choices = model.variantChoices
        if !choices.isEmpty {
            ChipRow(label: "VARIANT") {
                ForEach(choices) { choice in
                    OptionChip(title: choice.label, selected: choice.id == model.filmID) { model.select(choice.id) }
                }
            }
        }
    }
}

/// Push / pull, scan and (monochrome films) toning for the applied film. Compact: one scrolling row each.
private struct FilmOptions: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            ChipRow(label: "PUSH") {
                ForEach(FilmBrowsing.pushSteps, id: \.self) { step in
                    OptionChip(title: FilmBrowsing.pushLabel(step), selected: abs(model.recipe.push - step) < 0.01) {
                        model.recipe.push = step
                    }
                }
            }
            ChipRow(label: "SCAN") {
                ForEach(ScanProfile.allCases, id: \.self) { profile in
                    OptionChip(title: profile.displayName, selected: model.recipe.scanProfile == profile) {
                        model.recipe.scanProfile = profile
                    }
                }
            }
            if model.offersToning {
                ChipRow(label: "TONING") {
                    ForEach(Toning.allCases, id: \.self) { toning in
                        OptionChip(title: toning.displayName, selected: model.recipe.toning == toning) {
                            model.recipe.toning = toning
                        }
                    }
                }
                if model.recipe.toning != .none {
                    FFSlider("TONING", value: model.bind(\.toningStrength), in: 0...1, default: 0.5)
                        .frame(minHeight: 44)
                        .padding(.horizontal, FieldFramesTheme.cells(2))
                }
            }
        }
    }
}

/// A mono label followed by a horizontally scrolling row of chips.
private struct ChipRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: FieldFramesTheme.cells(2)) {
            Text(label).ffLabel(size: 9, color: FieldFramesTheme.paperDim)
                .frame(width: 56, alignment: .leading)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: FieldFramesTheme.cells(2)) { content }
            }
        }
        .padding(.horizontal, FieldFramesTheme.cells(2))
        .frame(height: 36)
    }
}

/// A tab-bar-style choice: mono label, paper with a lichen underline when selected.
private struct OptionChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .ffLabel(size: 10, color: selected ? FieldFramesTheme.paper : FieldFramesTheme.paperDim,
                         weight: selected ? .medium : .regular)
                .lineLimit(1)
                .frame(minWidth: 28, minHeight: 36)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? FieldFramesTheme.lichen : .clear).frame(height: 1).padding(.bottom, 6)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ChooseLabel: View {
    var body: some View { Text("CHOOSE").ffLabel(size: 11) }
}
