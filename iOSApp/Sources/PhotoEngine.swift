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
    private var histogramSource: CIImage?
    private var thumb: CIImage?

    init() {
        let lib = FilmLibrary.bundled(in: .main)
        library = lib
        renderer = lib.map { Renderer(library: $0) }
    }

    nonisolated static let filmList: [Film] = FilmLibrary.bundled(in: .main)?.films ?? []

    /// Loads an upright image from `data`; returns the source for the live view.
    func load(data: Data) throws -> LoadedSource {
        guard let renderer else { throw PhotoEngineError.noLibrary }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mira-source-\(UUID().uuidString)")
        try data.write(to: url)
        if let old = sourceURL { try? FileManager.default.removeItem(at: old) }
        guard let loaded = ImageSource.loadWithColorSpace(url: url) else { throw PhotoEngineError.cannotLoad }
        sourceURL = url
        source = loaded.image
        colorSpace = loaded.colorSpace
        histogramSource = renderer.previewImage(from: loaded.image, maxPixelSize: 480)
        thumb = renderer.previewImage(from: loaded.image, maxPixelSize: 220)
        let space = loaded.colorSpace
        return LoadedSource(image: loaded.image, colorSpace: space, size: loaded.image.extent.size)
    }

    /// Histogram of the graded small preview. Called throttled, never per frame.
    func histogram(for recipe: Recipe) throws -> HistogramData {
        guard let renderer, let histogramSource else { throw PhotoEngineError.cannotLoad }
        return Self.histogram(of: renderer.apply(recipe, to: histogramSource))
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
        guard let renderer, let thumb else { throw PhotoEngineError.cannotLoad }
        return try Self.encode(renderer.apply(Recipe(filmID: filmID), to: thumb), colorSpace: colorSpace)
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

    static func saveToLibrary(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotoEngineError.notAuthorized }
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, fileURL: url, options: PHAssetResourceCreationOptions())
        }
        try? FileManager.default.removeItem(at: url)
    }
}
