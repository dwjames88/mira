import MiraCore
import MiraUI
import Photos
import PhotosUI
import SwiftUI
import UIKit

@MainActor @Observable
final class EditorViewModel {
    let live = LivePreview()
    /// Realtime view state driven by canvas gestures.
    var zoom: CGFloat = 1
    var offset: CGSize = .zero
    var showingOriginal = false
    private(set) var thumbnails: [String: UIImage] = [:]
    /// Changes whenever the thumbnails are discarded (a new photo), so visible cards ask again.
    private(set) var thumbEpoch = 0
    @ObservationIgnored private var thumbInFlight: Set<String> = []
    private(set) var hasPhoto = false
    private(set) var isSaving = false
    private(set) var status = ""
    private(set) var histogram: HistogramData = .empty
    private(set) var sourcePixelSize: CGSize = .zero
    private(set) var isCropping = false
    /// Crop being edited while `isCropping`; committed to `recipe.crop` by `commitCrop()`.
    var workingCrop = CropSettings.identity

    /// Steps whose control panel the user folded away to see the whole photo. Per step, kept while editing, not persisted.
    var panelHidden: [EditorTab: Bool] = [:]
    /// FILMS step: true while the applied stock's full options panel replaces the card strip.
    var filmsDetail = false
    /// A library asset another screen (the camera's last-frame thumbnail) wants opened. The gallery picks it up and opens
    /// it through its own path, so the open gets the same OPENING state, Photos backstop and failure card.
    var pendingLibraryOpen: PHAsset?

    /// Single source of truth for every edit.
    var recipe: Recipe {
        didSet {
            guard recipe != oldValue else { return }
            // A pipeline-2-only control changed on a legacy recipe: move it to the current pipeline in the same edit.
            if !isRestoring { recipe.upgradePipelineIfFilmScienceChanged(from: oldValue) }
            if !isRestoring, saveState != .saving { saveState = .unsaved }
            scheduleHistogram()
            // A film changes how the RAW is developed (automatic boost and range), so develop it again.
            if !isRestoring, rawAsset, (recipe.filmID != nil) != (oldValue.filmID != nil) || recipe.raw != oldValue.raw {
                scheduleRawDevelop(debounce: Self.rawDevelopDebounce(from: oldValue, to: recipe))
            }
        }
    }

    /// Where Save writes: back to the library asset (non-destructive) or a new asset (imports).
    enum EditTarget {
        case asset(AssetEditSession)
        case imported
    }

    /// Edit state of the open photo; flips to `.unsaved` whenever `recipe` changes.
    enum SaveState {
        case unsaved, saving, saved
        var title: String {
            switch self {
            case .unsaved: "SAVE"
            case .saving: "SAVING"
            case .saved: "SAVED"
            }
        }
    }

    private(set) var editTarget: EditTarget = .imported
    /// Starts `.saved`: a freshly opened photo has nothing to write.
    private(set) var saveState: SaveState = .saved
    var saveTitle: String { saveState.title }
    var hasUnsavedEdits: Bool { saveState == .unsaved }
    private(set) var isLibraryAsset = false
    /// Local identifier of the open library photo (nil for imports and the sample).
    var libraryAssetID: String? { if case .asset(let session) = editTarget { session.asset.localIdentifier } else { nil } }
    /// Suppresses the unsaved flag while the recipe is set from stored adjustments / reset on open.
    @ObservationIgnored private var isRestoring = false

    /// Recipe handed to the Metal view; while cropping it carries the working crop.
    var liveRecipe: Recipe {
        var r = recipe
        if isCropping { r.crop = workingCrop }
        return r
    }

    var strength: Double {
        get { recipe.strength }
        set { recipe.strength = newValue }
    }
    var filmID: String? {
        get { recipe.filmID }
        set { recipe.filmID = newValue }
    }

    private let engine = PhotoEngine()
    /// True while the open library asset is developed from its RAW original.
    @ObservationIgnored private var rawAsset = false
    /// Which camera-raw controls the Develop panel shows for the open photo (none unless it is a RAW).
    private(set) var rawControls: RawControlVisibility = .none
    /// The open RAW's as-shot white balance (kelvin, tint); nil for anything else.
    private(set) var rawAsShot: (temperature: Double, tint: Double)?
    @ObservationIgnored private var rawTask: Task<Void, Never>?
    /// Bumped by every open; a load that finishes after a newer one started is dropped.
    @ObservationIgnored private var openGeneration = 0
    private var histogramTask: Task<Void, Never>?

    init() { recipe = Recipe() }

