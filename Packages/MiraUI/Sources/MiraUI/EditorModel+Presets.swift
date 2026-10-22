import AppKit
import MiraCore
import Observation

/// Which dialog the preset sheet is showing.
public enum PresetSheetMode: Identifiable, Equatable, Sendable {
    case save
    case rename(UUID)

    public var id: String {
        switch self {
        case .save: "save"
        case .rename(let id): "rename-\(id.uuidString)"
        }
    }
}

/// Stops a batch of preset thumbnail renders early (set on the main actor, read on workers).
final class PresetCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// A preset thumbnail depends only on the graded recipe (film resolved, no crop) and the crop.
struct PresetThumbnailKey: Hashable {
    let recipe: Recipe
    let crop: CropSettings
}

private struct PresetThumbnailResult: @unchecked Sendable {
    let id: String
    let image: CGImage
}

extension EditorModel {
    // MARK: Reading

    /// Picks up presets saved by the other process (app or Photos extension) or by this one.
    public func refreshPresets() {
        let all = presetStore.all
        if all != presets {
            presets = all
            presetThumbnailsDirty = true
            updateAppliedPreset()
        }
        if presetThumbnailsDirty { startPresetThumbnails() }
    }

    /// The preset's film is named but not in the library.
    public func isFilmMissing(_ preset: Preset) -> Bool {
        guard let id = preset.filmID else { return false }
        return library.film(id: id) == nil
    }

    /// The recipe applying `preset` would give right now: its film (none if missing) and develop
    /// settings, this photo's crop.
    public func recipe(applying preset: Preset) -> Recipe {
        var r = preset.recipe(keeping: recipe.crop)
        if isFilmMissing(preset) { r.filmID = nil }
        return r
    }

    /// True when the current look is exactly this preset (the card shows as selected).
    public func isApplied(_ preset: Preset) -> Bool {
        !isFilmMissing(preset) && recipe(applying: preset) == recipe
    }

    /// Keeps `appliedPresetID` in step with `recipe` and `presets`; writes only on change.
    func updateAppliedPreset() {
        guard !presets.isEmpty || appliedPresetID != nil else { return }
        let id = presets.first(where: { isApplied($0) })?.id
        if id != appliedPresetID { appliedPresetID = id }
    }

    var currentFilmName: String { selectedFilm?.displayName ?? Preset.originalName }

    // MARK: Saving and editing

    /// Saves the current film and develop settings under `nickname`.
    @discardableResult
    public func saveCurrentAsPreset(nickname: String) throws -> Preset {
        let preset = try presetStore.add(Preset(nickname: try PresetStore.validated(nickname), recipe: recipe, library: library))
        refreshPresets()
        return preset
    }

    public func renamePreset(_ id: UUID, nickname: String) throws {
        try presetStore.rename(id: id, nickname: nickname)
        refreshPresets()
    }

    public func duplicatePreset(_ id: UUID) {
        do {
            try presetStore.duplicate(id: id)
        } catch {
            showPresetNotice("Could not duplicate the preset.")
        }
        refreshPresets()
    }

    public func deletePreset(_ id: UUID) {
        if hoveredTarget == .preset(id) { endHover() }
        do {
            try presetStore.delete(id: id)
        } catch PresetError.notFound {
            // Already gone (deleted in the other process).
        } catch {
            showPresetNotice("Could not delete the preset.")
        }
        presetPendingDelete = nil
        refreshPresets()
    }

    public func beginSavePreset() {
        guard source != nil, !isCropping else { return }
        presetSheet = .save
    }

    // MARK: Applying

    /// Sets the preset's film and develop values, keeping this photo's crop. A film that is no longer
    /// installed is dropped (develop settings only) and a notice says so.
    public func applyPreset(_ id: UUID) {
        endHover()
        refreshPresets()
        guard let preset = presetStore.preset(id: id) else { return }
        if isFilmMissing(preset) {
            showPresetNotice("\(preset.filmName) is not installed; applied develop settings only.")
        } else {
            clearPresetNotice()
        }
        recipe = recipe(applying: preset)
    }

    // MARK: Notice

