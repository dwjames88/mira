import MiraCore
import Photos
import SwiftUI
import UIKit

/// PhotoKit types are not Sendable; this box carries them across the few hops that need it.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value
}

/// Every closure handed to PhotoKit is built in a `nonisolated` context and marked `@Sendable`
/// (Photos calls back on its own queues; a main-actor-inherited closure would trap in Swift 6).
enum GalleryKit {
    nonisolated static func requestThumbnail(
        manager: PHImageManager, asset: Unchecked<PHAsset>, size: CGSize, options: Unchecked<PHImageRequestOptions>,
        deliver: @escaping @Sendable (Unchecked<UIImage?>) -> Void
    ) -> PHImageRequestID {
        manager.requestImage(for: asset.value, targetSize: size, contentMode: .aspectFill, options: options.value) {
            @Sendable image, _ in
            let box = Unchecked(value: image)
            DispatchQueue.main.async { deliver(box) }
        }
    }

    nonisolated static func requestFullData(asset: Unchecked<PHAsset>) async -> Data? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        let boxed = Unchecked(value: options)
        return await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset.value, options: boxed.value) {
                @Sendable data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    /// (isRAW, isEdited) from the asset's resources; runs off the main actor.
    nonisolated static func badges(of asset: Unchecked<PHAsset>) -> (raw: Bool, edited: Bool) {
        let resources = PHAssetResource.assetResources(for: asset.value)
        let rawTypes: Set<String> = ["public.camera-raw-image", "com.adobe.raw-image"]
        let raw = resources.contains {
            ($0.type == .photo || $0.type == .alternatePhoto) && rawTypes.contains($0.uniformTypeIdentifier)
        }
        let edited = resources.contains { $0.type == .adjustmentData }
        return (raw, edited)
    }
}

/// Root gallery state: authorization, the album tree (shared `SidebarLoader` + MiraCore `SidebarModel`),
/// and the change signal that tells open grids to refetch.
@MainActor @Observable
final class GalleryModel: NSObject, PHPhotoLibraryChangeObserver {
    private(set) var status: PHAuthorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    private(set) var sections: [SidebarSection] = []
    private(set) var loadedSections = false
    /// Bumps whenever the library changes; grids refetch on it.
    private(set) var revision = 0
    private(set) var isOpening = false

    @ObservationIgnored private var observing = false

    var hasAccess: Bool { status == .authorized || status == .limited }

    /// Picture count of the whole library ("all" node), once sections are loaded.
    var libraryCount: Int? { SidebarModel.node(withID: "all", in: sections)?.count }

    func start() async {
        if !observing { PHPhotoLibrary.shared().register(self); observing = true }
        if status == .notDetermined {
            status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        if hasAccess { await reloadSections() }
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    /// `SidebarLoader` is `nonisolated`; run it off the main actor and hop back with Sendable values.
    func reloadSections() async {
        let loaded = await Task.detached(priority: .userInitiated) { SidebarLoader.load() }.value
        sections = loaded
        loadedSections = true
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
                if self.hasAccess {
                    self.revision += 1
                    Task { await self.reloadSections() }
                } else {
                    self.sections = []
                }
            }
        }
    }

    /// Fetches the full-resolution data for an asset and hands it to the editor.
    func open(_ asset: PHAsset, in editor: EditorViewModel) async {
        guard !isOpening else { return }
        isOpening = true
        defer { isOpening = false }
        let data = await GalleryKit.requestFullData(asset: Unchecked(value: asset))
        guard let data else { editor.fail("THAT PHOTO COULD NOT BE LOADED"); return }
        await editor.openData(data)
    }

    func presentLimitedPicker() {
        guard let top = Self.topViewController() else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: top)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }

    static func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}

/// One album's pictures: the fetch result for a sidebar node plus the thumbnail caching window.
@MainActor @Observable
final class AlbumModel {
    let nodeID: String
    private(set) var result: PHFetchResult<PHAsset>?
    private(set) var count = 0
    private(set) var loaded = false

    @ObservationIgnored let caching = PHCachingImageManager()
    @ObservationIgnored let thumbOptions: PHImageRequestOptions = {
        let o = PHImageRequestOptions()
        o.deliveryMode = .opportunistic
        o.resizeMode = .fast
        o.isNetworkAccessAllowed = true
        return o
    }()
    @ObservationIgnored private var cachedRange: Range<Int> = 0..<0
    @ObservationIgnored private(set) var thumbSize: CGSize = .zero

    init(nodeID: String) { self.nodeID = nodeID }

    func reload() async {
        let id = nodeID
        let box = await Task.detached(priority: .userInitiated) {
            Unchecked(value: SidebarLoader.fetchAssets(nodeID: id))
        }.value
        result = box.value
        count = box.value.count
        loaded = true
        caching.stopCachingImagesForAllAssets()
        cachedRange = 0..<0
    }

    func stopCaching() {
        caching.stopCachingImagesForAllAssets()
        cachedRange = 0..<0
    }

    func asset(at index: Int) -> PHAsset? {
        guard let result, index >= 0, index < result.count else { return nil }
        return result.object(at: index)
    }

    func setThumbSize(_ size: CGSize) { thumbSize = size }

    /// Keeps a window of ±36 around the visible index warm in the caching manager.
    func updateCaching(around index: Int) {
        guard let result, thumbSize != .zero else { return }
        let window = max(0, index - 36)..<min(result.count, index + 36)
        guard window != cachedRange else { return }
        let old = Set(cachedRange), new = Set(window)
        let add = new.subtracting(old).sorted(), drop = old.subtracting(new).sorted()
        if !add.isEmpty {
            caching.startCachingImages(for: add.map { result.object(at: $0) }, targetSize: thumbSize,
                                       contentMode: .aspectFill, options: thumbOptions)
        }
        if !drop.isEmpty {
            caching.stopCachingImages(for: drop.filter { $0 < result.count }.map { result.object(at: $0) },
                                      targetSize: thumbSize, contentMode: .aspectFill, options: thumbOptions)
        }
        cachedRange = window
    }
}
