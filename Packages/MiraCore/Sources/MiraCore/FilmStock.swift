import Foundation

/// One product line of `films.json`: the film strip shows one card per stock, and the FILMS panel offers
/// its ISOs and variations as chips. Each film still has its own concrete id, which recipes store.
public struct FilmStock: Identifiable, Hashable, Sendable {
    public let id: String
    /// The card title, e.g. "Portra".
    public let name: String
    public let brand: String
    /// The base film's family; every film of a stock shares it.
    public let family: FilmFamily
    /// The flagship film: its thumbnail is the card's, and clicking the card applies it.
    public let baseFilmID: String
    /// All films of the stock in `films.json` order.
    public let films: [Film]

    /// Groups `films` by `Film.stockID`, in order of each stock's first film. A stock without a flagged base
    /// film uses its first film.
    static func group(_ films: [Film]) -> [FilmStock] {
        var order: [String] = []
        var members: [String: [Film]] = [:]
        for f in films {
            if members[f.stockID] == nil { order.append(f.stockID) }
            members[f.stockID, default: []].append(f)
        }
        return order.compactMap { sid in
            guard let list = members[sid], let first = list.first else { return nil }
            let base = list.first(where: \.isStockBase) ?? first
            return FilmStock(id: sid, name: base.stockName ?? base.displayName, brand: base.brand,
                             family: base.family, baseFilmID: base.id, films: list)
        }
    }
}

/// One ISO chip.
public struct FilmISOChoice: Identifiable, Hashable, Sendable {
    public let iso: Int
    public let label: String
    public var id: Int { iso }
}

/// One Variations chip: `variation` is nil for the plain film ("Standard").
public struct FilmVariationChoice: Identifiable, Hashable, Sendable {
    public let variation: String?
    public let filmID: String
    public var id: String { filmID }
    public var label: String { variation ?? "Standard" }
}
