import Foundation
import MiraCore

/// A saved frame whose recipe has not been attached yet.
public struct PendingPrint: Sendable, Equatable, Codable, Identifiable {
    public var id: UUID
    public var assetID: String
    public var recipe: Recipe
    public var rawBase: Bool
    public var createdAt: Date
    public var attempts: Int

    public init(id: UUID = UUID(), assetID: String, recipe: Recipe, rawBase: Bool, createdAt: Date = Date(), attempts: Int = 0) {
        self.id = id
        self.assetID = assetID
        self.recipe = recipe
        self.rawBase = rawBase
        self.createdAt = createdAt
        self.attempts = attempts
    }
}

/// The queue on disk: `pending-prints.json` in an injected directory, written atomically.
public struct PendingPrintStore: Sendable {
    public static let fileName = "pending-prints.json"
    public let directory: URL

    public init(directory: URL) { self.directory = directory }

    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// The stored items, oldest first; empty when the file is missing or unreadable.
    public func load() -> [PendingPrint] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? Self.decoder.decode([PendingPrint].self, from: data)) ?? []
    }

    public func save(_ items: [PendingPrint]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.encoder.encode(items).write(to: fileURL, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Attaches recipes to saved frames, one at a time. Items survive relaunch; only a deleted asset drops one.
public actor PrintQueue {
    private let store: PendingPrintStore
    private let writer: any PrintWriting
    private var items: [PendingPrint]
    private var draining = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private let continuation: AsyncStream<String>.Continuation

    /// Asset identifiers of frames as they are developed (the recipe is attached), for the thumbnail to land.
    /// Single consumer.
    public nonisolated let developed: AsyncStream<String>

    /// Frames still waiting for their recipe.
    public var pendingCount: Int { items.count }
    public var pending: [PendingPrint] { items }

    public init(store: PendingPrintStore, writer: any PrintWriting) {
        self.store = store
        self.writer = writer
        self.items = store.load()
        let (stream, cont) = AsyncStream<String>.makeStream()
        self.developed = stream
        self.continuation = cont
    }

    /// Adds a frame and persists the queue. Call `drain()` to process it.
    @discardableResult
    public func enqueue(assetID: String, recipe: Recipe, rawBase: Bool) throws -> PendingPrint {
        let item = PendingPrint(assetID: assetID, recipe: recipe, rawBase: rawBase)
        items.append(item)
        try persist()
        return item
    }

    /// Announces a frame as developed without going through the queue (the baked-copy path).
    public nonisolated func announceDeveloped(_ assetID: String) { continuation.yield(assetID) }

    /// Processes every pending item serially. A failure keeps the item (attempts + 1) and moves on;
    /// `PrintError.assetMissing` drops it. A call made while a drain is running waits for it.
    public func drain() async {
        if draining {
            await withCheckedContinuation { waiters.append($0) }
            return
        }
        draining = true
        var tried = Set<UUID>()
        while let item = items.first(where: { !tried.contains($0.id) }) {
            tried.insert(item.id)
            do {
                try await writer.attach(recipe: item.recipe, toAsset: item.assetID, rawBase: item.rawBase)
                remove(item.id)
                continuation.yield(item.assetID)
            } catch PrintError.assetMissing {
                remove(item.id)
            } catch {
                if let i = items.firstIndex(where: { $0.id == item.id }) { items[i].attempts += 1 }
            }
            try? persist()
        }
        draining = false
        let w = waiters
        waiters.removeAll()
        for c in w { c.resume() }
    }

    private func remove(_ id: UUID) { items.removeAll { $0.id == id } }
    private func persist() throws { try store.save(items) }
}
