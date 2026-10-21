import Foundation

/// Thread-safe, persistent map from a photo's local identifier to its `AssetMetadata`.
///
/// Storage is JSON lines, one entry per line, appended in batches; a later line for the same id wins when
/// the file is loaded, and the file is compacted (rewritten atomically) when it has accumulated many
/// superseded lines. A truncated or corrupt line is skipped, so a crash mid-write loses at most that line.
public final class MetadataStore: @unchecked Sendable {
    public static let formatVersion = 1
    private let lock = NSLock()
    private var entries: [String: AssetMetadata] = [:]
    private var touched: Set<String> = []
    private let fileURL: URL?
    private var lineCount = 0

    /// `fileURL` nil keeps the store in memory only (tests, previews).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
    }

    /// Application Support/Mira/MetadataIndex/index-v1.jsonl
    public static func defaultFileURL() -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return base.appendingPathComponent("Mira/MetadataIndex/index-v\(formatVersion).jsonl")
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return entries.count }

    public func metadata(for id: String) -> AssetMetadata? {
        lock.lock(); defer { lock.unlock() }
        return entries[id]
    }

    /// Many lookups under one lock acquisition.
    public func metadata(forIDs ids: [String]) -> [AssetMetadata?] {
        lock.lock(); defer { lock.unlock() }
        return ids.map { entries[$0] }
    }

    /// True when the asset has no entry, its modification date changed, or its entry is `unavailable` and
    /// has not been retried in this session.
    public func needsIndex(id: String, modificationDate: Date?) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[id] else { return true }
        if !Self.sameDate(entry.modificationDate, modificationDate) { return true }
        return entry.unavailable && !touched.contains(id)
    }

    /// Stores the entries and appends them to the file.
    public func put(_ batch: [AssetMetadata]) {
        guard !batch.isEmpty else { return }
        lock.lock()
        for entry in batch {
            entries[entry.id] = entry
            touched.insert(entry.id)
        }
        lineCount += batch.count
        lock.unlock()
        append(batch)
    }

    /// Drops every entry (and the file).
    public func removeAll() {
        lock.lock()
        entries = [:]
        touched = []
        lineCount = 0
        lock.unlock()
        if let fileURL { try? FileManager.default.removeItem(at: fileURL) }
    }

    // MARK: Persistence

    /// Reads the file; returns the number of entries loaded. Skips corrupt lines and compacts when worthwhile.
    @discardableResult
    public func load() -> Int {
        guard let fileURL, let data = try? Data(contentsOf: fileURL) else { return 0 }
        let decoder = Self.decoder()
        var loaded: [String: AssetMetadata] = [:]
        var lines = 0
        for slice in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            lines += 1
            if let entry = try? decoder.decode(AssetMetadata.self, from: Data(slice)) { loaded[entry.id] = entry }
        }
        lock.lock()
        entries = loaded
        lineCount = lines
        lock.unlock()
        if lines > loaded.count + max(1000, loaded.count / 2) { compact() }
        return loaded.count
    }

    /// Rewrites the file with one line per entry.
    public func compact() {
        guard let fileURL else { return }
        lock.lock()
        let snapshot = Array(entries.values)
        lock.unlock()
        let encoder = Self.encoder()
        var out = Data()
        for entry in snapshot {
            if let line = try? encoder.encode(entry) { out.append(line); out.append(10) }
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try out.write(to: fileURL, options: .atomic)
            lock.lock(); lineCount = snapshot.count; lock.unlock()
        } catch {}
    }

    private func append(_ batch: [AssetMetadata]) {
        guard let fileURL else { return }
        let encoder = Self.encoder()
        var out = Data()
        for entry in batch {
            if let line = try? encoder.encode(entry) { out.append(line); out.append(10) }
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: fileURL.path) { fm.createFile(atPath: fileURL.path, contents: nil) }
            let handle = try FileHandle(forUpdating: fileURL)
            defer { try? handle.close() }
            // A crash can leave a half line; start on a fresh line so the next entry is not glued to it.
            let end = try handle.seekToEnd()
            if end > 0 {
                try handle.seek(toOffset: end - 1)
                if let last = try handle.read(upToCount: 1), last.first != 10 { try handle.seekToEnd(); try handle.write(contentsOf: Data([10])) }
                else { try handle.seekToEnd() }
            }
            try handle.write(contentsOf: out)
        } catch {}
    }

    static func sameDate(_ a: Date?, _ b: Date?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a.timeIntervalSince1970 - b.timeIntervalSince1970) < 0.001
        default: false
        }
    }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}

/// How far the index has got, for the "INDEXING n / m" line.
public struct IndexProgress: Equatable, Sendable {
    public enum Scope: Sendable { case collection, library }
    public var indexed: Int
    public var total: Int
    public var scope: Scope
    public var finished: Bool

    public init(indexed: Int = 0, total: Int = 0, scope: Scope = .collection, finished: Bool = true) {
        self.indexed = indexed
        self.total = total
        self.scope = scope
        self.finished = finished
    }

    /// "INDEXING 1200 / 48000", or nil when idle.
    public var line: String? { finished ? nil : "INDEXING \(indexed) / \(total)" }
}
