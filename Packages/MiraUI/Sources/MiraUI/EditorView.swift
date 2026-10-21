import MiraCore
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
                        footer
                    }
                }
                if !model.isImmersive {
                    FFHairline(.vertical)
                    panel
                        .frame(width: T.cells(36))
                }
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .background { if model.isImmersive { T.inkAlways } }
        .fieldFramesWindow()
        .background {
            if !imageCanvas { EditorKeyHost(model: model, windowFullScreen: windowFullScreen)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true) }
        }
    }

    @ViewBuilder private var panel: some View {
        switch model.tab {
        case .films: FilmsPanel(model: model)
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

    @ViewBuilder
    private func canvas(_ frame: PreviewFrame) -> some View {
        if imageCanvas, let image = model.displayedImage {
            Image(nsImage: image).resizable().interpolation(.high)
        } else {
            FrameCanvas(frame: frame)
        }
    }

    var body: some View {
        ZStack {
            // The photograph sits on plain ink: no grain, no veil over it.
            (model.isImmersive ? T.inkAlways : T.ink)
            if let frame = model.displayedFrame {
                canvas(frame)
                    .aspectRatio(frame.pixelSize, contentMode: .fit)
                    .padding(T.cells(3))
                    .accessibilityLabel(model.showOriginal ? "Original photo" : "Edited photo")
                if model.isCropping {
                    CropOverlay(model: model)
                        .padding(T.cells(3))
                }
            } else {
                Text("Developing").ffLabel()
            }
        }
        .overlay(alignment: .topLeading) {
            if let name = model.hoverPreviewName {
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
            if !model.isCropping {
                CompareButton(model: model)
                    .padding(T.cells(2))
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            paneSize = size
            // The picture area is the pane minus its padding; previews are rendered at that size in pixels.
            let inset = T.cells(3) * 2
            model.setCanvas(pixels: CGSize(width: max(1, size.width - inset) * displayScale,
                                           height: max(1, size.height - inset) * displayScale))
        }
        .contentShape(Rectangle())
        .gesture(holdToCompare(model), isEnabled: !model.isCropping && !model.eyedropperActive)
        .gesture(
            SpatialTapGesture().onEnded { tap in
                guard let frame = model.displayedFrame,
                      let p = PreviewHitMapping.normalizedPoint(tap.location, pane: paneSize, inset: T.cells(3),
                                                                image: frame.pixelSize) else {
                    model.eyedropperActive = false
                    return
                }
                model.sampleRange(atImagePoint: p)
            },
            isEnabled: model.eyedropperActive && !model.isCropping)
        .pointerStyle(model.eyedropperActive ? .rectSelection : .default)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(model.isCropping ? "" : "Press and hold to see the original")
    }
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
        VStack(alignment: .leading, spacing: 0) {
            FFTabBar(tabs, selection: $model.familyFilter)
                .padding(.horizontal, T.cells(2))
            FFHairline()
            FFScrollView(.horizontal) {
                HStack(alignment: .top, spacing: T.cells(1)) {
                    FilmCard(
                        title: "Original", caption: "No film",
                        image: model.thumbnails[EditorModel.originalTileID],
                        isSelected: model.recipe.filmID == nil,
                        onHoverChange: { hover($0, nil) }
                    ) { model.selectFilm(nil) }

                    ForEach(model.visibleFilms) { film in
                        FilmCard(
                            title: film.displayName,
                            caption: caption(for: film),
                            image: model.thumbnails[film.id],
                            isSelected: model.recipe.filmID == film.id,
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
