import AppKit
import CoreImage
import MiraCore
import ImageIO
import Observation

/// Carries a non-Sendable Core Image / Core Graphics value across a task boundary. Core Image
/// images are immutable and `CIContext` is documented as thread safe.
private struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Set from the main actor, read from worker threads, to stop a batch of renders early.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// State of the shared editor: the source photo, the current recipe, and the rendered previews.
///
/// Previews are rendered by a `PreviewEngine` at the size of the canvas (reported by the view with
/// `setCanvas(pixels:)`), into IOSurface-backed frames the canvas shows without any CGImage or
/// NSImage conversion. Requests are coalesced: at most one render is in flight and only the latest
/// recipe waits behind it.
@MainActor
@Observable
public final class EditorModel {
    public let library: FilmLibrary
    public let renderer: Renderer

    /// Full-size source, orientation already applied. While a large file is still being decoded this
    /// is a small stand-in (`isSourceFull` is false); use `fullSource()` for saving and exporting.
    public private(set) var source: CIImage?
    /// False while `source` is only a quick low-resolution stand-in for the real photo.
    public private(set) var isSourceFull = true

    public var recipe: Recipe {
        didSet {
            guard recipe != oldValue else { return }
            // Views that only care which film is applied (the film strip) read this instead of
            // `recipe`, so a slider tick does not re-evaluate them.
            if recipe.filmID != selectedFilmID { selectedFilmID = recipe.filmID }
            if recipe.crop != oldValue.crop { resetZoom() } else { revalidateZoom() }
            schedulePreview()
            recipeChangedWhileHovering()
            if recipe.crop != oldValue.crop { startThumbnails() }
        }
    }
    /// `recipe.filmID`, but only changes when the film does.
    public private(set) var selectedFilmID: String?
    public var showOriginal = false {
        didSet {
            // A zoomed original is rendered on demand, so ask for it as soon as compare starts.
            if showOriginal, !oldValue, zoomRegion != nil { schedulePreview() }
        }
    }

    // MARK: Histogram and colour mixer

    /// Histogram of the frame on the canvas (graded, original or hover), nil until the first frame.
    public private(set) var histogram: HistogramData?
    /// The colour-mixer range the sliders edit.
    public var mixerRange: ColorRange = .red
    /// While true, the next click on the canvas picks a colour-mixer range from the pixel under it.
    public var eyedropperActive = false
    @ObservationIgnored private var histogramInFlight = false
    @ObservationIgnored private var histogramPending: PreviewFrame?
    @ObservationIgnored private var histogramLast: ContinuousClock.Instant?
    /// Minimum time between histogram passes (about 20 Hz).
    nonisolated static let histogramInterval: Duration = .milliseconds(50)

    /// True while the crop tool is open. `crop` is the working copy; `recipe.crop` only changes on Done.
    public private(set) var isCropping = false
    /// The working crop while `isCropping` (rect, straighten, rotation, flips, aspect preset).
    public var crop: CropSettings = .identity {
        didSet {
            guard isCropping, Self.geometryKey(crop) != Self.geometryKey(oldValue) else { return }
            schedulePreview()
        }
    }
    public var familyFilter: FilmFamily?

    // MARK: Chrome

    /// Panels, sub-toolbar and film strip are hidden; only the photo remains (key F).
    public private(set) var isImmersive = false
    /// Space is held: a drag pans the zoomed picture.
    public private(set) var isSpaceHeld = false

    public func setImmersive(_ on: Bool) {
        guard on != isImmersive else { return }
        if on { endHover() }
        isImmersive = on
    }

    public func toggleImmersive() { setImmersive(!isImmersive) }

    /// Ends press-and-hold states (compare, Space) when the window loses focus or the editor closes.
    public func releaseHolds() {
        showOriginal = false
        isSpaceHeld = false
    }

    /// Runs a key-map action. Zoom and compare actions are handled alongside the zoom state.
    public func perform(_ action: EditorKeyAction) {
        switch action {
        case .selectTab(let tab): selectTab(tab)
        case .toggleImmersive: toggleImmersive()
        case .exitImmersive: setImmersive(false)
        case .compare(let held): if !isCropping || !held { showOriginal = held }
        case .space(let held): isSpaceHeld = held
        case .zoomIn: zoomStep(1)
        case .zoomOut: zoomStep(-1)
        case .swallow: break
        }
    }

