import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// The FILMS step. The strip shows one card per stock; tapping a card applies it and swaps the strip
/// for that stock's full options panel, whose back button returns to the strip.
struct FilmsPanel<M: FilmPanelModel, Extra: View>: View {
    @Bindable var model: M
    private let hub = PresetHub.shared
    private let extraRows: Extra

    /// `extraRows` are appended at the end of the options panel (the camera's GRAIN rows); the editor has none.
    init(model: M, @ViewBuilder extraRows: () -> Extra) {
        self.model = model
        self.extraRows = extraRows()
    }

    var body: some View {
        if model.filmsDetail, model.filmID != nil {
            FilmDetailPanel(model: model, hub: hub) { extraRows }
        } else {
            FilmStrip(model: model, hub: hub)
        }
    }
}

extension FilmsPanel where Extra == EmptyView {
    init(model: M) { self.init(model: model) { EmptyView() } }
}

// MARK: Strip

private struct FilmStrip<M: FilmPanelModel>: View {
    @Bindable var model: M
    let hub: PresetHub

    /// Header (1.5 rows) + hairline + gap (0.5 row) + FilmCard (4 + thumbnail + title + caption + 4) + padding.
    private static var stripHeight: CGFloat { T.rows(1.5) + 1 + T.rows(0.5) + FilmCard.thumbnailHeight + 4 + 6 + 22 + T.rows(1) + 4 + 20
        + T.rows(0.5) + T.rows(1) }

    private var familyTabs: [(value: FilmFamily?, title: String)] {
        [(value: nil, title: "ALL")] + model.availableFamilies.map { (value: Optional($0), title: $0.displayName.uppercased()) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Family tabs: ALL plus the families that have stocks, scrolling sideways when they overflow.
            ScrollView(.horizontal, showsIndicators: false) {
                FFTabBar(familyTabs, selection: $model.familyFilter, spacing: T.cells(2))
                    .padding(.horizontal, T.cells(2))
            }
            .frame(height: T.rows(2))
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: T.cells(3)) {
                        // PRESETS always show; the family tab only narrows FILMS.
                        PresetGroup(model: model, hub: hub)
                        StripGroup(title: "FILMS", count: model.visibleStocks.count + 1) {
                            FilmCard(title: "Original", caption: "NO LOOK", image: model.thumbnails["__original"],
                                     isSelected: model.filmID == nil, showsThumbnail: model.showsThumbnails) { model.select(nil) }
                                .task(id: model.thumbEpoch) { await model.requestThumbnail(nil) }
                                .id("__original")
                            ForEach(model.visibleStocks) { film in
                                FilmCard(title: film.stockName ?? film.displayName, caption: film.brand.uppercased(),
                                         image: model.thumbnails[film.id], isSelected: model.selectedStockID == film.stockID,
                                         showsThumbnail: model.showsThumbnails) {
                                    // The applied stock keeps its ISO and variation; any other starts at its base film.
                                    if model.selectedStockID != film.stockID { model.select(film.id) }
                                    withAnimation(.snappy(duration: 0.2)) { model.filmsDetail = true }
                                }
                                .task(id: model.thumbEpoch) { await model.requestThumbnail(film.id) }
                                .id(film.id)
                            }
                        }
                    }
                    .padding(.horizontal, T.cells(2))
                    .padding(.top, T.rows(0.5))
                    .padding(.bottom, T.rows(1))
                }
                // LazyHStack has no usable ideal height, so the strip is sized from its parts: group header,
                // hairline, thumbnail, title and caption rows, plus the padding around them.
                .frame(height: Self.stripHeight)
                .onAppear { scrollToSelection(proxy, animated: false) }
            }
        }
    }

    /// Brings the applied film's card into view (after returning from its options panel).
    private func scrollToSelection(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = model.selectedStock.flatMap({ stock in model.visibleStocks.first { $0.stockID == stock.id }?.id }) else { return }
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }
}

// MARK: Options panel

/// One scrolling panel for the applied stock: title, ISO, variations, film-stage options, preset
/// actions and strength.
private struct FilmDetailPanel<M: FilmPanelModel, Extra: View>: View {
    @Bindable var model: M
    let hub: PresetHub
    @ViewBuilder var extraRows: Extra