    /// Applies a film (or Original). A film choice moves the recipe to the current rendering pipeline,
    /// as on the Mac; push, scan and toning stay as the user set them.
    func select(_ id: String?) {
        var r = recipe
        r.filmID = id
        r.pipeline = Recipe.currentPipeline
        recipe = r.applyingNativeTexture(filmID: id)   // grain, halation, bloom at the new film's own level
    }

    // MARK: Film picker

    /// The family tab; nil = ALL. Only shapes which stock cards the strip shows.
    var familyFilter: FilmFamily?

    var availableFamilies: [FilmFamily] { PhotoEngine.library.map(FilmBrowsing.families(in:)) ?? [] }

    /// One card per stock for the current tab, shown as its base film (ISOs and variations are chip rows).
    var visibleStocks: [Film] {
        PhotoEngine.library.map { FilmBrowsing.stocks(in: $0, family: familyFilter) } ?? []
    }

    var selectedFilm: Film? { recipe.filmID.flatMap { PhotoEngine.library?.film(id: $0) } }

    /// The stock of the applied film (any concrete film id resolves to it); nil for Original.
    var selectedStock: FilmStock? { recipe.filmID.flatMap { PhotoEngine.library?.stock(for: $0) } }

    var selectedStockID: String? { selectedStock?.id }

    /// ISO chips of the applied film's stock; empty when the stock has a single ISO.
    var isoChoices: [FilmISOChoice] {
        guard let stock = selectedStock, let lib = PhotoEngine.library else { return [] }
        let choices = lib.isoChoices(stockID: stock.id)
        return choices.count > 1 ? choices : []
    }

    /// Variations chips at the applied film's ISO; empty when there is only one.
    var variationChoices: [FilmVariationChoice] {
        guard let stock = selectedStock, let film = selectedFilm, let lib = PhotoEngine.library else { return [] }
        let choices = lib.variationChoices(stockID: stock.id, iso: film.iso)
        return choices.count > 1 ? choices : []
    }

    /// Applies an ISO chip: that ISO with the current variation where it exists, else Standard.
    func selectISO(_ iso: Int) {
        guard let stock = selectedStock,
              let film = PhotoEngine.library?.film(stockID: stock.id, iso: iso, variation: selectedFilm?.variationLabel)
        else { return }
        select(film.id)
    }

    var offersToning: Bool { FilmBrowsing.offersToning(selectedFilm) }

    // MARK: Paper (Mira originals; same rules as the Mac panel)

    /// Paper is offered for every film except the print cards and monochrome films.
    var showsPaperChips: Bool { selectedFilm.map { $0.family != .print && !$0.isMonochrome } ?? false }

    /// Scan and Paper are mutually exclusive: choosing a scan other than Neutral clears the paper.
    func selectScan(_ scan: ScanProfile) {
        recipe.scanProfile = scan
        if scan != .neutral { recipe.paper = .none }
    }

    func selectPaper(_ paper: PaperProfile) {
        recipe.paper = paper
        if paper != .none { recipe.scanProfile = .neutral }
    }

    // MARK: Exposure time and reciprocity

    /// The open photo's EXIF exposure time in seconds; nil when it has none.
    private(set) var sourceExposureTime: Double?

    var effectiveExposureTime: Double? { recipe.exposureTime ?? sourceExposureTime }

    var reciprocityEffect: ReciprocityEffect? {
        Reciprocity.effect(for: recipe, film: selectedFilm, sourceExposureTime: sourceExposureTime)
    }
    var reciprocityReadout: String? {
        ReciprocityFormat.summary(recipe: recipe, film: selectedFilm, sourceExposureTime: sourceExposureTime)?.text
    }
    var reciprocityExtrapolated: Bool {
        ReciprocityFormat.summary(recipe: recipe, film: selectedFilm, sourceExposureTime: sourceExposureTime)?.beyondDatasheet ?? false
    }

    var exposureTimeSliderValue: Double { log2(effectiveExposureTime ?? ExposureTimeFormat.neutral) }

    /// The slider position of "no override": the standard speed nearest the EXIF time (1/125 s without EXIF).
    var exposureTimeResetValue: Double {
        log2(sourceExposureTime.map { ExposureTimeFormat.standard(nearestTo: $0) } ?? ExposureTimeFormat.neutral)
    }

    func setExposureTime(sliderValue v: Double) {
        let t = ExposureTimeFormat.standard(nearestTo: exp2(v))
        let unchanged = sourceExposureTime.map { ExposureTimeFormat.standard(nearestTo: $0) } ?? ExposureTimeFormat.neutral
        let newValue: Double? = t == unchanged ? nil : t
        if recipe.exposureTime != newValue { recipe.exposureTime = newValue }
    }

