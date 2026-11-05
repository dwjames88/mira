#if os(macOS)
import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

/// Every bundled film, grouped by family: the film list inside the About window.
public struct FilmsList: View {
    private let library: FilmLibrary

    public init(library: FilmLibrary) {
        self.library = library
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("\(library.filmStocks.count) stocks \u{00B7} \(library.films.count) looks \u{00B7} \(familyCount) families")
                .ffLabel(color: T.paperDim)
                .frame(height: T.rows(1))
            ForEach(FilmFamily.displayOrder, id: \.self) { family in
                let stocks = library.filmStocks.filter { $0.family == family }
                if !stocks.isEmpty {
                    FFSectionLabel(family.displayName, trailing: String(format: "%03d", stocks.count))
                        .padding(.top, T.rows(2))
                    ForEach(stocks) { stock in
                        FilmRow(stock: stock, isos: library.isoChoices(stockID: stock.id).map(\.label),
                                description: library.film(id: stock.baseFilmID)?.description ?? "")
                        FFHairline()
                    }
                }
            }
        }
    }

    private var familyCount: Int {
        FilmFamily.displayOrder.filter { family in library.filmStocks.contains { $0.family == family } }.count
    }
}

private struct FilmRow: View {
    let stock: FilmStock
    /// The stock's ISO chip labels, ascending.
    var isos: [String] = []
    var description = ""

    /// Looks beyond one per ISO: push / pull steps, scans and the like.
    private var variationCount: Int { stock.films.count - isos.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(stock.name)
                    .font(T.display(21, weight: .medium))
                    .foregroundStyle(T.paper)
                Spacer(minLength: T.cells(2))
                Text(stock.brand)
                    .ffLabel()
            }
            if isos.count > 1 || variationCount > 0 {
                let iso = isos.count > 1 ? "ISO " + isos.joined(separator: " \u{00B7} ") : (isos.first.map { "ISO \($0)" } ?? "")
                let variations = variationCount > 0 ? "\(variationCount) variation\(variationCount == 1 ? "" : "s")" : ""
                Text([iso, variations].filter { !$0.isEmpty }.joined(separator: " \u{00B7} "))
                    .ffLabel(color: T.lichen)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let only = isos.first, only != "0" {
                Text("ISO \(only)").ffLabel(color: T.lichen)
            }
            if !description.isEmpty {
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(T.paperMid)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, T.rows(1) / 2)
        .accessibilityElement(children: .combine)
    }
}

/// The license credit for the bundled film looks.
public struct AttributionFooter: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: T.rows(1) / 2 + 2) {
            Text("Film looks are from the RawTherapee Film Simulation Collection by Pat David (with Pavlov Dmitry and Michael Ezra), licensed under CC BY-SA 4.0. Film stock names are used for information only; Mira is not affiliated with any film maker.")
                .font(.system(size: 11))
                .lineSpacing(2)
                .foregroundStyle(T.paperDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: T.cells(3)) {
                if let url = URL(string: "https://rawpedia.rawtherapee.com/Film_Simulation") {
                    Link("RawPedia: Film Simulation", destination: url)
                }
                if let url = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/") {
                    Link("CC BY-SA 4.0", destination: url)
                }
            }
            .ffLabel(color: T.lichen)
            Text("Cormorant Garamond and IBM Plex Mono, SIL Open Font License.")
                .font(.system(size: 11))
                .foregroundStyle(T.paperDim)
        }
    }
}

#endif