    var body: some View {
        CappedScroll {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { model.filmsDetail = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                        Text("FILMS").ffLabel(size: 11)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(T.paper)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to films")
                .padding(.horizontal, T.cells(2))
                header
                stockChips
                FilmOptions(model: model)
                HStack(spacing: T.cells(1)) {
                    Spacer(minLength: 0)
                    Button { hub.importerShown = true } label: { Text("IMPORT").padding(.vertical, 4) }
                        .buttonStyle(.ff)
                    Button { hub.sheet = .save } label: { Text("SAVE PRESET").padding(.vertical, 4) }
                        .buttonStyle(.ff)
                        .disabled(!model.hasPhoto)
                }
                .padding(.horizontal, T.cells(2))
                .padding(.vertical, T.rows(0.5))
                // STRENGTH is the one slider in focus; double-tap resets it to full strength.
                FFSlider("STRENGTH", value: $model.strength, in: 0...1, default: 1)
                    .frame(minHeight: 56)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture(count: 2).onEnded { model.strength = 1 })
                    .padding(.horizontal, T.cells(2))
                    .padding(.bottom, T.rows(0.5))
                extraRows
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(model.selectedStock?.name ?? model.selectedFilm?.displayName ?? "")
                .font(T.display(24, weight: .medium))
                .foregroundStyle(T.paper)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let film = model.selectedFilm {
                Text([film.brand, film.iso > 0 ? "ISO \(film.iso)" : nil, film.family.displayName]
                    .compactMap { $0 }.joined(separator: " \u{00B7} ").uppercased())
                    .ffLabel(size: 9, color: T.paperDim)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, T.cells(2))
        .padding(.bottom, T.rows(0.5))
    }

    /// ISO and VARIATIONS for the applied film's stock; each row is absent when there is only one choice.
    @ViewBuilder private var stockChips: some View {
        let isos = model.isoChoices
        if !isos.isEmpty {
            ChipRow(label: "ISO", selected: isos.first { $0.iso == model.selectedFilm?.iso }?.label) {
                ForEach(isos) { choice in
                    OptionChip(title: choice.label, selected: choice.iso == model.selectedFilm?.iso) { model.selectISO(choice.iso) }
                }
            }
        }
        let variations = model.variationChoices
        if !variations.isEmpty {
            ChipRow(label: "VARIATIONS", selected: variations.first { $0.filmID == model.filmID }?.label) {
                ForEach(variations) { choice in
                    OptionChip(title: choice.label, selected: choice.filmID == model.filmID) { model.select(choice.filmID) }
                }
            }
        }
    }
}

/// Push / pull, scan, paper, exposure time with reciprocity, and (monochrome films) toning for the applied film.
private struct FilmOptions<M: FilmPanelModel>: View {
    @Bindable var model: M

