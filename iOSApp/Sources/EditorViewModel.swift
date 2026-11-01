import MiraCore
import PhotosUI
import SwiftUI
import UIKit

@MainActor @Observable
final class EditorViewModel {
    private(set) var previewImage: UIImage?
    private(set) var thumbnails: [String: UIImage] = [:]
    private(set) var hasPhoto = false
    private(set) var isSaving = false
    private(set) var status = ""
    private(set) var histogram: HistogramData = .empty
    private(set) var sourcePixelSize: CGSize = .zero
    private(set) var isCropping = false
    /// Crop being edited while `isCropping`; committed to `recipe.crop` by `commitCrop()`.
    var workingCrop = CropSettings.identity {
        didSet {
            // Re-render the uncropped preview only when the orientation changes (rotate / flip /
            // straighten); dragging the rect leaves the underlying full-frame image unchanged.
            guard isCropping else { return }
            if workingCrop.normalizedQuarterTurns != oldValue.normalizedQuarterTurns
                || workingCrop.flipH != oldValue.flipH
                || workingCrop.flipV != oldValue.flipV
                || workingCrop.straighten != oldValue.straighten {
                requestRender()
            }
        }
    }

    /// Single source of truth for every edit.
    var recipe: Recipe { didSet { if recipe != oldValue { requestRender() } } }

    var strength: Double {
        get { recipe.strength }
        set { recipe.strength = newValue }
    }
    var filmID: String? {
        get { recipe.filmID }
        set { recipe.filmID = newValue }
    }

    private let engine = PhotoEngine()
    private var rendering = false
    private var dirty = false
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
        requestRender()
    }

    func commitCrop() {
        guard isCropping else { return }
        isCropping = false
        let changed = recipe.crop != workingCrop
        recipe.crop = workingCrop
        if !changed { requestRender() }
    }

    func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        requestRender()
    }

    func pick(_ item: PhotosPickerItem) async {
        status = "LOADING"
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                status = "THAT PHOTO COULD NOT BE LOADED"; return
            }
            sourcePixelSize = try await engine.load(data: data)
            hasPhoto = true
            isCropping = false
            recipe = Recipe()
            thumbnails = [:]
            status = ""
            requestRender()
            startThumbnails()
        } catch {
            status = "ERROR · \(error.localizedDescription.uppercased())"
        }
    }

    /// Coalescing render loop: always renders the latest recipe, one at a time.
    private func requestRender() {
        guard hasPhoto else { return }
        dirty = true
        guard !rendering else { return }
        rendering = true
        Task {
            while dirty {
                dirty = false
                var r = recipe
                if isCropping { r.crop = workingCrop.withFullRect }
                if let result = try? await engine.renderPreview(r), let img = UIImage(data: result.jpeg) {
                    previewImage = img
                    histogram = result.histogram
                }
            }
            rendering = false
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
