#if os(macOS)
import CoreImage
import ImageIO
import MiraCore
import Observation

/// Carries a Core Image value (immutable, thread safe) across a task boundary.
struct RawImageBox: @unchecked Sendable {
    let image: CIImage
}

/// What a RAW develop was made for. Only these inputs change the developed pixels: the RAW settings
/// and whether a film is applied (automatic boost and extended range depend on it).
struct RawDevelopKey: Equatable, Sendable {
    var raw: RawSettings
    var filmApplied: Bool

    init(_ recipe: Recipe) {
        raw = recipe.raw
        filmApplied = recipe.filmID != nil
    }
}

/// The editor's RAW state for the open photo (see EditorModel+Raw.swift). Observable parts are the
/// ones the Develop panel reads; the rest is bookkeeping.
@MainActor
@Observable
public final class RawSession {
    public internal(set) var isRaw = false
    public internal(set) var asShot: (temperature: Double, tint: Double)?
    public internal(set) var supported = RawSupportedControls()

    @ObservationIgnored var develop: RawDevelop?
    @ObservationIgnored var url: URL?
    @ObservationIgnored var orientation: CGImagePropertyOrientation?
    /// Key of the source currently on screen, and of the newest one asked for.
    @ObservationIgnored var shownKey: RawDevelopKey?
    @ObservationIgnored var desiredKey: RawDevelopKey?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var thumbnailTask: Task<Void, Never>?
    /// The background full-quality (non-draft) decode that replaces the draft frame.
    @ObservationIgnored var refineTask: Task<Void, Never>?
    /// Key of the source on screen when it is the full-quality decode (nil while it is a draft).
    @ObservationIgnored var refinedKey: RawDevelopKey?
    @ObservationIgnored var generation = 0

    init() {}

    func reset() {
        task?.cancel()
        task = nil
        thumbnailTask?.cancel()
        thumbnailTask = nil
        refineTask?.cancel()
        refineTask = nil
        refinedKey = nil
        generation += 1
        develop = nil
        url = nil
        orientation = nil
        shownKey = nil
        desiredKey = nil
        if isRaw { isRaw = false }
        asShot = nil
        supported = RawSupportedControls()
    }
}

extension EditorModel {
    /// Wait after the last RAW setting change before re-developing.
    nonisolated static let rawDebounce: Duration = .milliseconds(120)

    // MARK: State for the Develop panel

    /// True when the open photo is a camera RAW file developed by `RawDevelop`.
    public var isRawSource: Bool { rawSession.isRaw }
    /// White balance the camera recorded (kelvin, tint); nil for non-RAW photos.
    public var rawAsShot: (temperature: Double, tint: Double)? { rawSession.asShot }
    /// Which RAW controls this file's decoder supports.
    public var rawSupportedControls: RawSupportedControls { rawSession.supported }

    // MARK: Loading

    /// Cache key of a RAW file for the session caches: its path and modification time.
    nonisolated static func rawCacheKey(url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.timeIntervalSince1970 ?? 0
        return "file:\(url.path)@\(date)"
    }

    /// Opens a RAW file in stages, none of which blocks the main actor for a decode:
    /// 1. the camera's embedded preview (milliseconds) as a stand-in;
    /// 2. a draft-mode decode at preview size, cached per file for the session, becomes the first
    ///    editable frame (instantly on a reopen);
    /// 3. a full-quality decode replaces it in the background (`scheduleRawRefine`).
    /// Returns false when the file cannot be read as an image at all.
    func loadRawSource(url: URL, orientation: CGImagePropertyOrientation?) -> Bool {
        let cacheKey = Self.rawCacheKey(url: url)
        let key = RawDevelopKey(recipe)
        let proxyKey = RawAssetCache.ProxyKey(settings: key.raw, filmApplied: key.filmApplied)

        // Reopen: the cached proxy is the first frame, synchronously.
        if let develop = RawAssetCache.shared.develop(forKey: cacheKey, url: url, orientation: orientation),
           let proxy = RawAssetCache.shared.proxy(forKey: cacheKey, proxyKey) {
            setSource(proxy.image)
            beginRawSession(develop: develop, url: url, orientation: orientation, developedFor: key)
            scheduleRawRefine()
            return true
        }

        guard let placeholder = ImageSource.loadEmbeddedPreview(url: url, orientation: orientation,
                                                                 maxPixelSize: Self.standInLongSide) else {
            // No embedded preview to show: develop before returning, as before.
            guard let frame = RawOpener.openDraft(url: url, orientation: orientation, settings: key.raw,
                                                  filmApplied: key.filmApplied, cacheKey: cacheKey)
            else { return false }
            setSource(frame.source.image)
            beginRawSession(develop: frame.develop, url: url, orientation: orientation, developedFor: key)
            scheduleRawRefine()
            return true
        }
        guard ImageSource.orientedPixelSize(url: url, orientation: orientation) != nil else { return false }
        setSource(placeholder, isFull: false)
        let generation = rawSession.generation
        rawSession.task = Task { [weak self] in
            let opened = await Task.detached(priority: .userInitiated) {
                RawOpener.openDraft(url: url, orientation: orientation, settings: key.raw, filmApplied: key.filmApplied,
                                    cacheKey: cacheKey)
            }.value
            guard !Task.isCancelled, let self, self.rawSession.generation == generation else { return }
            guard let frame = opened else { return }   // stays on the embedded preview
            self.replaceSource(frame.source.image, isFull: true)
            // The recipe may have changed while the file decoded (a restored sidecar): develop again if so.
            self.beginRawSession(develop: frame.develop, url: url, orientation: orientation,
                                 developedFor: key)
            self.rawRecipeChanged(from: self.recipe)
            self.scheduleRawRefine()
        }
        return true
    }

