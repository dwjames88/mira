import Foundation

/// The per-asset values PhotoKit supplies for filtering (everything the metadata index does not hold).
public struct AssetFacts: Sendable {
    public var id: String
    public var creationDate: Date?
    public var isRAW: Bool
    public var isEdited: Bool
    public var isFavorite: Bool

    public init(id: String, creationDate: Date? = nil, isRAW: Bool = false, isEdited: Bool = false, isFavorite: Bool = false) {
        self.id = id
        self.creationDate = creationDate
        self.isRAW = isRAW
        self.isEdited = isEdited
        self.isFavorite = isFavorite
    }
}

public struct FacetCount: Hashable, Sendable {
    public var name: String
    public var count: Int
    public init(name: String, count: Int) {
        self.name = name
        self.count = count
    }
}

public struct FilterFacets: Equatable, Sendable {
    public var cameras: [FacetCount] = []
    public var lenses: [FacetCount] = []
    public init(cameras: [FacetCount] = [], lenses: [FacetCount] = []) {
        self.cameras = cameras
        self.lenses = lenses
    }
}

/// The library grid's filter criteria and the pure logic that applies them.
///
/// Favorites and the source scope are also expressible as a PhotoKit predicate / fetch option, so the app
/// puts them into `PHFetchOptions`; `matches` still checks favorites so the struct is complete on its own.
public struct LibraryFilter: Equatable, Sendable {
    public enum Scope: String, Sendable, CaseIterable {
        /// Only the user's own library: no iCloud Shared Library, no shared albums.
        case myLibrary
        case all
    }

    public var scope: Scope = .all
    public var rawOnly = false
    public var editedOnly = false
    public var favoritesOnly = false
    /// Selected camera names ("Make Model").
    public var cameras: Set<String> = []
    public var lenses: Set<String> = []
    public var search = ""

    public init() {}

    /// Number of active criteria, for the badge on the FILTER button.
    public var activeCount: Int {
        var n = 0
        if scope != .all { n += 1 }
        if rawOnly { n += 1 }
        if editedOnly { n += 1 }
        if favoritesOnly { n += 1 }
        if !cameras.isEmpty { n += 1 }
        if !lenses.isEmpty { n += 1 }
        if !searchTerms.isEmpty { n += 1 }
        return n
    }

    public var isActive: Bool { activeCount > 0 }

    /// Criteria PhotoKit evaluates in the fetch itself; changing them means a refetch.
    public var fetchCriteria: [Bool] { [scope != .all, favoritesOnly] }

    /// Something has to be checked per asset after the fetch (RAW, edited, camera, lens, search).
    public var needsAssetPass: Bool {
        rawOnly || editedOnly || !cameras.isEmpty || !lenses.isEmpty || !searchTerms.isEmpty
    }

    /// Some criterion can only be answered from indexed metadata.
    public var needsMetadata: Bool { !cameras.isEmpty || !lenses.isEmpty || !searchTerms.isEmpty }

    /// Lower-cased whitespace-separated search words; all must match.
    public var searchTerms: [String] {
        search.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
    }

    public func matches(_ meta: AssetMetadata?, facts: AssetFacts) -> Bool {
        matches(meta, facts: facts, terms: searchTerms)
    }

    func matches(_ meta: AssetMetadata?, facts: AssetFacts, terms: [String]) -> Bool {
        if favoritesOnly, !facts.isFavorite { return false }
        if rawOnly, !facts.isRAW { return false }
        if editedOnly, !facts.isEdited { return false }
        if !cameras.isEmpty {
            guard let name = meta?.cameraName, cameras.contains(name) else { return false }
        }
        if !lenses.isEmpty {
            guard let lens = meta?.lens, lenses.contains(lens) else { return false }
        }
        if !terms.isEmpty {
            // Unindexed assets can still match on their date.
            var haystack = ""
            if let meta {
                haystack = [meta.filename, meta.cameraName ?? "", meta.lens ?? ""].joined(separator: "\n").lowercased()
            }
            var dateText: String?
            for term in terms {
                if haystack.contains(term) { continue }
                if dateText == nil { dateText = Self.dateText(facts.creationDate ?? meta?.creationDate) }
                if !(dateText?.contains(term) ?? false) { return false }
            }
        }
        return true
    }

    /// Indices of the assets that match, in input order. `count` assets; `facts(i)` and `meta(i)` describe asset i.
    public func matchingIndices(count: Int, facts: (Int) -> AssetFacts, meta: (Int) -> AssetMetadata?) -> [Int] {
        let terms = searchTerms
        var result: [Int] = []
        result.reserveCapacity(count)
        for i in 0..<count where matches(meta(i), facts: facts(i), terms: terms) {
            result.append(i)
        }
        return result
    }

    // MARK: Facets

    /// Camera and lens counts, most photos first (ties by name). Assets without the field are not counted.
    public static func facets(of metas: some Sequence<AssetMetadata?>) -> FilterFacets {
        var cameras: [String: Int] = [:]
        var lenses: [String: Int] = [:]
        for case let meta? in metas {
            if let name = meta.cameraName { cameras[name, default: 0] += 1 }
            if let lens = meta.lens { lenses[lens, default: 0] += 1 }
        }
        func sorted(_ d: [String: Int]) -> [FacetCount] {
            d.map { FacetCount(name: $0.key, count: $0.value) }
                .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        return FilterFacets(cameras: sorted(cameras), lenses: sorted(lenses))
    }

    // MARK: Date text

    private static let monthNames = ["january", "february", "march", "april", "may", "june", "july",
                                     "august", "september", "october", "november", "december"]
    private static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c
    }()

    /// Lower-case text a search term is matched against: "2025 2025-07 2025-07-15 july 2025 jul 2025 15 july 2025 ..."
    public static func dateText(_ date: Date?) -> String {
        guard let date else { return "" }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard let y = parts.year, let m = parts.month, let d = parts.day, (1...12).contains(m) else { return "" }
        let month = monthNames[m - 1]
        let short = String(month.prefix(3))
        let mm = m < 10 ? "0\(m)" : "\(m)"
        let dd = d < 10 ? "0\(d)" : "\(d)"
        return "\(y) \(y)-\(mm) \(y)-\(mm)-\(dd) \(month) \(y) \(short) \(y) \(d) \(month) \(y) \(d) \(short) \(y) \(month) \(d) \(y) \(short) \(d) \(y)"
    }

    /// True when the (possibly multi-word) query matches the date: "2025", "July 2025", "Jul 2025", "2025-07".
    public static func dateMatches(_ query: String, _ date: Date?) -> Bool {
        let text = dateText(date)
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace)
        return !terms.isEmpty && terms.allSatisfy { text.contains($0) }
    }
}