    func resetExposureTime() { recipe.exposureTime = nil }

    var exposureTimeReadout: String {
        if let t = recipe.exposureTime { return ExposureTimeFormat.label(t) }
        if let t = sourceExposureTime { return ExposureTimeFormat.label(t) + " \u{00B7} EXIF" }
        return "NO EXIF"   // caps like every other readout (the Mac shows "No EXIF")
    }

    /// Binding into the recipe for DEVELOP controls; writes flow through `recipe`'s didSet.
    func bind<V>(_ keyPath: WritableKeyPath<Recipe, V>) -> Binding<V> {
        Binding(get: { self.recipe[keyPath: keyPath] }, set: { self.recipe[keyPath: keyPath] = $0 })
    }

    private func clearRawInfo() {
        rawControls = .none
        rawAsShot = nil
    }

    /// Test seam: shows the RAW-only Develop controls without a PhotoKit asset. Does not enable re-developing.
    func setRawInfoForTesting(asShot: (temperature: Double, tint: Double)?, supported: RawSupportedControls) {
        rawControls = RawControlVisibility(isRaw: asShot != nil, supported: supported)
        rawAsShot = asShot
    }

    /// The one temperature / tint pair: camera white balance for a RAW, pipeline balance otherwise.
    var whiteBalance: WhiteBalanceControl { WhiteBalanceControl(isRaw: rawControls.isRaw, asShot: rawAsShot) }

    func bindTemperature() -> Binding<Double> {
        Binding(get: { self.whiteBalance.temperature(of: self.recipe) },
                set: { k in var r = self.recipe; self.whiteBalance.setTemperature(k, in: &r); self.recipe = r })
    }

    func bindTint() -> Binding<Double> {
        Binding(get: { self.whiteBalance.tint(of: self.recipe) },
                set: { t in var r = self.recipe; self.whiteBalance.setTint(t, in: &r); self.recipe = r })
    }

    func resetWhiteBalance() {
        var r = recipe
        WhiteBalanceControl.resetToAsShot(&r)
        recipe = r
    }

    /// A RAW setting shown as a slider: while nil ("Auto") it rests at `fallback`; moving it back onto the fallback clears it.
    func bindRaw(_ kp: WritableKeyPath<RawSettings, Double?>, fallback: Double) -> Binding<Double> {
        Binding(get: { self.recipe.raw[keyPath: kp] ?? fallback },
                set: { v in self.recipe.raw[keyPath: kp] = abs(v - fallback) <= 0.005 ? nil : v })
    }

    /// Resets every develop control; keeps film and crop.
    func resetDevelop() {
        recipe = Recipe(filmID: recipe.filmID, crop: recipe.crop)
    }

    var canResetDevelop: Bool { recipe != Recipe(filmID: recipe.filmID, crop: recipe.crop) }

    func beginCrop() {
        guard hasPhoto, !isCropping else { return }
        workingCrop = recipe.crop
        isCropping = true
        zoom = 1; offset = .zero
    }

