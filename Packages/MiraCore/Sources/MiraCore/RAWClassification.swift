import Foundation

/// Which assets of a collection are RAW, for the ALL / RAW gallery filter. Pure logic; the iOS app feeds it
/// either the library's RAW smart album (authoritative: anything not in it is not RAW) or per-asset
/// resource lookups that arrive chunk by chunk.
public struct RAWClassification: Sendable, Equatable {
    public private(set) var known: [String: Bool]
    /// When true, an id with no recorded answer is not RAW (the RAW smart album listed every RAW asset).
    public let authoritative: Bool

    public init(known: [String: Bool] = [:], authoritative: Bool = false) {
        self.known = known
        self.authoritative = authoritative
    }

    /// A classification built from the RAW smart album's identifiers.
    public init(rawIDs: Set<String>) {
        self.known = Dictionary(uniqueKeysWithValues: rawIDs.map { ($0, true) })
        self.authoritative = true
    }

    public mutating func record(id: String, isRAW: Bool) { known[id] = isRAW }

    /// The answer for an id, or nil while it is still unknown.
    public func isRAW(_ id: String) -> Bool? { known[id] ?? (authoritative ? false : nil) }

    /// Indices (into `ids`) still needing a lookup.
    public func unresolved(in ids: [String], range: Range<Int>? = nil) -> [Int] {
        let r = range ?? ids.indices
        return r.filter { isRAW(ids[$0]) == nil }
    }

    /// Indices (into `ids`, ascending) of the RAW assets, via `LibraryFilter`'s `rawOnly` rule.
    /// Unknown ids do not match.
    public func matchingIndices(in ids: [String], range: Range<Int>? = nil) -> [Int] {
        var filter = LibraryFilter()
        filter.rawOnly = true
        let r = range ?? ids.indices
        return filter.matchingIndices(
            count: r.count,
            facts: { AssetFacts(id: ids[r.lowerBound + $0], isRAW: isRAW(ids[r.lowerBound + $0]) ?? false) },
            meta: { _ in nil }
        ).map { r.lowerBound + $0 }
    }
}
