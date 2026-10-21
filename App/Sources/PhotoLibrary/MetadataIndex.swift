import Foundation
import MiraCore
import Photos

/// Cancellation flag shared between the store (main actor) and an index run (background).
final class IndexCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}

/// One EXIF read in flight. PhotoKit calls `receive` for each chunk of the resource and `complete` at
/// the end, on its own queue; the first of "camera found", "byte limit reached" or "stream ended"
/// resumes the continuation, and a found/limit result also cancels the rest of the transfer.
private final class ResourceRead: @unchecked Sendable {
    struct Result: Sendable {
        var exif: ParsedEXIF?
        /// No bytes arrived because the original is not on this Mac.
        var unavailable: Bool
    }

    private let lock = NSLock()
    private let accumulator: EXIFAccumulator
    private var continuation: CheckedContinuation<Result, Never>?
    private var requestID: PHAssetResourceDataRequestID?
    private var cancelWhenIDKnown = false
    private let manager: Unchecked<PHAssetResourceManager>

    nonisolated init(limit: Int, manager: Unchecked<PHAssetResourceManager>, continuation: CheckedContinuation<Result, Never>) {
        self.accumulator = EXIFAccumulator(limit: limit)
        self.manager = manager
        self.continuation = continuation
    }

    nonisolated func setRequestID(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        requestID = id
        let cancelNow = cancelWhenIDKnown
        lock.unlock()
        if cancelNow { manager.value.cancelDataRequest(id) }
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
        // Enough has been read: stop the transfer so a RAW file is not read to the end.
        if let id { manager.value.cancelDataRequest(id) }
        cont?.resume(returning: Result(exif: parsed, unavailable: false))
    }

    nonisolated func complete(error: Error?) {
        lock.lock()
        guard let cont = continuation else { lock.unlock(); return }
        continuation = nil
        let received = accumulator.received
        let parsed = accumulator.finish()
        lock.unlock()
        cont.resume(returning: Result(exif: parsed, unavailable: error != nil && received == 0))
    }
}

/// Reads the per-asset metadata that the filter and search use. Everything here is `nonisolated` and every
/// closure given to PhotoKit is built in that context.
enum MetadataReader {
    /// Largest prefix read from an ordinary photo, and from a RAW file whose header holds no camera tags early.
    nonisolated static let photoByteLimit = 256 * 1024
    nonisolated static let rawByteLimit = 768 * 1024

    nonisolated static func read(_ box: Unchecked<PHAsset>) async -> AssetMetadata {
        let asset = box.value
        var meta = AssetMetadata(
            id: asset.localIdentifier, modificationDate: asset.modificationDate, creationDate: asset.creationDate,
            pixelWidth: asset.pixelWidth, pixelHeight: asset.pixelHeight)
        let resources = PHAssetResource.assetResources(for: asset)
        let photoTypes = resources.filter { $0.type == .photo || $0.type == .alternatePhoto }
        meta.isRAW = RAWDetection.containsRAW(photoTypes.map(\.uniformTypeIdentifier))
        // The original photo (not the edited render): .photo, which for a RAW+JPEG pair is the JPEG.
        guard let primary = resources.first(where: { $0.type == .photo }) ?? photoTypes.first else {
            meta.unavailable = true
            return meta
        }
        meta.filename = primary.originalFilename
        let isRAWPrimary = RAWDetection.isRAW(typeIdentifier: primary.uniformTypeIdentifier)
        let result = await readEXIF(Unchecked(value: primary), limit: isRAWPrimary ? rawByteLimit : photoByteLimit)
        if let exif = result.exif { meta.apply(exif) }
        meta.unavailable = result.unavailable
        return meta
    }

    nonisolated private static func readEXIF(_ resource: Unchecked<PHAssetResource>, limit: Int) async -> ResourceRead.Result {
        await withCheckedContinuation { continuation in
            let manager = Unchecked(value: PHAssetResourceManager.default())
            let state = ResourceRead(limit: limit, manager: manager, continuation: continuation)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = false
            let id = manager.value.requestData(
                for: resource.value, options: options,
                dataReceivedHandler: { @Sendable data in state.receive(data) },
                completionHandler: { @Sendable error in state.complete(error: error) })
            state.setRequestID(id)
        }
    }
}

/// Walks fetch results and fills the metadata store: the current collection first, then the rest of the library.
enum MetadataIndexer {
    /// Concurrent EXIF reads. Each is a few tens of KB of I/O; more only adds contention with thumbnails.
    nonisolated static let concurrency = 3
    nonisolated static let batchSize = 50
    nonisolated static let reportInterval: Duration = .milliseconds(250)

    /// - Parameters: `collection` is indexed first; `library` (nil when the collection is the whole library) after it.
    ///   `report` is called at most about four times a second, plus once per phase end.
    nonisolated static func run(
        collection: Unchecked<PHFetchResult<PHAsset>>, library: Unchecked<PHFetchResult<PHAsset>>?,
        store: MetadataStore, flag: IndexCancelFlag, report: @escaping @Sendable (IndexProgress) -> Void
    ) async {
        await pass(collection, scope: .collection, store: store, flag: flag, report: report)
        guard !flag.isCancelled, let library else { return }
        await pass(library, scope: .library, store: store, flag: flag, report: report)
    }

    nonisolated private static func pass(
        _ fetch: Unchecked<PHFetchResult<PHAsset>>, scope: IndexProgress.Scope,
        store: MetadataStore, flag: IndexCancelFlag, report: @escaping @Sendable (IndexProgress) -> Void
    ) async {
        let result = fetch.value
        let total = result.count
        var indexed = 0
        var buffer: [AssetMetadata] = []
        let clock = ContinuousClock()
        var lastReport = clock.now - reportInterval
        func publish(force: Bool = false, finished: Bool = false) {
            let now = clock.now
            guard force || finished || now - lastReport >= reportInterval else { return }
            lastReport = now
            report(IndexProgress(indexed: indexed, total: total, scope: scope, finished: finished))
        }
        publish(force: true)

        await withTaskGroup(of: AssetMetadata.self) { group in
            var inFlight = 0
            func absorb(_ meta: AssetMetadata) {
                inFlight -= 1
                indexed += 1
                buffer.append(meta)
                if buffer.count >= batchSize { store.put(buffer); buffer.removeAll(keepingCapacity: true) }
                publish()
            }
            var start = 0
            scan: while start < total {
                if flag.isCancelled || Task.isCancelled { break }
                let end = min(start + 256, total)
                let assets = result.objects(at: IndexSet(integersIn: start..<end))
                start = end
                for asset in assets {
                    if !store.needsIndex(id: asset.localIdentifier, modificationDate: asset.modificationDate) {
                        indexed += 1
                        continue
                    }
                    if inFlight >= concurrency, let meta = await group.next() { absorb(meta) }
                    if flag.isCancelled || Task.isCancelled { break scan }
                    let box = Unchecked(value: asset)
                    group.addTask { await MetadataReader.read(box) }
                    inFlight += 1
                }
                publish()
            }
            while let meta = await group.next() { absorb(meta) }
        }
        if !buffer.isEmpty { store.put(buffer) }
        publish(force: true, finished: !(flag.isCancelled || Task.isCancelled))
    }
}
