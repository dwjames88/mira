import MiraCore
import MiraUI
import Observation
import SwiftUI
import UIKit

/// The camera's side of the FILMS panel: owns the camera's `recipe`, the strip's state and the live-frame thumbnails.
/// Same select semantics as `EditorViewModel` so the film door behaves like the editor's FILMS step.
@MainActor @Observable
final class CameraFilmDoorModel: FilmPanelModel {
    /// The camera's recipe; every change is pushed to the finder through `onRecipeChange`.
    var recipe: Recipe {
        didSet {
            guard recipe != oldValue else { return }
            onRecipeChange?(recipe)
        }
    }

    var filmsDetail = false
    var familyFilter: FilmFamily?
    /// Live-frame thumbnails, updated ~2 Hz by the camera. `thumbEpoch` never changes, so cards do not re-run their tasks.
    private(set) var thumbnails: [String: UIImage] = [:]
    let thumbEpoch = 0
    /// Film ids (nil = Original, stored as "__original") the visible cards asked for; the camera's finder renders these.
    @ObservationIgnored private(set) var wantedThumbnailIDs: [String] = []
    /// Called when a card asks for a thumbnail it had not asked for yet (the camera forwards the ids to the finder at once).
    @ObservationIgnored var onWantedChange: (([String]) -> Void)?
    @ObservationIgnored var onRecipeChange: ((Recipe) -> Void)?

    /// A frame always exists in the camera, so presets can be saved from the live recipe.
    var hasPhoto: Bool { true }

    init(recipe: Recipe? = nil) {
        if let recipe {
            self.recipe = recipe
        } else {
            let first = PhotoEngine.library.map { FilmBrowsing.stocks(in: $0, family: nil) }?.first
            self.recipe = Recipe(filmID: first?.id).applyingNativeTexture(filmID: first?.id)
            self.recipe.pipeline = Recipe.currentPipeline
        }
    }

    var strength: Double {
        get { recipe.strength }
        set { recipe.strength = newValue }
    }

    var filmID: String? {
        get { recipe.filmID }
        set { recipe.filmID = newValue }
    }

    /// Same as the editor: a film choice moves to the current pipeline and takes the film's native texture;
    /// push, scan and toning stay as set.
    func select(_ id: String?) {
        var r = recipe
        r.filmID = id
        r.pipeline = Recipe.currentPipeline
        recipe = r.applyingNativeTexture(filmID: id)
    }

    // MARK: Thumbnails

    /// Replaces the thumbnails the finder just rendered (keys are film ids, "__original" for no look).
    func setThumbnails(_ images: [String: CGImage]) {
        for (key, image) in images { thumbnails[key] = UIImage(cgImage: image) }
    }

    /// The door just opened or closed: forget what the old cards asked for.
    func resetWantedThumbnails() { wantedThumbnailIDs = [] }

    func requestThumbnail(_ id: String?) async {
        let key = id ?? "__original"
        guard !wantedThumbnailIDs.contains(key) else { return }
        // Request order is on-screen order: the finder renders the first cards first.
        wantedThumbnailIDs.append(key)
        onWantedChange?(prioritizedWantedIDs)
    }

    /// The wanted ids, the cards around the applied film first (the strip scrolls to it, so those are on screen),
    /// then by distance. A lazy strip that jumps to the selection instantiates every card before it first, so the
    /// order the cards asked in is not the order they are seen in.
    var prioritizedWantedIDs: [String] {
        let order = ["__original"] + visibleStocks.map(\.id)
        var index: [String: Int] = [:]
        for (i, id) in order.enumerated() { index[id] = i }
        let center = selectedStock.flatMap { stock in visibleStocks.firstIndex { $0.stockID == stock.id } }.map { $0 + 1 } ?? 0
        return wantedThumbnailIDs.sorted {
            let a = index[$0] ?? Int.max / 2, b = index[$1] ?? Int.max / 2
            let da = abs(a - center), db = abs(b - center)
            return da != db ? da < db : a < b
        }
    }

    // MARK: Film picker (same rules as the editor)

    var availableFamilies: [FilmFamily] { PhotoEngine.library.map(FilmBrowsing.families(in:)) ?? [] }

    var visibleStocks: [Film] {
        PhotoEngine.library.map { FilmBrowsing.stocks(in: $0, family: familyFilter) } ?? []
    }

    var selectedFilm: Film? { recipe.filmID.flatMap { PhotoEngine.library?.film(id: $0) } }
    var selectedStock: FilmStock? { recipe.filmID.flatMap { PhotoEngine.library?.stock(for: $0) } }
    var selectedStockID: String? { selectedStock?.id }

    var isoChoices: [FilmISOChoice] {
        guard let stock = selectedStock, let lib = PhotoEngine.library else { return [] }
        let choices = lib.isoChoices(stockID: stock.id)
        return choices.count > 1 ? choices : []
    }

    var variationChoices: [FilmVariationChoice] {
        guard let stock = selectedStock, let film = selectedFilm, let lib = PhotoEngine.library else { return [] }
        let choices = lib.variationChoices(stockID: stock.id, iso: film.iso)
        return choices.count > 1 ? choices : []
    }

    func selectISO(_ iso: Int) {
        guard let stock = selectedStock,
              let film = PhotoEngine.library?.film(stockID: stock.id, iso: iso, variation: selectedFilm?.variationLabel)
        else { return }
        select(film.id)
    }

    var offersToning: Bool { FilmBrowsing.offersToning(selectedFilm) }
    var showsPaperChips: Bool { selectedFilm.map { $0.family != .print && !$0.isMonochrome } ?? false }

    func selectScan(_ scan: ScanProfile) {
        recipe.scanProfile = scan
        if scan != .neutral { recipe.paper = .none }
    }

    func selectPaper(_ paper: PaperProfile) {
        recipe.paper = paper
        if paper != .none { recipe.scanProfile = .neutral }
    }

    // MARK: Exposure time (hidden in the camera: the frame's own exposure time is used)

    var showsExposureTimeControls: Bool { false }
    var exposureTimeSliderValue: Double { log2(recipe.exposureTime ?? ExposureTimeFormat.neutral) }
    var exposureTimeResetValue: Double { log2(ExposureTimeFormat.neutral) }
    func setExposureTime(sliderValue v: Double) {}
    var exposureTimeReadout: String { recipe.exposureTime.map { ExposureTimeFormat.label($0) } ?? "FRAME" }
    var reciprocityReadout: String? { nil }
    var reciprocityExtrapolated: Bool { false }
}