    /// For callers that set the source themselves (Photos editing in the app) from a RAW file that
    /// was developed with `developedFor` (see `ImageSource.developedSource`). Call after
    /// `setSource` / `replaceSource`, which end any earlier RAW session. `develop` reuses a decoder
    /// already open for this file (e.g. from `RawAssetCache`).
    public func attachRawSource(url: URL, orientation: CGImagePropertyOrientation?, developedFor: Recipe,
                                develop existing: RawDevelop? = nil) {
        guard ImageSource.isRAW(url: url), let develop = existing ?? RawDevelop(url: url, orientation: orientation) else { return }
        beginRawSession(develop: develop, url: url, orientation: orientation, developedFor: RawDevelopKey(developedFor))
        rawRecipeChanged(from: developedFor)
        scheduleRawRefine()
    }

    private func beginRawSession(develop: RawDevelop, url: URL, orientation: CGImagePropertyOrientation?,
                                 developedFor: RawDevelopKey) {
        rawSession.reset()
        rawSession.develop = develop
        rawSession.url = url
        rawSession.orientation = orientation
        rawSession.shownKey = developedFor
        rawSession.desiredKey = rawSession.shownKey
        rawSession.asShot = develop.asShot
        rawSession.supported = develop.supported
        rawSession.isRaw = true
    }

    /// Called when `setSource` replaces the photo.
    func endRawSession() { rawSession.reset() }

    func cancelRawWork() {
        rawSession.task?.cancel()
        rawSession.refineTask?.cancel()
        rawSession.thumbnailTask?.cancel()
    }

    // MARK: Re-developing

    /// Called from `recipe`'s didSet: when the RAW settings, or whether a film is applied, differ
    /// from what the source on screen was developed with, develops again (debounced, off the main
    /// actor) and swaps the source in, keeping the zoom.
    func rawRecipeChanged(from old: Recipe) {
        guard rawSession.isRaw, let develop = rawSession.develop else { return }
        let key = RawDevelopKey(recipe)
        guard key != rawSession.desiredKey else { return }
        rawSession.desiredKey = key
        rawSession.task?.cancel()
        rawSession.refineTask?.cancel()
        rawSession.refinedKey = nil
        rawSession.generation += 1
        let generation = rawSession.generation
        let scale = develop.previewScale()
        rawSession.task = Task { [weak self] in
            try? await Task.sleep(for: Self.rawDebounce)
            guard !Task.isCancelled else { return }
            let box = await Task.detached(priority: .userInitiated) {
                develop.apply(key.raw, filmApplied: key.filmApplied, draft: true, scale: scale).map(RawImageBox.init)
            }.value
            guard !Task.isCancelled, let self, self.rawSession.generation == generation, let box else { return }
            self.rawSession.shownKey = key
            self.replaceSource(box.image, keepZoom: true)
            self.scheduleThumbnailRefresh()
            self.scheduleRawRefine()
        }
    }

    /// After the draft frame settles, decodes the same settings at full quality (draft mode off, same
    /// size) off the main actor and swaps it in, keeping the zoom. Any RAW change in the meantime
    /// abandons it; the next draft schedules it again.
    func scheduleRawRefine(delay: Duration = .milliseconds(250)) {
        guard rawSession.isRaw, let develop = rawSession.develop,
              let key = rawSession.shownKey, key == rawSession.desiredKey, rawSession.refinedKey != key else { return }
        rawSession.refineTask?.cancel()
        let generation = rawSession.generation
        rawSession.refineTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let box = await Task.detached(priority: .utility) {
                RawOpener.refine(develop: develop, settings: key.raw, filmApplied: key.filmApplied)
                    .map { RawImageBox(image: $0.image) }
            }.value
            guard !Task.isCancelled, let self, self.rawSession.generation == generation,
                  self.rawSession.shownKey == key, self.rawSession.desiredKey == key, let box else { return }
            self.rawSession.refinedKey = key
            self.replaceSource(box.image, keepZoom: true)
        }
    }

    // MARK: Thumbnails

    /// Waits for a pause in RAW changes, then regenerates the film-strip and preset thumbnails from the
    /// newly developed source. The old tiles stay on screen until the new ones arrive.
    func scheduleThumbnailRefresh(delay: Duration = .milliseconds(400)) {
        rawSession.thumbnailTask?.cancel()
        rawSession.thumbnailTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.invalidateThumbnailsForNewSource()
        }
    }

    /// Drops the cached tiles (they were made from the previous develop) and renders them again.
    func invalidateThumbnailsForNewSource() {
        thumbnailCache = [:]
        thumbnailCacheOrder = []
        startThumbnails(keepShown: true)
        presetThumbnailCache = [:]
        presetThumbnailsDirty = true
        startPresetThumbnails()
    }

    // MARK: Export

    /// The source to save, export or share: for a RAW photo a fresh full-quality develop (no draft
    /// mode, full size) of the current recipe; otherwise `fullSource()`.
    public func exportSource() async -> CIImage? {
        guard rawSession.isRaw, let url = rawSession.url else { return await fullSource() }
        let orientation = rawSession.orientation
        let recipe = recipe
        let box = await Task.detached(priority: .userInitiated) {
            ImageSource.developedSource(url: url, orientation: orientation, recipe: recipe, draft: false)
                .map(RawImageBox.init)
        }.value
        return box?.image
    }
}
#endif
