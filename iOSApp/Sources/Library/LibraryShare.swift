import MiraCore
import Photos
import UIKit
import UniformTypeIdentifiers

/// Loads the current picture of each asset to temp files and hands them to the share sheet.
enum LibraryShare {
    /// Most pictures shared in one go.
    static let cap = 30

    struct Prepared: Sendable {
        var urls: [URL]
        var truncated: Bool
        /// The temporary folder holding `urls`; removed once the share sheet closes (or when nothing is shared).
        var directory: URL
    }

    /// Writes the current image data of up to `cap` assets to temporary files. Runs off the main actor.
    nonisolated static func prepare(ids: [String]) async -> Prepared {
        let chosen = Array(ids.prefix(cap))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mira-share-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        var taken = Set<String>()
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        for (n, id) in chosen.enumerated() {
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject else { continue }
            guard let (data, uti) = await requestData(Unchecked(value: asset)) else { continue }
            let ext = uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
            let name = PHAssetResource.assetResources(for: asset).first?.originalFilename
            let base = name.map { ($0 as NSString).deletingPathExtension } ?? "Mira-\(n + 1)"
            // A picture and its duplicate share an original filename: the second must not overwrite the first.
            var file = "\(base).\(ext)"
            var copy = 2
            while !taken.insert(file.lowercased()).inserted { file = "\(base) \(copy).\(ext)"; copy += 1 }
            let url = directory.appendingPathComponent(file)
            if (try? data.write(to: url)) != nil { urls.append(url) }
        }
        return Prepared(urls: urls, truncated: ids.count > chosen.count, directory: directory)
    }

    private nonisolated static func requestData(_ asset: Unchecked<PHAsset>) async -> (Data, String?)? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat
        options.version = .current
        let boxed = Unchecked(value: options)
        return await withCheckedContinuation { (continuation: CheckedContinuation<(Data, String?)?, Never>) in
            PHImageManager.default().requestImageDataAndOrientation(for: asset.value, options: boxed.value) {
                @Sendable data, uti, _, _ in
                continuation.resume(returning: data.map { ($0, uti) })
            }
        }
    }

    /// Presents the system share sheet from the top view controller; deletes the temp files when it closes.
    @MainActor
    static func present(urls: [URL], directory: URL) {
        guard let top = topViewController() else {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { @Sendable _, _, _, _ in
            try? FileManager.default.removeItem(at: directory)
        }
        controller.popoverPresentationController?.sourceView = top.view
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.maxY - 1, width: 1, height: 1)
        top.present(controller, animated: true)
    }

    @MainActor
    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = top?.presentedViewController { top = next }
        return top
    }
}