    func commitCrop() {
        guard isCropping else { return }
        isCropping = false
        recipe.crop = workingCrop
    }

    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
    }

    func pick(_ item: PhotosPickerItem) async {
        status = "LOADING"
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                status = "THAT PHOTO COULD NOT BE LOADED"; return
            }
            try await ingest(data)
        } catch {
            status = "ERROR · \(error.localizedDescription.uppercased())"
        }
    }

    /// Snapshot harness: loads the bundled fixture through the same path as a picked photo.
    /// No PhotosPicker, no user input. Applies a small exposure lift so the editor shows an edit.
    func loadSnapshotFixture() async {
        guard let url = Bundle.main.url(forResource: "sample", withExtension: "jpg"),
              let data = try? Data(contentsOf: url) else {
            status = "SNAPSHOT FIXTURE MISSING"; return
        }
        do {
            try await ingest(data)
            recipe.exposure = 0.35
        } catch {
            status = "ERROR · \(error.localizedDescription.uppercased())"
        }
    }

    /// Opens full image data from the gallery in the editor.
    func openData(_ data: Data) async {
        status = "LOADING"
        do { try await ingest(data) } catch { status = "ERROR · \(error.localizedDescription.uppercased())" }
    }

    /// Opens a library asset non-destructively: the ORIGINAL pixels become the base and any stored
    /// Mira recipe is restored on top, so a saved edit reopens exactly and stays adjustable.
    @discardableResult
    func openAsset(_ asset: PHAsset, onEvent: @escaping @Sendable (EditingInputEvent) -> Void = { _ in }) async -> OpenResult {
        status = "LOADING"
        openGeneration += 1
        let generation = openGeneration
        let session = makeSession(asset)
        do {
            let loaded = try await session.load(onEvent: onEvent)
            guard generation == openGeneration else { return .superseded }
            let adopted = LoadedSource(image: loaded.source, colorSpace: loaded.colorSpace, size: loaded.size)
            try await engine.adopt(adopted)
            // A newer open (another asset or a picked photo) started while this one loaded: it wins.
            guard generation == openGeneration else { return .superseded }
            live.setSource(loaded.source, colorSpace: loaded.colorSpace, size: loaded.size)
            sourceExposureTime = loaded.source.miraExposureTime
            sourcePixelSize = loaded.size
            zoom = 1; offset = .zero; showingOriginal = false
            hasPhoto = true
            isCropping = false
            isRestoring = true
            recipe = loaded.recipe
            isRestoring = false
            editTarget = .asset(session)
            isLibraryAsset = true
            saveState = .saved
            thumbnails = [:]
            if !loaded.isFullSize {
                status = "PREVIEW ONLY · FULL SIZE UNAVAILABLE"
            } else if let foreign = loaded.foreignFormat {
                status = "EDITED IN ANOTHER APP (\(foreign)) · STARTING FROM ORIGINAL"
            } else {
                status = loaded.rawNote ?? ""
            }
            rawAsset = loaded.isRaw
            if loaded.isRaw, let info = session.rawInfo {
                rawControls = RawControlVisibility(isRaw: true, supported: info.supported)
                rawAsShot = info.asShot
            } else {
                clearRawInfo()
            }
            thumbnailsFilmApplied = loaded.recipe.filmID != nil
            scheduleHistogram()
            startThumbnails()
            if loaded.isRaw { scheduleRawDevelop(draftFirst: false) }
            return .opened
        } catch {
            guard generation == openGeneration else { return .superseded }
            status = "ERROR · \(error.localizedDescription.uppercased())"
            return .failed(error)
        }
    }

    enum OpenResult {
        case opened, superseded, failed(Error)
    }

    /// Test seam: how a library asset gets its edit session.
    @ObservationIgnored var makeSession: (PHAsset) -> AssetEditSession = { AssetEditSession(asset: $0) }

    /// Develops the RAW again for the current recipe off the main actor and swaps it in: a draft at preview
    /// size first (unless `draftFirst` is false), then the full-quality full-size develop. Newer requests win.
    private func scheduleRawDevelop(draftFirst: Bool = true, debounce: Duration = .milliseconds(120)) {
        guard case .asset(let session) = editTarget else { return }
        rawTask?.cancel()
        rawTask = Task { [weak self] in
            guard let self else { return }
            if draftFirst {
                // A slider drag coalesces; a film tap is one discrete change and starts at once.
                if debounce > .zero { try? await Task.sleep(for: debounce) }
                guard !Task.isCancelled else { return }
                let applied = self.recipe.filmID != nil
                if let draft = await session.rawSource(for: self.recipe, full: false) {
                    await self.adoptRaw(draft, session, filmApplied: applied)
                }
            }
            guard !Task.isCancelled else { return }
            let applied = self.recipe.filmID != nil
            if let full = await session.rawSource(for: self.recipe, full: true) {
                await self.adoptRaw(full, session, filmApplied: applied)
            } else if !Task.isCancelled, self.hasPhoto {
                self.status = "RAW DEVELOP FAILED · SHOWING THE LAST PREVIEW"
            }
        }
    }

    /// No wait when the film was toggled (a tap); the usual 120 ms while RAW settings change (a slider drag).
    static func rawDevelopDebounce(from old: Recipe, to new: Recipe) -> Duration {
        (old.filmID != nil) != (new.filmID != nil) ? .zero : .milliseconds(120)
    }

    /// Whether the film thumbnails (and the engine's small source behind them) come from a develop with the film applied.
    @ObservationIgnored private(set) var thumbnailsFilmApplied = false

    /// A develop with a different film-applied state than the one the thumbnails were rendered from (automatic boost
    /// and range depend on it) invalidates them, so the strip never mixes film-off and film-on develops. The draft to
    /// full swap of the same state does not.
    func noteThumbnailSource(filmApplied: Bool) {
        guard filmApplied != thumbnailsFilmApplied else { return }
        thumbnailsFilmApplied = filmApplied
        thumbnails = [:]
        startThumbnails()
    }

    private func adoptRaw(_ loaded: LoadedSource, _ session: AssetEditSession, filmApplied: Bool) async {
        guard !Task.isCancelled, hasPhoto, case .asset(let current) = editTarget, current === session else { return }
        try? await engine.adopt(loaded)
        guard !Task.isCancelled else { return }
        noteThumbnailSource(filmApplied: filmApplied)
        live.setSource(loaded.image, colorSpace: loaded.colorSpace, size: loaded.size)
        sourcePixelSize = loaded.size
        scheduleHistogram()
    }

    func fail(_ message: String) { status = message }

    /// Returns to the gallery, discarding the open photo's edit state.
    func closePhoto() {
        commitCrop()
        rawTask?.cancel()
        rawAsset = false
        clearRawInfo()
        hasPhoto = false
        isCropping = false
        panelHidden = [:]
        filmsDetail = false
        zoom = 1; offset = .zero; showingOriginal = false
        isRestoring = true
        recipe = Recipe()
        isRestoring = false
        editTarget = .imported
        isLibraryAsset = false
        saveState = .saved
        thumbnails = [:]
        startThumbnails()
        status = ""
    }

    private func ingest(_ data: Data) async throws {
        openGeneration += 1
        let generation = openGeneration
        let loaded = try await engine.load(data: data)
        guard generation == openGeneration else { return }
        present(loaded)
    }

    /// Shows a decoded source as a freshly opened import (default recipe, nothing to save).
    func present(_ loaded: LoadedSource) {
        thumbnailsFilmApplied = false
        live.setSource(loaded.image, colorSpace: loaded.colorSpace, size: loaded.size)
        sourceExposureTime = loaded.image.miraExposureTime
        sourcePixelSize = loaded.size
        zoom = 1; offset = .zero; showingOriginal = false
        hasPhoto = true
        isCropping = false
        isRestoring = true
        recipe = Recipe()
        isRestoring = false
        editTarget = .imported
        isLibraryAsset = false
        clearRawInfo()
        saveState = .saved
        thumbnails = [:]
        status = ""
        scheduleHistogram()
        startThumbnails()
    }

    /// Throttled (at most ~10 Hz, trailing) histogram off the render path; never gates the live view.
    private func scheduleHistogram() {
        guard hasPhoto, histogramTask == nil else { return }
        histogramTask = Task {
            try? await Task.sleep(for: .milliseconds(100))
            let r = recipe
            if let h = try? await engine.histogram(for: r) { histogram = h }
            histogramTask = nil
            if r != recipe { scheduleHistogram() }
        }
    }

    /// Forgets every film thumbnail; the cards on screen render theirs again via `requestThumbnail`.
    private func startThumbnails() {
        thumbInFlight = []
        thumbEpoch += 1
    }

    /// Renders one film's thumbnail on demand (a card became visible). Idempotent per photo.
    func requestThumbnail(_ id: String?) async {
        let key = id ?? "__original"
        guard hasPhoto, thumbnails[key] == nil, !thumbInFlight.contains(key) else { return }
        thumbInFlight.insert(key)
        let epoch = thumbEpoch
        if let data = try? await engine.renderThumbnail(filmID: id), let img = UIImage(data: data),
           epoch == thumbEpoch {
            thumbnails[key] = img
        }
        if epoch == thumbEpoch { thumbInFlight.remove(key) }
    }

    /// Writes only when Save is tapped. Library assets get a non-destructive edit (adjustment data +
    /// rendered JPEG over the original); imports are saved as a new photo.
    func save() async {
        guard hasPhoto, saveState != .saving else { return }
        commitCrop()
        let previous = saveState
        let saving = recipe
        saveState = .saving
        isSaving = true
        status = "SAVING"
        defer { isSaving = false }
        do {
            switch editTarget {
            case .asset(let session):
                guard let renderer = live.renderer else { throw AssetEditError.noRenderer }
                try await session.save(recipe: recipe, renderer: renderer)
                status = "SAVED TO PHOTOS"
            case .imported:
                let url = try await engine.exportFull(recipe)
                try await PhotoEngine.saveToLibrary(url)
                status = "SAVED TO PHOTOS"
            }
            // Edits made while the save ran are not in the file: the photo is still unsaved.
            saveState = recipe == saving ? .saved : .unsaved
        } catch {
            saveState = previous == .saved ? .unsaved : previous
            status = "SAVE FAILED · \(error.localizedDescription.uppercased())"
        }
    }
}
