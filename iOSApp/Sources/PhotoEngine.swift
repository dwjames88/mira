import CoreImage
import Foundation
import ImageIO
import MiraCore
import Photos
import UniformTypeIdentifiers

enum PhotoEngineError: Error, LocalizedError {
    case noLibrary, cannotLoad, renderFailed, notAuthorized
    var errorDescription: String? {
        switch self {
        case .noLibrary: "Film library missing from the app bundle"
        case .cannotLoad: "Could not read that photo"
        case .renderFailed: "Render failed"
        case .notAuthorized: "Photos access was denied"
        }
    }
}

/// Hand-off of the decoded source to the main-actor live view. `CIImage` is immutable here and is
/// never mutated after decode, so crossing the actor boundary is safe.
struct LoadedSource: @unchecked Sendable {
    let image: CIImage
    let colorSpace: CGColorSpace
    let size: CGSize
}

/// Owns the non-Sendable CoreImage source and renders off the main actor.
/// Everything crossing the actor boundary is `Data`, `String` or value types.
actor PhotoEngine {
    private let library: FilmLibrary?
    private let renderer: Renderer?
    private var sourceURL: URL?
    private var source: CIImage?
    private var colorSpace: CGColorSpace?
    /// The histogram's and the film cards' small copies of `source`, made on first use (see `smallCopies()`).
    private var small: (histogram: CIImage, thumb: CIImage)?
    /// The caller's number of the source held now (see `discard(upTo:)`).
    private var epoch = 0

    init() {
        let lib = Self.library
        library = lib
        renderer = lib.map { Renderer(library: $0) }
    }

    nonisolated static let library: FilmLibrary? = FilmLibrary.bundled(in: .main)
    nonisolated static let filmList: [Film] = library?.films ?? []

    /// Loads an upright image from `data`; returns the source for the live view.
    func load(data: Data, epoch: Int = 0) throws -> LoadedSource {
        guard renderer != nil else { throw PhotoEngineError.noLibrary }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mira-source-\(UUID().uuidString)")
        try data.write(to: url)
        // A photo that cannot be read leaves the one already held (and its file) alone.
        guard let loaded = ImageSource.loadWithColorSpace(url: url) else {
            try? FileManager.default.removeItem(at: url)
            throw PhotoEngineError.cannotLoad
        }
        if let old = sourceURL { try? FileManager.default.removeItem(at: old) }
        self.epoch = epoch
        sourceURL = url
        source = loaded.image
        colorSpace = loaded.colorSpace
        small = nil
        let space = loaded.colorSpace
        return LoadedSource(image: loaded.image, colorSpace: space, size: loaded.image.extent.size)
    }

    /// Adopts an already-decoded original (library asset) for histogram and film thumbnails.
    /// Export of library assets goes through `AssetEditSession`, not this engine.
    func adopt(_ loaded: LoadedSource, epoch: Int = 0) throws {
        guard renderer != nil else { throw PhotoEngineError.noLibrary }
        if let old = sourceURL { try? FileManager.default.removeItem(at: old) }
        self.epoch = epoch
        sourceURL = nil
        source = loaded.image
        colorSpace = loaded.colorSpace
        small = nil
    }

    /// Lets go of the held source, its temp copy and the derived small images, unless a newer one (`epoch` above
    /// `upTo`) was handed over after the caller decided to discard.
    func discard(upTo: Int) {
        guard epoch <= upTo else { return }
        if let old = sourceURL { try? FileManager.default.removeItem(at: old) }
        sourceURL = nil
        source = nil
        colorSpace = nil
        small = nil
    }

    /// Small copies of the source for the histogram (480 px) and the film cards (220 px), materialised on first use and
    /// kept. Left lazy, every histogram tick (about 10 Hz while a slider moves) and every card would scale the whole
    /// source down again. Made here, not when the source is handed over, so opening a photo does not wait for them.
    private func smallCopies() -> (histogram: CIImage, thumb: CIImage)? {
        if let small { return small }
        guard let renderer, let source else { return nil }
        func make(_ side: CGFloat) -> CIImage {
            Self.tagged(PreviewProxy.make(from: source, renderer: renderer, context: Renderer.sharedContext, wanted: side),
                        like: source)
        }
        let made = (histogram: make(480), thumb: make(220))
        small = made
        return made
    }

    /// A derived image keeps the source's EXIF exposure time and headroom (the reciprocity and exposure stages read them).
    private static func tagged(_ image: CIImage, like source: CIImage) -> CIImage {
        image.withMiraExposureTime(source.miraExposureTime).withMiraHeadroom(source.miraHeadroom)
    }

    /// Histogram of the graded small preview. Called throttled, never per frame.
    func histogram(for recipe: Recipe) throws -> HistogramData {
        guard let renderer, let copies = smallCopies() else { throw PhotoEngineError.cannotLoad }
        return Self.histogram(of: renderer.apply(recipe, to: copies.histogram))
    }

    private static func histogram(of image: CIImage) -> HistogramData {
        let extent = image.extent.integral
        let w = Int(extent.width), h = Int(extent.height)
        guard w > 0, h > 0, extent.width.isFinite else { return .empty }
        let rowBytes = w * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * h)
        bytes.withUnsafeMutableBytes { buf in
            Renderer.sharedContext.render(image, toBitmap: buf.baseAddress!, rowBytes: rowBytes,
                                          bounds: extent, format: .BGRA8,
                                          colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return bytes.withUnsafeBytes {
            HistogramData.compute(bgra: $0.baseAddress!, width: w, height: h, rowBytes: rowBytes)
        }
    }

    func renderThumbnail(filmID: String?) throws -> Data {
        // Cards queue here one by one; one whose request was cancelled while it waited (scrolled away) is skipped.
        try Task.checkCancellation()
        guard let renderer, let copies = smallCopies() else { throw PhotoEngineError.cannotLoad }
        // Same card recipe as the Mac strip: the film at its native grain, halation and bloom (what applying it gives).
        let recipe = Recipe(filmID: filmID, reciprocity: .off).applyingNativeTexture(filmID: filmID)
        return try Self.encode(renderer.apply(recipe, to: copies.thumb), colorSpace: colorSpace)
    }

    /// Full-size export to a temp JPEG; returns its URL.
    func exportFull(_ recipe: Recipe) throws -> URL {
        guard let renderer, let source, let sourceURL else { throw PhotoEngineError.cannotLoad }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("Mira-\(UUID().uuidString).jpg")
        try renderer.export(recipe, source: source, metadataFrom: sourceURL, outputURL: out,
                            type: .jpeg, quality: 0.95, colorSpace: colorSpace)
        return out
    }

    private static func encode(_ image: CIImage, colorSpace: CGColorSpace?) throws -> Data {
        let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let data = Renderer.sharedContext.jpegRepresentation(
            of: image, colorSpace: space,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.85]
        ) else { throw PhotoEngineError.renderFailed }
        return data
    }

    /// Adds the JPEG at `url` to the library as a new photo; the file is removed whether or not that succeeds.
    static func saveToLibrary(_ url: URL) async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoEngineError.notAuthorized }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, fileURL: url, options: PHAssetResourceCreationOptions())
        }
    }
}
