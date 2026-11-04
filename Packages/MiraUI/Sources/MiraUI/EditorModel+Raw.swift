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
    @ObservationIgnored var generation = 0

    init() {}

    func reset() {
        task?.cancel()
        task = nil
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

    /// Opens a RAW file: a draft, reduced-size develop of the current recipe becomes the source.
    func loadRawSource(url: URL, orientation: CGImagePropertyOrientation?) -> Bool {
        guard let develop = RawDevelop(url: url, orientation: orientation),
              let image = develop.apply(recipe.raw, filmApplied: recipe.filmID != nil, draft: true,
                                        scale: develop.previewScale())
        else { return false }
        setSource(image)
        beginRawSession(develop: develop, url: url, orientation: orientation, developedFor: recipe)
        return true
    }

    /// For callers that set the source themselves (Photos editing in the app) from a RAW file that
    /// was developed with `developedFor` (see `ImageSource.developedSource`). Call after
    /// `setSource` / `replaceSource`, which end any earlier RAW session.
    public func attachRawSource(url: URL, orientation: CGImagePropertyOrientation?, developedFor: Recipe) {
        guard ImageSource.isRAW(url: url), let develop = RawDevelop(url: url, orientation: orientation) else { return }
        beginRawSession(develop: develop, url: url, orientation: orientation, developedFor: developedFor)
        rawRecipeChanged(from: developedFor)
    }

    private func beginRawSession(develop: RawDevelop, url: URL, orientation: CGImagePropertyOrientation?,
                                 developedFor: Recipe) {
        rawSession.reset()
        rawSession.develop = develop
        rawSession.url = url
        rawSession.orientation = orientation
        rawSession.shownKey = RawDevelopKey(developedFor)
        rawSession.desiredKey = rawSession.shownKey
        rawSession.asShot = develop.asShot
        rawSession.supported = develop.supported
        rawSession.isRaw = true
    }

    /// Called when `setSource` replaces the photo.
    func endRawSession() { rawSession.reset() }

    func cancelRawWork() { rawSession.task?.cancel() }

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
        }
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
