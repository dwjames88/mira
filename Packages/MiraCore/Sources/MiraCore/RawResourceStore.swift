import Foundation
import Photos

extension PHAssetResource: AssetResourceFields {
    public var resourceKind: AssetResourceKind {
        switch type {
        case .photo: .photo
        case .alternatePhoto: .alternatePhoto
        case .fullSizePhoto: .fullSizePhoto
        default: .other
        }
    }
    public var typeIdentifier: String { uniformTypeIdentifier }
}

/// Downloads an asset's RAW original (a `PHAssetResource`) into a per-asset session cache folder and
/// keeps the newest few. Every PhotoKit closure is built here, `nonisolated`, because Photos calls
/// them back on its own queues (a main-actor closure traps in Swift 6).
public enum RawResourceStore {
    public static let keptAssets = 6

    /// `Caches/MiraRawSession`.
    public static var root: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiraRawSession", isDirectory: true)
    }

    /// The RAW resource of the asset, nil when it has none.
    nonisolated public static func rawResource(forAsset localIdentifier: String) -> PHAssetResource? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil).firstObject else { return nil }
        let resources = PHAssetResource.assetResources(for: asset)
        return RawResourceSelection.rawIndex(in: resources).map { resources[$0] }
    }

    public enum FetchError: Error { case noRawResource, writeFailed(String) }

    /// The RAW file of the asset on disk: reused from an earlier open this session, else written by
    /// `PHAssetResourceManager.writeData` (network allowed: iCloud originals download, `progress` 0...1).
    nonisolated public static func fetchRaw(
        forAsset localIdentifier: String, progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> URL {
        guard let resource = rawResource(forAsset: localIdentifier) else { throw FetchError.noRawResource }
        let folder = root.appendingPathComponent(sanitized(localIdentifier), isDirectory: true)
        let name = resource.originalFilename.isEmpty ? "original.raw" : resource.originalFilename
        let final = folder.appendingPathComponent(name)
        let fm = FileManager.default
        if fm.fileExists(atPath: final.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
            return final
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent(".partial-\(UUID().uuidString)")
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        if let progress { options.progressHandler = { @Sendable value in progress(value) } }
        let box = ResourceBox(resource: resource, options: options)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: box.resource, toFile: partial, options: box.options) { @Sendable error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        do {
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            throw FetchError.writeFailed("\(error)")
        }
        prune(keeping: folder)
        return final
    }

    private struct ResourceBox: @unchecked Sendable {
        let resource: PHAssetResource
        let options: PHAssetResourceRequestOptions
    }

    nonisolated static func sanitized(_ identifier: String) -> String {
        String(identifier.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
    }

    /// Deletes all but the `keptAssets` most recently used asset folders (never `keeping`).
    nonisolated static func prune(keeping: URL) {
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let dated = folders.map { url -> (URL, Date) in
            (url, (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }.sorted { $0.1 > $1.1 }
        for (url, _) in dated.dropFirst(keptAssets) where url.standardizedFileURL != keeping.standardizedFileURL {
            try? fm.removeItem(at: url)
        }
    }
}
