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

/// State of the shared editor: the source photo, the current recipe, and the rendered previews.
@MainActor
@Observable
public final class EditorModel {
    public let library: FilmLibrary
    public let renderer: Renderer

    /// Full-size source, orientation already applied.
    public private(set) var source: CIImage?
    /// Source scaled to about 1600 px on its long side. Previews render from this.
    public private(set) var previewSource: CIImage?

    public var recipe: Recipe {
        didSet {
            guard recipe != oldValue else { return }
            schedulePreview()
            recipeChangedWhileHovering()
        }
    }
    public var showOriginal = false

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

    /// The rendered preview (graded, or the original while `showOriginal`).
    public private(set) var previewImage: NSImage?
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
    private var hoverImage: NSImage?

    public static let originalTileID = "__original__"
    public nonisolated static let previewLongSide: CGFloat = 1600
    public nonisolated static let thumbnailLongSide: CGFloat = 160

    @ObservationIgnored private let context: CIContext
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var originalPreview: NSImage?
    @ObservationIgnored private var originalPreviewCrop: CropSettings?
    @ObservationIgnored private var sourceGeneration = 0
    @ObservationIgnored private var hoverTask: Task<Void, Never>?
    @ObservationIgnored private var hoverGeneration = 0
    @ObservationIgnored private var hoverCache: [HoverKey: NSImage] = [:]
    @ObservationIgnored private var hoverCacheOrder: [HoverKey] = []

    private struct HoverKey: Hashable {
        let filmID: String?
        let recipe: Recipe
    }
    private static let hoverCacheLimit = 6
    nonisolated static let hoverDebounce: Duration = .milliseconds(120)

    public init(library: FilmLibrary, recipe: Recipe = .neutral) {
        self.library = library
        self.renderer = Renderer(library: library)
        self.context = Renderer.makeContext()
        self.recipe = recipe
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

    /// Sets the photo to edit. `image` must already be upright.
    public func setSource(_ image: CIImage) {
        sourceGeneration += 1
        isCropping = false
        source = image
        previewSource = renderer.previewImage(from: image, maxPixelSize: Self.previewLongSide)
        thumbnails = [:]
        originalPreview = nil
        originalPreviewCrop = nil
        previewImage = nil
        hoverCache = [:]
        hoverCacheOrder = []
        if let target = hoveredTarget { startHover(target, keepImage: false) }
        schedulePreview()
        startThumbnails()
    }

    /// Loads an image file (RAW included), applying its own orientation exactly once.
    @discardableResult
    public func loadSource(url: URL) -> Bool {
        loadSource(url: url, orientation: nil)
    }

    /// Loads an image file and applies `orientation` to its pixels (Photos'
    /// `fullSizeImageOrientation`). nil uses the file's own orientation.
    @discardableResult
    public func loadSource(url: URL, orientation: CGImagePropertyOrientation?) -> Bool {
        guard let image = ImageSource.load(url: url, orientation: orientation) else { return false }
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

    // MARK: Crop

    /// Opens the crop tool on a copy of the recipe's crop. The canvas then shows the whole picture
    /// (rotated, flipped and straightened) so the box can reach anything.
    public func beginCrop() {
        guard !isCropping, previewSource != nil else { return }
        endHover()
        showOriginal = false
        crop = recipe.crop
        isCropping = true
        schedulePreview()
    }

    /// Done: writes the working crop to `recipe.crop` and closes the tool.
    public func commitCrop() {
        guard isCropping else { return }
        var result = crop
        result.rect = result.rect.clamped()
        if result.isIdentity { result = .identity }
        isCropping = false
        recipe.crop = result
        schedulePreview()
    }

    /// Cancel: drops the working copy; the recipe is untouched.
    public func cancelCrop() {
        guard isCropping else { return }
        isCropping = false
        crop = recipe.crop
        schedulePreview()
    }

    public func toggleCrop() {
        if isCropping { commitCrop() } else { beginCrop() }
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
        previewSource.map { CropGeometry.orientedSize(for: crop, size: $0.extent.size) }
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

    /// What the preview renders: while cropping, the whole canvas instead of the cropped box.
    private var previewRecipe: Recipe {
        guard isCropping else { return recipe }
        var r = recipe
        r.crop = crop.withFullRect
        return r
    }

    // MARK: Preview

    private func schedulePreview() {
        guard let input = previewSource else { return }
        previewTask?.cancel()
        let recipe = previewRecipe
        let renderer = renderer
        let context = context
        let box = Unchecked(value: input)
        let originalRecipe = Recipe(crop: recipe.crop)
        let needsOriginal = originalPreview == nil || originalPreviewCrop != recipe.crop
        previewTask = Task { [weak self] in
            // Coalesce bursts of slider changes: the latest task wins.
            try? await Task.sleep(for: .milliseconds(12))
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (Unchecked<CGImage>?, Unchecked<CGImage>?) in
                let graded = renderer.render(recipe, input: box.value, context: context).map(Unchecked.init)
                let original = needsOriginal
                    ? renderer.render(originalRecipe, input: box.value, context: context).map(Unchecked.init)
                    : nil
                return (graded, original)
            }.value
            if Task.isCancelled { return }
            guard let self else { return }
            if let cg = result.1?.value {
                self.originalPreview = Self.nsImage(cg)
                self.originalPreviewCrop = originalRecipe.crop
            }
            if let cg = result.0?.value { self.previewImage = Self.nsImage(cg) }
        }
    }

    /// The image to show for the current state. Press-and-hold compare wins over a hover preview.
    public var displayedImage: NSImage? {
        if isCropping { return previewImage }
        if showOriginal { return originalPreview ?? previewImage }
        return visibleHoverImage ?? previewImage
    }

    /// The hover render, only while it is ready and differs from the applied look.
    private var visibleHoverImage: NSImage? {
        guard !isCropping, let target = hoveredTarget, target != appliedTarget else { return nil }
        return hoverImage
    }

    private var appliedTarget: HoverTarget {
        recipe.filmID.map(HoverTarget.film) ?? .original
    }

    /// The film being previewed, non-nil only while its hover image is actually displayed.
    public var hoverPreviewFilm: Film? {
        guard !showOriginal, visibleHoverImage != nil, let id = hoveredTarget?.filmID else { return nil }
        return library.film(id: id)
    }

    /// Label text for the canvas chip ("Original" or the film name), nil unless a hover image is displayed.
    public var hoverPreviewName: String? {
        guard !showOriginal, visibleHoverImage != nil, let target = hoveredTarget else { return nil }
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
        hoverImage = nil
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
        if !keepImage { hoverImage = nil }
        guard let input = previewSource else { return }

        var swapped = recipe
        swapped.filmID = target.filmID
        let graded = swapped
        let key = HoverKey(filmID: target.filmID, recipe: graded)
        if let cached = hoverCache[key] {
            hoverImage = cached
            return
        }
        let renderer = renderer
        let context = context
        let box = Unchecked(value: input)
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverDebounce)
            if Task.isCancelled { return }
            let cg = await Task.detached(priority: .userInitiated) {
                renderer.render(graded, input: box.value, context: context).map(Unchecked.init)
            }.value
            guard !Task.isCancelled, let self, self.hoverGeneration == generation, let cg else { return }
            let image = Self.nsImage(cg.value)
            self.storeHover(image, for: key)
            self.hoverImage = image
        }
    }

