import AppKit
import MiraCore
import Foundation
import Photos

/// Every closure handed to PhotoKit is built here, in a `nonisolated` context, and marked `@Sendable`.
/// Photos invokes its callbacks on its own queues; a closure written inside `@MainActor` code would
/// inherit main-actor isolation and trap in Swift 6's runtime executor check. Callers hop to the main
/// actor explicitly with the values these helpers hand back.
enum PhotoKitBridge {
    /// Lock-protected slot for a value produced inside a change block.
    final class Slot<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value?
        func set(_ value: Value) { lock.lock(); stored = value; lock.unlock() }
        var value: Value? { lock.lock(); defer { lock.unlock() }; return stored }
    }

    nonisolated static func makeOptions(progress: (@Sendable (Double) -> Void)?) -> PHContentEditingInputRequestOptions {
        let options = PHContentEditingInputRequestOptions()
        options.canHandleAdjustmentData = { @Sendable data in MiraAdjustment.canHandle(data) }
        options.isNetworkAccessAllowed = true
        if let progress {
            options.progressHandler = { @Sendable value, _ in progress(value) }
        }
        return options
    }

    nonisolated static func requestEditingInput(
        asset: Unchecked<PHAsset>, progress: (@Sendable (Double) -> Void)?
    ) async -> Unchecked<PHContentEditingInput>? {
        let options = Unchecked(value: makeOptions(progress: progress))
        return await withCheckedContinuation { continuation in
            asset.value.requestContentEditingInput(with: options.value) { @Sendable input, _ in
                continuation.resume(returning: input.map(Unchecked.init))
            }
        }
    }

    nonisolated static func saveEdit(asset: Unchecked<PHAsset>, output: Unchecked<PHContentEditingOutput>) async throws {
        try await performLibraryChanges { @Sendable in
            let request = PHAssetChangeRequest(for: asset.value)
            request.contentEditingOutput = output.value
        }
    }

    nonisolated static func revert(asset: Unchecked<PHAsset>) async throws {
        try await performLibraryChanges { @Sendable in
            PHAssetChangeRequest(for: asset.value).revertAssetContentToOriginal()
        }
    }

    /// Imports `url` as a new photo, adds it to the album named `albumTitle` (creating it), and
    /// returns the new asset's local identifier.
    nonisolated static func importPhoto(url: URL, filename: String, albumTitle: String) async throws -> String? {
        let slot = Slot<String>()
        try await performLibraryChanges { @Sendable in
            let creation = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = filename
            creation.addResource(with: .photo, fileURL: url, options: options)
            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            slot.set(placeholder.localIdentifier)
            let fetch = PHFetchOptions()
            fetch.predicate = NSPredicate(format: "title = %@", albumTitle)
            let existing = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: fetch).firstObject
            let albumRequest = existing.map { PHAssetCollectionChangeRequest(for: $0) }
                ?? PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
            albumRequest?.addAssets([placeholder] as NSArray)
        }
        return slot.value
    }

    /// Requests an image; `deliver` runs on the main queue, in order (degraded, then final).
    nonisolated static func requestImage(
        manager: PHImageManager, asset: PHAsset, size: CGSize, options: PHImageRequestOptions,
        deliver: @escaping @MainActor (NSImage?) -> Void
    ) -> PHImageRequestID {
        manager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { @Sendable image, _ in
            let box = Unchecked(value: image)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { deliver(box.value) }
            }
        }
    }

    /// Detects a RAW resource off the main actor.
    nonisolated static func resourceTypeIdentifiers(of asset: Unchecked<PHAsset>) -> [String] {
        PHAssetResource.assetResources(for: asset.value)
            .filter { $0.type == .photo || $0.type == .alternatePhoto }
            .map(\.uniformTypeIdentifier)
    }
}

nonisolated func performLibraryChanges(_ body: @escaping @Sendable () -> Void) async throws {
    try await PHPhotoLibrary.shared().performChanges(body)
}
