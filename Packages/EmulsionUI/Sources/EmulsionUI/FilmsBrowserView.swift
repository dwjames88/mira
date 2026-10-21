import EmulsionCore
import SwiftUI

/// Every bundled film, grouped by family, with the licence credit.
public struct FilmsBrowserView: View {
    private let library: FilmLibrary

    public init(library: FilmLibrary) {
        self.library = library
    }

    public var body: some View {
        List {
            ForEach(FilmFamily.allCases, id: \.self) { family in
                let films = library.films.filter { $0.family == family }
                if !films.isEmpty {
                    Section(family.displayName) {
                        ForEach(films) { film in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text(film.displayName).font(.headline)
                                    Spacer()
                                    Text(film.iso > 0 ? "\(film.brand) \u{00B7} ISO \(film.iso)" : film.brand)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                                if !film.description.isEmpty {
                                    Text(film.description)
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            Section {
                AttributionFooter()
            }
        }
        .frame(minWidth: 420, minHeight: 360)
    }
}

/// The licence credit for the bundled film looks.
public struct AttributionFooter: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Film looks are from the RawTherapee Film Simulation Collection by Pat David (with Pavlov Dmitry and Michael Ezra), licensed under CC BY-SA 4.0. Film stock names are used for information only.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                if let url = URL(string: "https://rawpedia.rawtherapee.com/Film_Simulation") {
                    Link("RawPedia: Film Simulation", destination: url)
                }
                if let url = URL(string: "https://creativecommons.org/licenses/by-sa/4.0/") {
                    Link("CC BY-SA 4.0", destination: url)
                }
            }
            .font(.caption)
        }
    }
}