    private func storeHover(_ image: NSImage, for key: HoverKey) {
        hoverCache[key] = image
        hoverCacheOrder.removeAll { $0 == key }
        hoverCacheOrder.append(key)
        while hoverCacheOrder.count > Self.hoverCacheLimit {
            hoverCache[hoverCacheOrder.removeFirst()] = nil
        }
    }

    // MARK: Thumbnails

    private func startThumbnails() {
        thumbnailTask?.cancel()
        guard let input = previewSource else { return }
        let generation = sourceGeneration
        let renderer = renderer
        let context = context
        let films = library.films
        let box = Unchecked(value: input)
        thumbnailTask = Task { [weak self] in
            // Tiny source, rendered once to pixels so each film only grades ~160 px.
            let tiny = await Task.detached(priority: .utility) { () -> Unchecked<CIImage>? in
                let small = renderer.previewImage(from: box.value, maxPixelSize: Self.thumbnailLongSide)
                guard let cg = context.createCGImage(small, from: small.extent, format: .RGBA8,
                                                     colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                else { return nil }
                return Unchecked(value: CIImage(cgImage: cg))
            }.value
            guard let tiny else { return }

            var ids: [String?] = [nil]
            ids.append(contentsOf: films.map { Optional($0.id) })
            let maxInFlight = 4

            // Bounded parallelism: keep up to `maxInFlight` renders going, publish each as it lands.
            await withTaskGroup(of: (String?, Unchecked<CGImage>?).self) { group in
                var iterator = ids.makeIterator()
                func addNext() -> Bool {
                    guard let id = iterator.next() else { return false }
                    let recipe = Recipe(filmID: id)
                    group.addTask(priority: .utility) {
                        if Task.isCancelled { return (id, nil) }
                        return (id, renderer.render(recipe, input: tiny.value, context: context).map(Unchecked.init))
                    }
                    return true
                }
                for _ in 0..<maxInFlight { if !addNext() { break } }
                while let (id, cg) = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        continue
                    }
                    guard let self, self.sourceGeneration == generation else {
                        group.cancelAll()
                        continue
                    }
                    if let cg { self.thumbnails[id ?? Self.originalTileID] = Self.nsImage(cg.value) }
                    _ = addNext()
                }
            }
        }
    }

    /// Stops background work (used when an editing session is cancelled).
    public func cancelWork() {
        previewTask?.cancel()
        thumbnailTask?.cancel()
        hoverTask?.cancel()
    }

    private static func nsImage(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
