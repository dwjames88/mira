import Foundation
import Photos
import UniformTypeIdentifiers

/// Reads everything the INFO panel shows about one asset: PhotoKit properties, resource names and
/// sizes, and the camera EXIF from the first ~256 KB of the original.
///
/// Geocoding is deliberately not here: `CLGeocoder` is deprecated in the iOS 26 / macOS 26 SDKs, its
/// replacement (MapKit's `MKReverseGeocodingRequest`) is not allowed in MiraCore, and the info must not
/// wait on the network. Apps resolve a place name from `AssetInfo.latitude/longitude` themselves and set
/// `AssetInfo.locationName`; until then the formatter shows coordinates.
public enum AssetInfoReader {
    /// How much of the original is read for EXIF.
    public nonisolated static let exifByteLimit = 256 * 1024

    /// nil when the asset is gone. Never throws; fields that cannot be read stay nil.
    public nonisolated static func read(id: String) async -> AssetInfo? {
        let options = PHFetchOptions()
        options.includeHiddenAssets = true
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: options).firstObject else { return nil }

        var info = AssetInfo(
            creationDate: asset.creationDate, pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight,
            isFavorite: asset.isFavorite, isHidden: asset.isHidden)
        if let location = asset.location {
            info.latitude = location.coordinate.latitude
            info.longitude = location.coordinate.longitude
        }

        let resources = PHAssetResource.assetResources(for: asset)
        let originals = resources.filter { $0.type == .photo || $0.type == .alternatePhoto }
        let primary = resources.first { $0.type == .photo } ?? resources.first { $0.type == .alternatePhoto }
        info.filename = primary?.originalFilename ?? resources.first?.originalFilename ?? ""
        info.formats = formats(of: originals.map(\.uniformTypeIdentifier))
        info.isRAW = RAWDetection.containsRAW(originals.map(\.uniformTypeIdentifier))
        info.fileSize = totalSize(originals)
        let adjustment = resources.first { $0.type == .adjustmentData }
        info.hasAdjustments = adjustment != nil || asset.hasAdjustments
        if let adjustment, asset.hasAdjustments { info.hasMiraEdit = await isMiraEdit(adjustment) }

        if let primary {
            // A RAW original is read for its camera fields as well; the header is up front.
            let exif = await readEXIF(primary, limit: exifByteLimit)
            if let exif {
                info.cameraName = AssetMetadata(id: id, make: exif.make, model: exif.model).cameraName
                info.lens = exif.lens
                info.iso = exif.iso
                info.focalLength = exif.focalLength
                info.fNumber = exif.fNumber
                info.exposureTime = exif.exposureTime
            }
        }
        return info
    }

    /// "RAW" first, then each distinct format ("JPEG", "HEIC", ...).
    public nonisolated static func formats(of typeIdentifiers: [String]) -> [String] {
        var names: [String] = []
        for identifier in typeIdentifiers {
            let name: String
            if RAWDetection.isRAW(typeIdentifier: identifier) {
                name = "RAW"
            } else if let type = UTType(identifier), let ext = type.preferredFilenameExtension {
                name = ext.lowercased() == "jpg" ? "JPEG" : ext.uppercased()
            } else {
                continue
            }
            if !names.contains(name) { names.append(name) }
        }
        return names.sorted { ($0 == "RAW" ? 0 : 1) < ($1 == "RAW" ? 0 : 1) }
    }

    private nonisolated static func totalSize(_ resources: [PHAssetResource]) -> Int64? {
        var total: Int64 = 0
        var found = false
        for resource in resources {
            // `fileSize` is not public API; guard it so a future SDK that drops it yields nil, not a crash.
            let selector = NSSelectorFromString("fileSize")
            guard resource.responds(to: selector), let size = resource.value(forKey: "fileSize") as? Int64 else { continue }
            total += size
            found = true
        }
        return found ? total : nil
    }

    /// The adjustment data (a small property list) names its format identifier; Mira's edits carry ours.
    private nonisolated static func isMiraEdit(_ adjustment: PHAssetResource) async -> Bool {
        let data = await readAll(adjustment, limit: 256 * 1024)
        let identifiers = [MiraAdjustment.formatIdentifier] + MiraAdjustment.legacyFormatIdentifiers
        return identifiers.contains { data.range(of: Data($0.utf8)) != nil }
    }

    private nonisolated static func readAll(_ resource: PHAssetResource, limit: Int) async -> Data {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data, Never>) in
            let collector = Collector(continuation)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            PHAssetResourceManager.default().requestData(
                for: resource, options: options,
                dataReceivedHandler: { @Sendable data in collector.append(data, limit: limit) },
                completionHandler: { @Sendable _ in collector.finish() })
        }
    }

    private nonisolated static func readEXIF(_ resource: PHAssetResource, limit: Int) async -> ParsedEXIF? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ParsedEXIF?, Never>) in
            let manager = PHAssetResourceManager.default()
            let state = ResourceRead(limit: limit, manager: manager, continuation: continuation)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            let requestID = manager.requestData(
                for: resource, options: options,
                dataReceivedHandler: { @Sendable data in state.receive(data) },
                completionHandler: { @Sendable error in state.complete() })
            state.setRequestID(requestID)
        }
    }
}

/// Collects a resource's first bytes and resumes its continuation exactly once.
private final class ResourceRead: @unchecked Sendable {
    private let lock = NSLock()
    private let accumulator: EXIFAccumulator
    private var continuation: CheckedContinuation<ParsedEXIF?, Never>?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelWhenIDKnown = false
    private let manager: PHAssetResourceManager

    nonisolated init(limit: Int, manager: PHAssetResourceManager, continuation: CheckedContinuation<ParsedEXIF?, Never>) {
        self.accumulator = EXIFAccumulator(limit: limit)
        self.manager = manager
        self.continuation = continuation
    }

    nonisolated func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        requestID = id
        let cancelNow = cancelWhenIDKnown
        lock.unlock()
        if cancelNow { manager.cancelDataRequest(id) }
    }

    nonisolated func receive(_ data: Data) {
        lock.lock()
        guard continuation != nil else { lock.unlock(); return }
        let outcome = accumulator.append(data)
        guard case .done(let parsed) = outcome else { lock.unlock(); return }
        let cont = continuation
        continuation = nil
        let id = requestID
        if id == nil { cancelWhenIDKnown = true }
        lock.unlock()
        // Enough has been read: stop the transfer so a big original is not read to the end.
        if let id { manager.cancelDataRequest(id) }
        cont?.resume(returning: parsed)
    }

    nonisolated func complete() {
        lock.lock()
        guard let cont = continuation else { lock.unlock(); return }
        continuation = nil
        let parsed = accumulator.finish()
        lock.unlock()
        cont.resume(returning: parsed)
    }
}

/// Gathers a small resource's bytes and resumes once.
private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var continuation: CheckedContinuation<Data, Never>?

    nonisolated init(_ continuation: CheckedContinuation<Data, Never>) { self.continuation = continuation }

    nonisolated func append(_ chunk: Data, limit: Int) {
        lock.lock()
        if data.count < limit { data.append(chunk) }
        lock.unlock()
    }

    nonisolated func finish() {
        lock.lock()
        let cont = continuation
        continuation = nil
        let result = data
        lock.unlock()
        cont?.resume(returning: result)
    }
}