    func showPresetNotice(_ text: String) {
        presetNotice = text
        presetNoticeTask?.cancel()
        presetNoticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            self?.presetNotice = nil
        }
    }

    func clearPresetNotice() {
        presetNoticeTask?.cancel()
        presetNotice = nil
    }

    // MARK: Hover

    /// Previews the preset on the canvas (after the usual debounce). Never touches `recipe`.
    public func hoverPreset(_ id: UUID) {
        guard !isCropping else { return }
        startHover(.preset(id), keepImage: false)
    }

    /// The recipe to draw for a hover target: the applied look with the film swapped (film cards), or
    /// the whole preset on this photo's crop (preset cards).
    func hoverRecipe(for target: HoverTarget) -> Recipe {
        if case .preset(let id) = target, let preset = presetStore.preset(id: id) {
            return recipe(applying: preset)
        }
        var swapped = recipe
        swapped.filmID = target.filmID
        return swapped
    }

    // MARK: Thumbnails

    func presetTabOpened() {
        refreshPresets()
        if presetThumbnailsDirty { startPresetThumbnails() }
    }

    func presetSourceChanged() {
        presetThumbnailCache = [:]
        presetThumbnails = [:]
        presetThumbnailsDirty = true
        startPresetThumbnails()
    }

    func cancelPresetWork() {
        presetThumbnailTask?.cancel()
        presetThumbnailCancel?.cancel()
        presetNoticeTask?.cancel()
    }

    private func thumbnailKey(_ preset: Preset) -> PresetThumbnailKey {
        var r = recipe(applying: preset)
        r.crop = .identity
        return PresetThumbnailKey(recipe: r, crop: recipe.crop)
    }

    /// Renders one thumbnail per preset from the photo with its current crop, a few at a time. Only
    /// while the FILMS tab is showing; otherwise the work waits (`presetThumbnailsDirty`) until it opens.
    func startPresetThumbnails() {
        presetThumbnailTask?.cancel()
        presetThumbnailCancel?.cancel()
        guard tab == .films else { presetThumbnailsDirty = true; return }
        guard engine.hasSource else { return }
        presetThumbnailsDirty = false

        let crop = recipe.crop
        var shown: [UUID: NSImage] = [:]
        var todo: [(id: String, recipe: Recipe)] = []
        var keys: [String: (UUID, PresetThumbnailKey)] = [:]
        for preset in presets {
            let key = thumbnailKey(preset)
            if let cached = presetThumbnailCache[key] {
                shown[preset.id] = cached
            } else {
                todo.append((preset.id.uuidString, key.recipe))
                keys[preset.id.uuidString] = (preset.id, key)
            }
        }
        presetThumbnails = shown
        guard !todo.isEmpty else { return }
        let flushInterval = EditorModel.thumbnailFlushInterval

        let cancel = PresetCancelFlag()
        presetThumbnailCancel = cancel
        let engine = engine
        let work = todo
        let (stream, continuation) = AsyncStream.makeStream(of: PresetThumbnailResult.self)
        presetThumbnailTask = Task { [weak self] in
            await withTaskCancellationHandler {
                Task.detached(priority: .utility) {
                    engine.renderThumbnails(recipes: work, crop: crop, longSide: EditorModel.thumbnailLongSide,
                                            isCancelled: { cancel.isCancelled }) { id, cg in
                        continuation.yield(PresetThumbnailResult(id: id, image: cg))
                    }
                    continuation.finish()
                }
                // Published in 60 ms batches like the film thumbnails: every write re-evaluates the strip.
                var batch: [UUID: NSImage] = [:]
                var lastFlush = ContinuousClock.now
                for await item in stream {
                    guard let self, !cancel.isCancelled, let (uuid, key) = keys[item.id] else {
                        cancel.cancel()
                        batch = [:]
                        break
                    }
                    let image = NSImage(cgImage: item.image,
                                        size: NSSize(width: item.image.width, height: item.image.height))
                    batch[uuid] = image
                    if self.presetThumbnailCache.count > 64 { self.presetThumbnailCache = [:] }
                    self.presetThumbnailCache[key] = image
                    if lastFlush.duration(to: .now) >= flushInterval {
                        self.presetThumbnails.merge(batch) { $1 }
                        batch = [:]
                        lastFlush = .now
                    }
                }
                if !batch.isEmpty, let self, !cancel.isCancelled {
                    self.presetThumbnails.merge(batch) { $1 }
                }
            } onCancel: {
                cancel.cancel()
                continuation.finish()
            }
        }
    }
}
