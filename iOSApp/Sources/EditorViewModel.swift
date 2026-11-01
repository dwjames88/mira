import MiraCore
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
    var recipe: Recipe { didSet { if recipe != oldValue { scheduleHistogram() } } }

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

    private func ingest(_ data: Data) async throws {
        let loaded = try await engine.load(data: data)
        live.setSource(loaded.image, colorSpace: loaded.colorSpace, size: loaded.size)
        sourcePixelSize = loaded.size
        zoom = 1; offset = .zero; showingOriginal = false
        hasPhoto = true
        isCropping = false
        recipe = Recipe()
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

    func save() async {
        guard hasPhoto, !isSaving else { return }
        isSaving = true
        status = "SAVING"
        defer { isSaving = false }
        do {
            let url = try await engine.exportFull(recipe)
            try await PhotoEngine.saveToLibrary(url)
            status = "SAVED TO PHOTOS"
        } catch {
            status = "SAVE FAILED · \(error.localizedDescription.uppercased())"
        }
    }
}