    var body: some View {
        VStack(spacing: 0) {
            if model.recipe.isLegacyPipeline && model.recipe.filmID != nil {
                Text("Made with an earlier Mira; changing film settings updates it to the current film model")
                    .ffLabel(size: 9, color: T.paperDim)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, T.cells(2))
            }
            ChipRow(label: "PUSH", selected: FilmBrowsing.pushSteps.first { abs(model.recipe.push - $0) < 0.01 }.map(FilmBrowsing.pushLabel)) {
                ForEach(FilmBrowsing.pushSteps, id: \.self) { step in
                    OptionChip(title: FilmBrowsing.pushLabel(step), selected: abs(model.recipe.push - step) < 0.01) {
                        model.recipe.push = step
                    }
                }
            }
            ChipRow(label: "SCAN", selected: model.recipe.scanProfile.displayName) {
                ForEach(ScanProfile.allCases, id: \.self) { profile in
                    OptionChip(title: profile.displayName, selected: model.recipe.scanProfile == profile) {
                        model.selectScan(profile)
                    }
                }
            }
            if model.showsPaperChips {
                ChipRow(label: "PAPER", selected: model.recipe.paper.displayName) {
                    ForEach(PaperProfile.allCases, id: \.self) { paper in
                        OptionChip(title: paper.displayName, selected: model.recipe.paper == paper) {
                            model.selectPaper(paper)
                        }
                    }
                }
                Text("Mira originals, inspired by published print behavior. Replaces Scan.")
                    .ffLabel(size: 9, color: T.paperDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, T.cells(2))
                    .padding(.top, 2)
                    .padding(.bottom, T.rows(0.5))
            }
            if model.showsExposureTimeControls {
                FFSlider("EXPOSURE TIME",
                         value: Binding(get: { model.exposureTimeSliderValue },
                                        set: { model.setExposureTime(sliderValue: $0) }),
                         in: ExposureTimeFormat.range, default: model.exposureTimeResetValue,
                         snap: ExposureTimeFormat.step, format: { _ in model.exposureTimeReadout })
                    .frame(minHeight: 44)
                    .padding(.horizontal, T.cells(2))
                ChipRow(label: "RECIP.", selected: model.recipe.reciprocity.displayName) {
                    ForEach(ReciprocityMode.allCases, id: \.self) { mode in
                        OptionChip(title: mode.displayName, selected: model.recipe.reciprocity == mode) {
                            model.recipe.reciprocity = mode
                        }
                    }
                }
                if model.recipe.reciprocity != .off {
                    FFSlider("RECIP. STRENGTH", value: model.bind(\.reciprocityStrength), in: 0...2, default: 1,
                             format: { "\(Int(($0 * 100).rounded())) %" })
                        .frame(minHeight: 44)
                        .padding(.horizontal, T.cells(2))
                }
                if let readout = model.reciprocityReadout {
                    (Text(readout).foregroundStyle(T.paperMid)
                        + Text(model.reciprocityExtrapolated ? " \u{00B7} beyond datasheet" : "")
                            .foregroundStyle(T.paperDim))
                        .ffLabel(size: 9, color: T.paperMid)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, T.cells(2))
                        .accessibilityLabel(readout + (model.reciprocityExtrapolated ? ", beyond datasheet" : ""))
                }
            }
            if model.offersToning {
                ChipRow(label: "TONING", selected: model.recipe.toning.displayName) {
                    ForEach(Toning.allCases, id: \.self) { toning in
                        OptionChip(title: toning.displayName, selected: model.recipe.toning == toning) {
                            model.recipe.toning = toning
                        }
                    }
                }
                if model.recipe.toning != .none {
                    FFSlider("TONING", value: model.bind(\.toningStrength), in: 0...1, default: 0.5)
                        .frame(minHeight: 44)
                        .padding(.horizontal, T.cells(2))
                }
            }
        }
    }
}

/// A mono label followed by a horizontally scrolling row of chips. The label column is wide enough
/// for the longest label (VARIATIONS) and labels never wrap; at accessibility text sizes the label
/// stacks above its chips instead.
struct ChipRow<Content: View>: View {
    let label: String
    /// Id (the chip's title) of the selected chip; the row scrolls it into view when it appears.
    var selected: String?
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var typeSize

    /// "VARIATIONS" at 9 pt mono with 0.1 em tracking is about 63 pt.
    static var labelWidth: CGFloat { 72 }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 0) { labelView; chips }
            } else {
                HStack(spacing: T.cells(1)) { labelView.frame(width: Self.labelWidth, alignment: .leading); chips }
            }
        }
        .padding(.horizontal, T.cells(2))
        .frame(minHeight: 36)
    }

    private var labelView: some View {
        Text(label).ffLabel(size: 9, color: T.paperDim)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .reportFrame("label.\(label)")
    }

    private var chips: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: T.cells(2)) { content }
                    .padding(.trailing, T.cells(1))
            }
            .onAppear { if let selected { DispatchQueue.main.async { proxy.scrollTo(selected, anchor: .center) } } }
            .onChange(of: selected) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
        }
    }
}

/// A tab-bar-style choice: mono label, paper with a lichen underline when selected.
struct OptionChip: View {
    let title: String
    let selected: Bool
    /// Text color while selected (the camera's LOCK chip uses lichen).
    var selectedColor: Color = T.paper
    /// VoiceOver label when the title alone is not enough (the camera's white balance chips).
    var accessibilityLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .ffLabel(size: 10, color: selected ? selectedColor : T.paperDim,
                         weight: selected ? .medium : .regular)
                .lineLimit(1)
                .frame(minWidth: 28, minHeight: 36)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? T.lichen : .clear).frame(height: 1).padding(.bottom, 6)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(title)
        .accessibilityLabel(accessibilityLabel ?? title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
