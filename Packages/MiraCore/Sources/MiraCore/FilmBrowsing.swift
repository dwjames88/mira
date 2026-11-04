import Foundation

/// Pure logic behind the film picker's family tabs and the push / pull chips, shared by the iOS app
/// and testable under `swift test`.
public enum FilmBrowsing {
    /// The families that have at least one stock, in `FilmFamily.displayOrder`; the picker's tabs.
    public static func families(in library: FilmLibrary) -> [FilmFamily] {
        let present = Set(library.stocks.map(\.family))
        return FilmFamily.displayOrder.filter { present.contains($0) }
    }

    /// The stock cards a family tab shows (all stocks for nil); never variants.
    public static func stocks(in library: FilmLibrary, family: FilmFamily?) -> [Film] {
        let stocks = library.stocks
        guard let family else { return stocks }
        return stocks.filter { $0.family == family }
    }

    /// Push / pull choices, −2 ... +2 in thirds of a stop.
    public static let pushSteps: [Double] = (-6...6).map { Double($0) / 3 }

    /// "0", "+⅓", "+1⅓", "−2" with a real minus sign.
    public static func pushLabel(_ stops: Double) -> String {
        let thirds = Int((stops * 3).rounded())
        if thirds == 0 { return "0" }
        let sign = thirds < 0 ? "\u{2212}" : "+"
        let whole = abs(thirds) / 3
        let fraction = ["", "\u{2153}", "\u{2154}"][abs(thirds) % 3]
        if whole == 0 { return sign + fraction }
        return sign + String(whole) + fraction
    }

    /// Toning applies to monochrome films only.
    public static func offersToning(_ film: Film?) -> Bool { film?.isMonochrome ?? false }
}