    // MARK: Tabs

    /// The tab the right panel and the canvas surroundings show. `.crop` is on exactly while the
    /// crop tool is open (`isCropping`): entering it begins a crop, leaving it commits.
    public private(set) var tab: EditorTab = .films
    /// The tab to return to when the crop tool closes.
    @ObservationIgnored private var tabBeforeCrop: EditorTab = .films

    /// The latest rendered frame (graded, or the cropping canvas while cropping).
    public private(set) var previewFrame: PreviewFrame?
    /// Thumbnails by film id. The key `EditorModel.originalTileID` holds the untouched tile.
    public private(set) var thumbnails: [String: NSImage] = [:]

    /// What the pointer is over in the film strip. Preview-only state: it never touches `recipe`.
    public enum HoverTarget: Hashable, Sendable {
        case original
        case film(String)

        var filmID: String? {
            if case .film(let id) = self { return id }
            return nil
        }
    }

    /// The card under the pointer, or nil when the pointer is elsewhere. Set immediately; the
    /// preview image follows after the debounce.
    public private(set) var hoveredTarget: HoverTarget?
    private var hoverFrame: PreviewFrame?

    public static let originalTileID = "__original__"
    /// Long side of the film-strip thumbnails, in pixels.
    public nonisolated static let thumbnailLongSide: CGFloat = 256

    @ObservationIgnored let engine: PreviewEngine
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var gate = RenderGate<PreviewRequest>()
    @ObservationIgnored private var canvasPixels: CGSize?
    /// Graded frames published so far (tests check that bursts are coalesced).
    @ObservationIgnored private(set) var publishedFrames = 0
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailCancel: CancelFlag?
    @ObservationIgnored private var thumbnailCache: [CropSettings: [String: NSImage]] = [:]
    @ObservationIgnored private var thumbnailCacheOrder: [CropSettings] = []
    @ObservationIgnored private var originalFrame: PreviewFrame?
    @ObservationIgnored private var originalKey: OriginalKey?
    @ObservationIgnored private var sourceGeneration = 0
    @ObservationIgnored private var contentGeneration = 0
    @ObservationIgnored private var fullDecodeTask: Task<CIImage?, Never>?
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var hoverGeneration = 0
    @ObservationIgnored private var hoverCache: [HoverKey: PreviewFrame] = [:]
    @ObservationIgnored private var hoverCacheOrder: [HoverKey] = []
    @ObservationIgnored private var imageCache: [Int: NSImage] = [:]

    private struct HoverKey: Hashable {
        let filmID: String?
        let recipe: Recipe
        let canvas: CGSize?
        let zoom: ZoomRegion?
    }

    private struct OriginalKey: Equatable {
        let crop: CropSettings
        let canvas: CGSize?
        let generation: Int
        let zoom: ZoomRegion?
    }

    private struct PreviewRequest: Sendable {
        let recipe: Recipe
        let canvas: CGSize?
        let generation: Int
        /// The part of the picture to render at the zoom scale, nil to render the whole picture.
        let zoom: ZoomRegion?
    }

    private static let hoverCacheLimit = 6
    private static let thumbnailCacheLimit = 4
    nonisolated static let hoverDebounce: Duration = .milliseconds(60)

    public init(library: FilmLibrary, recipe: Recipe = .neutral) {
        self.library = library
        self.renderer = Renderer(library: library)
        self.engine = PreviewEngine(renderer: renderer, context: Renderer.sharedContext)
        self.recipe = recipe
        self.selectedFilmID = recipe.filmID
    }

    public var films: [Film] { library.films }

    public var visibleFilms: [Film] {
        guard let familyFilter else { return library.films }
        return library.films.filter { $0.family == familyFilter }
    }

    public var selectedFilm: Film? {
        recipe.filmID.flatMap { library.film(id: $0) }
    }

    /// Whether leaving now would discard work.
    public var hasEdits: Bool {
        recipe != .neutral
    }

    // MARK: Source

    /// Photos longer than this are opened with a quick reduced-size decode first.
    nonisolated static let standInThreshold: CGFloat = 2600
    nonisolated static let standInLongSide: CGFloat = 1600

