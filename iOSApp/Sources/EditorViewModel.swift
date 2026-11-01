import MiraCore
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
    private(set) var hasPhoto = false
    private(set) var isSaving = false
    private(set) var status = ""
    private(set) var histogram: HistogramData = .empty
    private(set) var sourcePixelSize: CGSize = .zero
    private(set) var isCropping = false
    /// Crop being edited while `isCropping`; committed to `recipe.crop` by `commitCrop()`.
    var workingCrop = CropSettings.identity

    /// Single source of truth for every edit.
    var recipe: Recipe {
        didSet {
            guard recipe != oldValue else { return }
            if !isRestoring, saveState != .saving { saveState = .unsaved }
            scheduleHistogram()
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
    private var histogramTask: Task<Void, Never>?
    private var thumbTask: Task<Void, Never>?

    init() { recipe = Recipe() }

    func select(_ id: String?) {
        filmID = id
    }

    /// Binding into the recipe for DEVELOP controls; writes flow through `recipe`'s didSet.
    func bind<V>(_ keyPath: WritableKeyPath<Recipe, V>) -> Binding<V> {
        Binding(get: { self.recipe[keyPath: keyPath] }, set: { self.recipe[keyPath: keyPath] = $0 })
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
    func openAsset(_ asset: PHAsset) async {
        status = "LOADING"
        let session = AssetEditSession(asset: asset)
        do {
            let loaded = try await session.load()
            let adopted = LoadedSource(image: loaded.source, colorSpace: loaded.colorSpace, size: loaded.size)
            try await engine.adopt(adopted)
            live.setSource(loaded.source, colorSpace: loaded.colorSpace, size: loaded.size)
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
                status = ""
            }
            scheduleHistogram()
            startThumbnails()
        } catch {
            status = "ERROR · \(error.localizedDescription.uppercased())"
        }
    }

    func fail(_ message: String) { status = message }

    /// Returns to the gallery, discarding the open photo's edit state.
    func closePhoto() {
        commitCrop()
        hasPhoto = false
        isCropping = false
        zoom = 1; offset = .zero; showingOriginal = false
        isRestoring = true
        recipe = Recipe()
        isRestoring = false
        editTarget = .imported
        isLibraryAsset = false
        saveState = .saved
        thumbnails = [:]
        status = ""
    }

    private func ingest(_ data: Data) async throws {
        let loaded = try await engine.load(data: data)
        live.setSource(loaded.image, colorSpace: loaded.colorSpace, size: loaded.size)
        sourcePixelSize = loaded.size
        zoom = 1; offset = .zero; showingOriginal = false
        hasPhoto = true
        isCropping = false
        isRestoring = true
        recipe = Recipe()
        isRestoring = false
        editTarget = .imported
        isLibraryAsset = false
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

    private func startThumbnails() {
        thumbTask?.cancel()
        let ids: [String?] = [nil] + PhotoEngine.filmList.map { Optional($0.id) }
        thumbTask = Task {
            for id in ids {
                if Task.isCancelled { return }
                if let data = try? await engine.renderThumbnail(filmID: id), let img = UIImage(data: data) {
                    thumbnails[id ?? "__original"] = img
                }
            }
        }
    }

    /// Writes only when Save is tapped. Library assets get a non-destructive edit (adjustment data +
    /// rendered JPEG over the original); imports are saved as a new photo.
    func save() async {
        guard hasPhoto, saveState != .saving else { return }
        commitCrop()
        let previous = saveState
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
            saveState = .saved
        } catch {
            saveState = previous == .saved ? .unsaved : previous
            status = "SAVE FAILED · \(error.localizedDescription.uppercased())"
        }
    }
}
