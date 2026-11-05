import MiraCore
import Observation
import SwiftUI
import UIKit

/// What the FILMS strip and options panel (`FilmsPanel`, preset cards, SAVE PRESET) read and write.
/// `EditorViewModel` (a photo's edit) and the camera's `CameraFilmDoorModel` (the live recipe) both conform,
/// so the camera uses the editor's own film-picking pattern instead of a third one.
@MainActor
protocol FilmPanelModel: AnyObject, Observable {
    // Recipe and film
    var recipe: Recipe { get set }
    var filmID: String? { get set }
    var strength: Double { get set }
    /// True when there is something to save a preset from (a photo in the editor; always in the camera).
    var hasPhoto: Bool { get }
    func select(_ id: String?)
    /// Binding into the recipe; writes flow through `recipe`.
    func bind<V>(_ keyPath: WritableKeyPath<Recipe, V>) -> Binding<V>

    // Strip
    var filmsDetail: Bool { get set }
    var familyFilter: FilmFamily? { get set }
    var availableFamilies: [FilmFamily] { get }
    var visibleStocks: [Film] { get }
    var thumbnails: [String: UIImage] { get }
    /// Changes whenever the thumbnails are discarded, so visible cards ask again.
    var thumbEpoch: Int { get }
    func requestThumbnail(_ id: String?) async

    // Options panel
    var selectedFilm: Film? { get }
    var selectedStock: FilmStock? { get }
    var selectedStockID: String? { get }
    var isoChoices: [FilmISOChoice] { get }
    var variationChoices: [FilmVariationChoice] { get }
    func selectISO(_ iso: Int)
    var offersToning: Bool { get }
    var showsPaperChips: Bool { get }
    func selectScan(_ scan: ScanProfile)
    func selectPaper(_ paper: PaperProfile)

    // Exposure time and reciprocity
    /// The camera hides EXPOSURE TIME and RECIP. rows: the frame's own exposure time is used.
    var showsExposureTimeControls: Bool { get }
    var exposureTimeSliderValue: Double { get }
    var exposureTimeResetValue: Double { get }
    func setExposureTime(sliderValue v: Double)
    var exposureTimeReadout: String { get }
    var reciprocityReadout: String? { get }
    var reciprocityExtrapolated: Bool { get }
}

extension FilmPanelModel {
    var showsExposureTimeControls: Bool { true }

    func bind<V>(_ keyPath: WritableKeyPath<Recipe, V>) -> Binding<V> {
        Binding(get: { self.recipe[keyPath: keyPath] }, set: { self.recipe[keyPath: keyPath] = $0 })
    }
}

extension EditorViewModel: FilmPanelModel {}
