import Foundation

/// Which slot of an asset a PhotoKit resource fills. Mirrors the `PHAssetResourceType` cases that matter for RAW.
public enum RAWResourceRole: Sendable, Equatable {
    /// `.photo`: the original (a RAW-only capture stores its DNG/RAW here).
    case photo
    /// `.alternatePhoto`: the RAW half of a RAW+JPEG pair.
    case alternatePhoto
    /// Edited renders, adjustment data, videos, and so on.
    case other
}

/// The fields of a `PHAssetResource` the classifier reads, so the rule can be tested without PhotoKit.
public protocol RAWResourceDescribing {
    var rawRole: RAWResourceRole { get }
    var rawTypeIdentifier: String { get }
}

public struct RAWResourceFields: RAWResourceDescribing, Sendable, Equatable {
    public let rawRole: RAWResourceRole
    public let rawTypeIdentifier: String
    public init(role: RAWResourceRole, typeIdentifier: String) {
        rawRole = role
        rawTypeIdentifier = typeIdentifier
    }
}

public enum RAWResourceClassifier {
    /// True when an asset's original (`.photo`) or paired alternate (`.alternatePhoto`) resource is a camera RAW type.
    public static func isRAW<S: Sequence>(_ resources: S) -> Bool where S.Element: RAWResourceDescribing {
        resources.contains { ($0.rawRole == .photo || $0.rawRole == .alternatePhoto) && RAWDetection.isRAW(typeIdentifier: $0.rawTypeIdentifier) }
    }
}

/// Persisted per-asset RAW answers keyed by `localIdentifier` and valid only for the stored `modificationDate`.
/// Bounded: past `capacity` the least recently used entries are dropped.
public struct RAWResultCache: Codable, Sendable, Equatable {
    public struct Entry: Codable, Sendable, Equatable {
        public var isRAW: Bool
        /// `modificationDate.timeIntervalSinceReferenceDate`; nil when the asset reports none.
        public var modified: Double?
        public var stamp: Int
    }

    public static let defaultCapacity = 40_000
    public private(set) var entries: [String: Entry]
    public private(set) var clock: Int
    public let capacity: Int

    public init(capacity: Int = RAWResultCache.defaultCapacity) {
        self.entries = [:]
        self.clock = 0
        self.capacity = max(1, capacity)
    }

    public var count: Int { entries.count }

    private static func stamp(_ date: Date?) -> Double? { date?.timeIntervalSinceReferenceDate }

    /// The cached answer, or nil when absent or recorded for a different modification date.
    public func lookup(id: String, modificationDate: Date?) -> Bool? {
        guard let e = entries[id], e.modified == Self.stamp(modificationDate) else { return nil }
        return e.isRAW
    }

    public mutating func record(id: String, modificationDate: Date?, isRAW: Bool) {
        clock += 1
        entries[id] = Entry(isRAW: isRAW, modified: Self.stamp(modificationDate), stamp: clock)
        if entries.count > capacity { trim() }
    }

    public mutating func invalidate(ids: some Sequence<String>) {
        for id in ids { entries[id] = nil }
    }

    public mutating func removeAll() { entries.removeAll(); clock = 0 }

    /// Drops the oldest tenth beyond the cap so trimming is not paid on every insert.
    private mutating func trim() {
        let keep = capacity - capacity / 10
        let drop = entries.count - keep
        guard drop > 0 else { return }
        for (id, _) in entries.sorted(by: { $0.value.stamp < $1.value.stamp }).prefix(drop) { entries[id] = nil }
    }

    public static func load(from url: URL, capacity: Int = defaultCapacity) -> RAWResultCache {
        guard let data = try? Data(contentsOf: url),
              var cache = try? JSONDecoder().decode(RAWResultCache.self, from: data) else { return RAWResultCache(capacity: capacity) }
        if cache.entries.count > capacity { cache = RAWResultCache(capacity: capacity) }
        return cache
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

public enum RAWScanBatching {
    /// Consecutive index ranges of at most `size` covering `0..<count`.
    public static func ranges(count: Int, size: Int) -> [Range<Int>] {
        guard count > 0, size > 0 else { return [] }
        return stride(from: 0, to: count, by: size).map { $0..<min(count, $0 + size) }
    }

    /// Splits `items` into at most `lanes` interleaved-free contiguous slices for a modest task group.
    public static func slices<T>(_ items: [T], lanes: Int) -> [[T]] {
        guard !items.isEmpty, lanes > 0 else { return [] }
        let per = (items.count + lanes - 1) / lanes
        return stride(from: 0, to: items.count, by: per).map { Array(items[$0..<min(items.count, $0 + per)]) }
    }
}