    /// Sets the photo to edit. `image` must already be upright. `isFull` is false for a quick
    /// stand-in that `replaceSource(_:)` swaps for the real photo later.
    public func setSource(_ image: CIImage, isFull: Bool = true) {
        fullDecodeTask?.cancel()
        fullDecodeTask = nil
        sourceGeneration += 1
        contentGeneration += 1
        isCropping = false
        leaveCropTab()
        resetZoom()
        source = image
        isSourceFull = isFull
        engine.setSource(image)
        thumbnails = [:]
        thumbnailCache = [:]
        thumbnailCacheOrder = []
        originalFrame = nil
        originalKey = nil
        previewFrame = nil
        imageCache = [:]
        hoverCache = [:]
        hoverCacheOrder = []
        if let target = hoveredTarget { startHover(target, keepImage: false) }
        schedulePreview()
        startThumbnails()
    }

    /// Swaps the stand-in for the real photo (same picture, full resolution). The frame on screen
    /// stays until the sharper one is ready, and the film strip is kept.
    public func replaceSource(_ image: CIImage, isFull: Bool = true) {
        sourceGeneration += 1
        resetZoom()
        source = image
        isSourceFull = isFull
        engine.setSource(image)
        originalKey = nil
        hoverCache = [:]
        hoverCacheOrder = []
        if let target = hoveredTarget { startHover(target, keepImage: true) }
        schedulePreview()
    }

    /// The full-size source, waiting for a background decode to finish. nil if it could not be decoded.
    public func fullSource() async -> CIImage? {
        if let task = fullDecodeTask { _ = await task.value }
        return isSourceFull ? source : nil
    }

    /// Loads an image file (RAW included), applying its own orientation exactly once.
    @discardableResult
    public func loadSource(url: URL) -> Bool {
        loadSource(url: url, orientation: nil)
    }

    /// Loads an image file and applies `orientation` to its pixels (Photos'
    /// `fullSizeImageOrientation`). nil uses the file's own orientation.
    ///
    /// Large files show a reduced decode at once and are decoded in full in the background;
    /// `isSourceFull` and `fullSource()` tell when the real photo is in.
    @discardableResult
    public func loadSource(url: URL, orientation: CGImagePropertyOrientation?) -> Bool {
        if !ImageSource.isRAW(url: url),
           let size = ImageSource.orientedPixelSize(url: url, orientation: orientation),
           max(size.width, size.height) > Self.standInThreshold,
           let stand = ImageSource.loadThumbnail(url: url, orientation: orientation, maxPixelSize: Self.standInLongSide) {
            setSource(stand, isFull: false)
            let generation = contentGeneration
            fullDecodeTask = Task { [weak self] () -> CIImage? in
                let decoded = await Task.detached(priority: .userInitiated) {
                    ImageSource.loadDecoded(url: url, orientation: orientation).map(Unchecked.init)
                }.value
                guard !Task.isCancelled, let self, self.contentGeneration == generation, let decoded else { return nil }
                self.replaceSource(decoded.value)
                return decoded.value
            }
            return true
        }
        guard let image = ImageSource.loadDecoded(url: url, orientation: orientation) else { return false }
        setSource(image)
        return true
    }

    // MARK: Editing

    public func selectFilm(_ id: String?) {
        endHover()
        recipe.filmID = id
    }

    /// Resets every slider to its default and keeps the selected film.
    public func reset() {
        recipe = Recipe(filmID: recipe.filmID, crop: recipe.crop)
    }

    /// Back to a neutral recipe: no film, sliders, curves, mixer or crop. Only the source stays.
    public func resetAll() {
        if isCropping { cancelCrop() }
        recipe = .neutral
    }

    /// True when `reset()` would change something (any adjustment differs from neutral).
    public var canReset: Bool {
        recipe != Recipe(filmID: recipe.filmID, crop: recipe.crop)
    }

    /// True when `resetAll()` would change something.
    public var canResetAll: Bool { recipe != .neutral }

    // MARK: Crop

    /// Opens the crop tool on a copy of the recipe's crop. The canvas then shows the whole picture
    /// (rotated, flipped and straightened) so the box can reach anything.
    public func beginCrop() {
        guard !isCropping, source != nil else { return }
        endHover()
        showOriginal = false
        setImmersive(false)
        resetZoom()
        crop = recipe.crop
        isCropping = true
        if tab != .crop { tabBeforeCrop = tab }
        tab = .crop
        schedulePreview()
    }

