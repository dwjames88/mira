#if os(iOS)
import CoreImage
import Foundation
import MiraCameraKit
import MiraCore
import Photos
import Synchronization
import UniformTypeIdentifiers

/// Holds the placeholder identifier a `performChanges` block produced.
private final class IdentifierBox: Sendable {
    private let value = Mutex<String?>(nil)
    func set(_ id: String) { value.withLock { $0 = id } }
    var id: String? { value.withLock { $0 } }
}

public enum PhotoLibraryError: Error, Sendable, Equatable {
    case noIdentifier
    case noFilmLibrary
    case renderFailed
}

/// Step 1 of the save, with PhotoKit. Every closure handed to Photos is `@Sendable` and built in a
/// `nonisolated` static, because Photos calls them on its own queues (a main-actor closure there crashes).
public struct PhotoKitLibraryWriter: PhotoLibraryWriting {
    public init() {}

    public func access() async -> LibraryAccess {
        Self.currentAccess()
    }

    /// Asks for read-write access if it was never asked. The UI calls this; the saver never does.
    public nonisolated static func requestAccess() async -> LibraryAccess {
        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return currentAccess()
    }

    nonisolated static func currentAccess() -> LibraryAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: return .full
        case .limited: return .limited
        case .denied, .restricted, .notDetermined:
            let addOnly = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            if addOnly == .authorized { return .addOnly }
            return PHPhotoLibrary.authorizationStatus(for: .readWrite) == .notDetermined && addOnly == .notDetermined ? .notDetermined : .denied
        @unknown default: return .denied
        }
    }

    public func createAsset(photo: URL, alternateRaw: URL?) async throws -> String {
        try await Self.create { request in
            let heic = PHAssetResourceCreationOptions()
            heic.shouldMoveFile = true
            heic.uniformTypeIdentifier = photo.pathExtension.lowercased() == "heic" ? UTType.heic.identifier : nil
            request.addResource(with: .photo, fileURL: photo, options: heic)
            if let alternateRaw {
                let dng = PHAssetResourceCreationOptions()
                dng.shouldMoveFile = true
                dng.uniformTypeIdentifier = UTType.dng.identifier
                request.addResource(with: .alternatePhoto, fileURL: alternateRaw, options: dng)
            }
        }
    }

    public func createBakedCopy(jpeg: URL) async throws -> String {
        try await Self.create { request in
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            options.uniformTypeIdentifier = UTType.jpeg.identifier
            request.addResource(with: .photo, fileURL: jpeg, options: options)
        }
    }

    /// Creates one asset; `fill` adds the resources. Returns the new asset's local identifier.
    private nonisolated static func create(_ fill: @escaping @Sendable (PHAssetCreationRequest) -> Void) async throws -> String {
        let box = IdentifierBox()
        try await PHPhotoLibrary.shared().performChanges(makeChanges(box: box, fill: fill))
        guard let id = box.id else { throw PhotoLibraryError.noIdentifier }
        return id
    }

    private nonisolated static func makeChanges(
        box: IdentifierBox, fill: @escaping @Sendable (PHAssetCreationRequest) -> Void
    ) -> @Sendable () -> Void {
        { @Sendable in
            let request = PHAssetCreationRequest.forAsset()
            fill(request)
            if let id = request.placeholderForCreatedAsset?.localIdentifier { box.set(id) }
        }
    }
}

/// Renders the recipe over the capture (the HEIC, or the DNG developed through `RawDevelop` when there is one)
/// into a temp JPEG at 0.95, for libraries where the recipe cannot be attached.
public struct PhotoKitBaker: PrintBaking {
    private let library: FilmLibrary?

    public init(bundle: Bundle = .main) {
        library = FilmLibrary.bundled(in: bundle)
    }

    public init(library: FilmLibrary) {
        self.library = library
    }

    public func bake(recipe: Recipe, photo: URL, raw: URL?) async throws -> URL {
        guard let library else { throw PhotoLibraryError.noFilmLibrary }
        let renderer = Renderer(library: library)
        return try await Task.detached(priority: .utility) {
            try Self.render(renderer: renderer, recipe: recipe, photo: photo, raw: raw)
        }.value
    }

    private static func render(renderer: Renderer, recipe: Recipe, photo: URL, raw: URL?) throws -> URL {
        let source: CIImage
        let space: CGColorSpace
        if let raw, let develop = RawDevelop(url: raw),
           let developed = develop.develop(recipe.raw, filmApplied: recipe.filmID != nil, draft: false)?.image {
            source = developed
            space = ImageSource.outputColorSpace(url: raw, image: developed)
        } else if let loaded = ImageSource.loadWithColorSpace(url: photo) {
            source = loaded.image
            space = loaded.colorSpace
        } else {
            throw PhotoLibraryError.renderFailed
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "MiraCamera", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory.appending(path: "\(UUID().uuidString)-baked.jpg")
        do {
            try renderer.export(recipe, source: source, metadataFrom: photo, outputURL: output, type: .jpeg, quality: 0.95, colorSpace: space)
        } catch {
            try? FileManager.default.removeItem(at: output)   // a failed export can leave a partial file
            throw error
        }
        return output
    }
}
#endif
