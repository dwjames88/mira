import AppKit
import CoreImage
import EmulsionCore
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
        didSet { if recipe != oldValue { schedulePreview() } }
    }
    public var showOriginal = false
    public var familyFilter: FilmFamily?

    /// The rendered preview (graded, or the original while `showOriginal`).
    public private(set) var previewImage: NSImage?
    /// Thumbnails by film id. The key `EditorModel.originalTileID` holds the untouched tile.
    public private(set) var thumbnails: [String: NSImage] = [:]

    public static let originalTileID = "__original__"
    public nonisolated static let previewLongSide: CGFloat = 1600
    public nonisolated static let thumbnailLongSide: CGFloat = 160

    @ObservationIgnored private let context: CIContext
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var originalPreview: NSImage?
    @ObservationIgnored private var sourceGeneration = 0

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
        source = image
        previewSource = renderer.previewImage(from: image, maxPixelSize: Self.previewLongSide)
        thumbnails = [:]
        originalPreview = nil
        previewImage = nil
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
        recipe.filmID = id
    }

    /// Resets every slider to its default and keeps the selected film.
    public func reset() {
        recipe = Recipe(filmID: recipe.filmID)
    }

    // MARK: Preview

    private func schedulePreview() {
        guard let input = previewSource else { return }
        previewTask?.cancel()
        let recipe = recipe
        let renderer = renderer
        let context = context
        let box = Unchecked(value: input)
        let needsOriginal = originalPreview == nil
        previewTask = Task { [weak self] in
            // Coalesce bursts of slider changes: the latest task wins.
            try? await Task.sleep(for: .milliseconds(12))
            if Task.isCancelled { return }
            let result = await Task.detached(priority: .userInitiated) { () -> (Unchecked<CGImage>?, Unchecked<CGImage>?) in
                let graded = renderer.render(recipe, input: box.value, context: context).map(Unchecked.init)
                let original = needsOriginal
                    ? renderer.render(.neutral, input: box.value, context: context).map(Unchecked.init)
                    : nil
                return (graded, original)
            }.value
            if Task.isCancelled { return }
            guard let self else { return }
            if let cg = result.1?.value { self.originalPreview = Self.nsImage(cg) }
            if let cg = result.0?.value { self.previewImage = Self.nsImage(cg) }
        }
    }

    /// The image to show for the current state.
    public var displayedImage: NSImage? {
        showOriginal ? (originalPreview ?? previewImage) : previewImage
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
    }

    private static func nsImage(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