    /// Done: writes the working crop to `recipe.crop` and closes the tool.
    public func commitCrop() {
        guard isCropping else { return }
        var result = crop
        result.rect = result.rect.clamped()
        if result.isIdentity { result = .identity }
        isCropping = false
        leaveCropTab()
        recipe.crop = result
        schedulePreview()
    }

    /// Cancel: drops the working copy; the recipe is untouched.
    public func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        leaveCropTab()
        crop = recipe.crop
        schedulePreview()
    }

    /// CANCEL in the crop tab: drops the changes made so far and stays in the tool, showing the
    /// committed crop again.
    public func revertCrop() {
        guard isCropping else { return }
        crop = recipe.crop
        schedulePreview()
    }

    private func leaveCropTab() {
        if tab == .crop { tab = tabBeforeCrop }
    }

    /// Switches tab. Entering CROP begins the crop tool; leaving it commits (the same as DONE).
    public func selectTab(_ new: EditorTab) {
        guard new != tab else { return }
        if tab == .crop { commitCrop() }
        if new == .crop {
            beginCrop()
        } else {
            tab = new
        }
    }

    /// Back to the whole, unrotated picture; the tool stays open.
    public func resetCrop() {
        guard isCropping else { return }
        crop = .identity
    }

    public func rotate90() { if isCropping { crop = CropGeometry.rotatedClockwise(crop) } }
    public func flipH() { if isCropping { crop = CropGeometry.flippedHorizontally(crop) } }
    public func flipV() { if isCropping { crop = CropGeometry.flippedVertically(crop) } }

    /// Straighten in degrees, -45...45.
    public var straighten: Double {
        get { crop.straighten }
        set { crop.straighten = min(max(newValue, -45), 45) }
    }

    /// Size of the crop canvas in preview pixels (oriented image size), nil without a photo.
    public var cropCanvasSize: CGSize? {
        source.map { CropGeometry.orientedSize(for: crop, size: $0.extent.size) }
    }

    /// Width / height the box is locked to, nil for a free box.
    public var cropAspectRatio: Double? {
        cropCanvasSize.flatMap { CropAspect.ratio(id: crop.aspect, canvas: $0) }
    }

    /// Picks a preset and reshapes the box to it, keeping its area and centre where possible.
    public func setAspect(_ id: String) {
        guard isCropping, let canvas = cropCanvasSize, canvas.width > 0, canvas.height > 0 else { return }
        crop.aspect = id
        guard let ratio = CropAspect.ratio(id: id, canvas: canvas) else { return }
        let r = crop.rect.cgRect
        let px = CGRect(x: r.minX * canvas.width, y: r.minY * canvas.height,
                        width: r.width * canvas.width, height: r.height * canvas.height)
        let fitted = CropGeometry.constrain(rect: px, toAspect: ratio, within: CGRect(origin: .zero, size: canvas))
        crop.rect = CropRect(x: fitted.minX / canvas.width, y: fitted.minY / canvas.height,
                             w: fitted.width / canvas.width, h: fitted.height / canvas.height)
    }

    /// Swaps a portrait preset for its landscape twin and back ("3:2" <-> "2:3").
    public func toggleAspectOrientation() {
        setAspect(CropAspect.swapped(crop.aspect))
    }

    /// The part of a crop that changes the canvas picture (not the box or the preset).
    private static func geometryKey(_ c: CropSettings) -> [Double] {
        [c.straighten, Double(c.normalizedQuarterTurns), c.flipH ? 1 : 0, c.flipV ? 1 : 0]
    }


    // MARK: Zoom

    /// How the picture is shown: fitted, or zoomed (device pixels per picture pixel, so 1 is 100%).
    public private(set) var zoom: ZoomState = .fit
    /// "100%", "50%" or "FIT" for a moment after the zoom changes, else nil.
    public private(set) var zoomReadout: String?
    /// The pane under the pointer in device pixels, nil when the pointer is elsewhere (anchors `[` and `]`).
    @ObservationIgnored public var pointerInPane: CGPoint?
    @ObservationIgnored private var paneSize = CGSize.zero
    @ObservationIgnored private var fitAreaSize = CGSize.zero
    @ObservationIgnored private var readoutTask: Task<Void, Never>?
    /// How long the zoom readout stays on screen.
    nonisolated static let readoutDuration: Duration = .milliseconds(1200)

    /// The pane the picture is shown in and the area fit mode letterboxes it into, in device pixels.
    public func setViewport(pane: CGSize, fitArea: CGSize) {
        guard pane.width >= 1, pane.height >= 1 else { return }
        paneSize = pane
        fitAreaSize = CGSize(width: max(1, fitArea.width), height: max(1, fitArea.height))
        revalidateZoom()
    }

    /// The geometry the zoom maths works in, nil until there is a photo and a pane.
    public var zoomViewport: ZoomViewport? {
        guard let source, paneSize.width >= 1 else { return nil }
        let vp = ZoomViewport(content: PreviewEngine.zoomContentSize(for: recipe, imageSize: source.extent.size),
                              pane: paneSize, fitArea: fitAreaSize)
        return vp.isValid ? vp : nil
    }

    /// Zoom works on the full-resolution photo, outside the crop tool.
    public var canZoom: Bool { isSourceFull && !isCropping && zoomViewport != nil }

    /// The region the zoomed render covers, nil while fitted or when zooming is unavailable.
    private var zoomRegion: ZoomRegion? {
        guard canZoom, let vp = zoomViewport else { return nil }
        return ZoomGeometry.renderRegion(state: zoom, in: vp)
    }

    /// Where `frame` sits in the pane, in device pixels, for the current zoom. nil without a viewport.
    public func paneRect(of frame: PreviewFrame) -> CGRect? {
        guard let vp = zoomViewport else { return nil }
        return ZoomGeometry.paneRect(ofContentRect: frame.contentRect(whole: vp.content), state: zoom, in: vp)
    }

    /// A click on the photo: fit goes to 200% around the point, zoomed goes back to fit.
    public func zoomClick(atPane point: CGPoint) {
        guard canZoom, let vp = zoomViewport else { return }
        setZoom(ZoomGeometry.clicked(zoom, atPane: point, in: vp))
    }

    /// `]` (direction 1) and `[` (-1): one step along fit, 50%, 100%, 200%, 400%, anchored at the
    /// pointer when it is over the photo, else at the centre.
    public func zoomStep(_ direction: Int) {
        guard canZoom, let vp = zoomViewport else { return }
        var anchor = pointerInPane
        if let a = anchor, a.x < 0 || a.y < 0 || a.x > vp.pane.width || a.y > vp.pane.height { anchor = nil }
        setZoom(ZoomGeometry.stepped(zoom, by: direction, anchor: anchor, in: vp))
    }

    public func zoomToFit() {
        guard canZoom else { return }
        setZoom(.fit)
    }

    /// Drags the zoomed picture by `delta` device pixels.
    public func zoomPan(byPane delta: CGSize) {
        guard canZoom, let vp = zoomViewport, !zoom.isFit else { return }
        setZoom(ZoomGeometry.panned(zoom, byPane: delta, in: vp), showReadout: false)
    }

    /// Pinch: scales the zoom by `factor` between fit and 400%, anchored at a pane point (device pixels).
    public func zoomPinch(by factor: Double, atPane point: CGPoint) {
        guard canZoom, let vp = zoomViewport else { return }
        setZoom(ZoomGeometry.scaled(zoom, by: factor, anchor: point, in: vp))
    }

    private func setZoom(_ new: ZoomState, showReadout: Bool = true) {
        guard new != zoom else { return }
        let scaleChanged = new.scale != zoom.scale
        zoom = new
        if showReadout && scaleChanged { flashReadout() }
        schedulePreview()
        if let target = hoveredTarget { startHover(target, keepImage: true) }
    }

    /// Back to fit without a readout (new photo, crop tool, new crop).
    private func resetZoom() {
        guard !zoom.isFit else { return }
        zoom = .fit
        readoutTask?.cancel()
        zoomReadout = nil
    }

    /// Keeps the zoom valid after the pane or the picture's size changed.
    private func revalidateZoom() {
        guard !zoom.isFit else { return }
        guard let vp = zoomViewport else { return }
        let valid = ZoomGeometry.revalidated(zoom, in: vp)
        guard valid != zoom else { return }
        zoom = valid
        if valid.isFit { zoomReadout = nil }
        schedulePreview()
    }

    private func flashReadout() {
        zoomReadout = ZoomGeometry.readout(for: zoom)
        readoutTask?.cancel()
        readoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.readoutDuration)
            guard !Task.isCancelled else { return }
            self?.zoomReadout = nil
        }
    }

    // MARK: Canvas

    /// The size of the area the picture is shown in, in pixels (points x backing scale). Previews
    /// are rendered at this size, never larger than the photo. Sizes are rounded up to 64 px, so a
    /// window resize does not rebuild the preview source for every pixel.
    public func setCanvas(pixels: CGSize) {
        guard pixels.width >= 1, pixels.height >= 1 else { return }
        let size = PreviewSizing.quantised(canvas: pixels)
        guard size != canvasPixels else { return }
        canvasPixels = size
        guard engine.hasSource else { return }
        hoverCache = [:]
        hoverCacheOrder = []
        if let target = hoveredTarget { startHover(target, keepImage: true) }
        schedulePreview()
    }

    // MARK: Preview

    /// The recipe the canvas renders: while cropping, the whole canvas instead of the cropped box.
    private var previewRecipe: Recipe {
        guard isCropping else { return recipe }
        var r = recipe
        r.crop = crop.withFullRect
        return r
    }

    /// Queues a render of the current state. At most one render runs; a newer request replaces any
    /// waiting one, so a fast slider drag renders only the frames it can keep up with.
    private func schedulePreview() {
        guard engine.hasSource else { return }
        let request = PreviewRequest(recipe: previewRecipe, canvas: canvasPixels, generation: sourceGeneration,
                                     zoom: zoomRegion)
        if let start = gate.submit(request) { run(start) }
    }

    private func run(_ request: PreviewRequest) {
        let engine = engine
        let key = OriginalKey(crop: request.recipe.crop, canvas: request.canvas, generation: request.generation,
                              zoom: request.zoom)
        // The whole-picture original is kept ready; a zoomed one is only made while compare is held.
        let needsOriginal = !isCropping && originalKey != key && (request.zoom == nil || showOriginal)
        previewTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> (PreviewFrame?, PreviewFrame?) in
                let graded: PreviewFrame?
                var original: PreviewFrame?
                if let region = request.zoom {
                    graded = engine.renderZoomed(request.recipe, region: region)
                    original = needsOriginal ? engine.renderZoomed(Recipe(crop: request.recipe.crop), region: region) : nil
                } else {
                    graded = engine.render(request.recipe, canvas: request.canvas)
                    original = needsOriginal ? engine.renderOriginal(crop: request.recipe.crop, canvas: request.canvas) : nil
                }
                return (graded, original)
            }.value
            guard let self else { return }
            if !Task.isCancelled, request.generation == self.sourceGeneration {
                if let original = result.1 {
                    self.originalFrame = original
                    self.originalKey = key
                }
                if let graded = result.0 {
                    self.previewFrame = graded
                    self.publishedFrames += 1
                }
            }
            if let next = self.gate.finish() { self.run(next) }
        }
    }

    /// True when no render is running or waiting (tests wait on this to see the settled frame).
    var isPreviewIdle: Bool { !gate.isBusy }

    /// The frame to show for the current state. Press-and-hold compare wins over a hover preview.
    public var displayedFrame: PreviewFrame? {
        if isCropping { return previewFrame }
        if showOriginal { return originalFrame ?? previewFrame }
        return visibleHoverFrame ?? previewFrame
    }

    /// The rendered preview as an image (for snapshots and tests; the canvas shows `displayedFrame`).
    public var previewImage: NSImage? { previewFrame.flatMap(nsImage) }

    /// The image to show for the current state, as an `NSImage` (snapshots and tests).
    public var displayedImage: NSImage? { displayedFrame.flatMap(nsImage) }

    private func nsImage(_ frame: PreviewFrame) -> NSImage? {
        if let hit = imageCache[frame.id] { return hit }
        guard let cg = frame.cgImage(context: engine.context) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        if imageCache.count > 8 { imageCache = [:] }
        imageCache[frame.id] = image
        return image
    }

    /// The hover render, only while it is ready and differs from the applied look.
    private var visibleHoverFrame: PreviewFrame? {
        guard !isCropping, let target = hoveredTarget, target != appliedTarget else { return nil }
        return hoverFrame
    }

    private var appliedTarget: HoverTarget {
        recipe.filmID.map(HoverTarget.film) ?? .original
    }

    /// The film being previewed, non-nil only while its hover image is actually displayed.
    public var hoverPreviewFilm: Film? {
        guard !showOriginal, visibleHoverFrame != nil, let id = hoveredTarget?.filmID else { return nil }
        return library.film(id: id)
    }

    /// Label text for the canvas chip ("Original" or the film name), nil unless a hover image is displayed.
    public var hoverPreviewName: String? {
        guard !showOriginal, visibleHoverFrame != nil, let target = hoveredTarget else { return nil }
        if case .original = target { return "Original" }
        return hoverPreviewFilm?.displayName
    }

    // MARK: Hover preview

    /// Previews `id` (nil for Original) on the canvas with the current sliders, after a short debounce.
    public func hoverFilm(_ id: String?) {
        guard !isCropping else { return }
        startHover(id.map(HoverTarget.film) ?? .original, keepImage: false)
    }

    /// The pointer left the film strip: back to the applied look immediately.
    public func endHover() {
        hoverGeneration += 1
        hoverTask?.cancel()
        hoverTask = nil
        hoveredTarget = nil
        hoverFrame = nil
    }

    private func recipeChangedWhileHovering() {
        hoverCache = [:]
        hoverCacheOrder = []
        if let target = hoveredTarget { startHover(target, keepImage: true) }
    }

    private func startHover(_ target: HoverTarget, keepImage: Bool) {
        hoverGeneration += 1
        let generation = hoverGeneration
        hoverTask?.cancel()
        hoverTask = nil
        hoveredTarget = target
        if !keepImage { hoverFrame = nil }
        guard engine.hasSource else { return }

        var swapped = recipe
        swapped.filmID = target.filmID
        let graded = swapped
        let canvas = canvasPixels
        let zoom = zoomRegion
        let key = HoverKey(filmID: target.filmID, recipe: graded, canvas: canvas, zoom: zoom)
        if let cached = hoverCache[key] {
            hoverFrame = cached
            return
        }
        let engine = engine
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDebounce)
            if Task.isCancelled { return }
            let frame = await Task.detached(priority: .userInitiated) {
                zoom.map { engine.renderZoomed(graded, region: $0) } ?? engine.render(graded, canvas: canvas)
            }.value
            guard !Task.isCancelled, let self, self.hoverGeneration == generation, let frame else { return }
            self.storeHover(frame, for: key)
            self.hoverFrame = frame
        }
    }

    private func storeHover(_ frame: PreviewFrame, for key: HoverKey) {
        hoverCache[key] = frame
        hoverCacheOrder.removeAll { $0 == key }
        hoverCacheOrder.append(key)
        while hoverCacheOrder.count > Self.hoverCacheLimit {
            hoverCache[hoverCacheOrder.removeFirst()] = nil
        }
    }

    // MARK: Thumbnails

    private struct ThumbnailResult: @unchecked Sendable {
        let id: String?
        let image: CGImage
    }

    /// Renders the film strip: one small bitmap made from the full-size source (with the current
    /// crop applied, so the strip matches the canvas), graded once per film, a few at a time.
    /// Results are cached per crop, so going back to a crop already seen is instant.
    nonisolated static let thumbnailFlushInterval: Duration = .milliseconds(60)

    private func startThumbnails() {
        thumbnailTask?.cancel()
        thumbnailCancel?.cancel()
        guard engine.hasSource else { return }
        let crop = recipe.crop
        let generation = contentGeneration
        let ids: [String?] = [nil] + library.films.map { Optional($0.id) }
        if let cached = thumbnailCache[crop], cached.count == ids.count {
            thumbnails = cached
            return
        }
        let cancel = CancelFlag()
        thumbnailCancel = cancel
        let engine = engine
        let (stream, continuation) = AsyncStream.makeStream(of: ThumbnailResult.self)
        thumbnailTask = Task { [weak self] in
            await withTaskCancellationHandler {
                Task.detached(priority: .utility) {
                    engine.renderThumbnails(ids: ids, crop: crop, longSide: Self.thumbnailLongSide,
                                            isCancelled: { cancel.isCancelled }) { id, cg in
                        continuation.yield(ThumbnailResult(id: id, image: cg))
                    }
                    continuation.finish()
                }
                // Thumbnails are published in small batches: every write to `thumbnails`
                // re-evaluates the whole film strip.
                var batch: [String: NSImage] = [:]
                var lastFlush = ContinuousClock.now
                for await item in stream {
                    guard let self, self.contentGeneration == generation, !cancel.isCancelled else {
                        cancel.cancel()
                        batch = [:]
                        break
                    }
                    let image = NSImage(cgImage: item.image,
                                        size: NSSize(width: item.image.width, height: item.image.height))
                    let key = item.id ?? Self.originalTileID
                    batch[key] = image
                    self.cacheThumbnail(image, key: key, crop: crop)
                    if lastFlush.duration(to: .now) >= Self.thumbnailFlushInterval {
                        self.thumbnails.merge(batch) { $1 }
                        batch = [:]
                        lastFlush = .now
                    }
                }
                if !batch.isEmpty, let self, self.contentGeneration == generation, !cancel.isCancelled {
                    self.thumbnails.merge(batch) { $1 }
                }
            } onCancel: {
                cancel.cancel()
                continuation.finish()
            }
        }
    }

    private func cacheThumbnail(_ image: NSImage, key: String, crop: CropSettings) {
        if thumbnailCache[crop] == nil {
            thumbnailCache[crop] = [:]
            thumbnailCacheOrder.append(crop)
            while thumbnailCacheOrder.count > Self.thumbnailCacheLimit {
                thumbnailCache[thumbnailCacheOrder.removeFirst()] = nil
            }
        }
        thumbnailCache[crop]?[key] = image
    }

    // MARK: Histogram

    /// Tells the model which frame is on the canvas. The histogram follows at most 20 times a
    /// second, off the main actor; a pass never starts while another is running, and only the
    /// newest frame waits.
    public func histogramFrameChanged(_ frame: PreviewFrame?) {
        guard let frame else { return }
        histogramPending = frame
        pumpHistogram()
    }

    /// Computes the histogram of the displayed frame now and waits for it (tests and snapshots).
    func refreshHistogramNow() async {
        guard let frame = displayedFrame else { return }
        let data = await Task.detached { HistogramData.compute(frame: frame) }.value
        histogram = data
    }

    private func pumpHistogram() {
        guard !histogramInFlight, histogramPending != nil else { return }
        histogramInFlight = true
        let wait: Duration = histogramLast.map { max(.zero, Self.histogramInterval - ($0.duration(to: .now))) } ?? .zero
        Task { [weak self] in
            if wait > .zero { try? await Task.sleep(for: wait) }
            guard let self, let frame = self.histogramPending else { self?.histogramInFlight = false; return }
            self.histogramPending = nil
            let data = await Task.detached(priority: .utility) { HistogramData.compute(frame: frame) }.value
            self.histogram = data
            self.histogramLast = .now
            self.histogramInFlight = false
            if self.histogramPending != nil { self.pumpHistogram() }
        }
    }

    // MARK: Eyedropper

    /// Picks the colour-mixer range for the colour at `point` (fractions of the displayed picture,
    /// origin top left), selects it and turns the eyedropper off. Returns nil, leaving the
    /// selection alone, for greys and points outside the picture.
    @discardableResult
    public func sampleRange(atImagePoint point: CGPoint) -> ColorRange? {
        defer { eyedropperActive = false }
        guard let frame = displayedFrame, let c = frame.color(atNormalized: point),
              let range = ColorRange.nearest(sRGB: c.r, c.g, c.b) else { return nil }
        mixerRange = range
        return range
    }

    /// Stops background work (used when an editing session is cancelled).
    public func cancelWork() {
        gate.cancelPending()
        previewTask?.cancel()
        thumbnailTask?.cancel()
        thumbnailCancel?.cancel()
        hoverTask?.cancel()
        fullDecodeTask?.cancel()
    }
}
