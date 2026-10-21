import EmulsionCore
import SwiftUI

private typealias T = FieldFramesTheme

/// Every bundled film, grouped by family, with the licence credit.
public struct FilmsBrowserView: View {
    private let library: FilmLibrary

    public init(library: FilmLibrary) {
        self.library = library
    }

    public var body: some View {
        FFScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Films")
                        .font(T.display(40, weight: .regular))
                        .foregroundStyle(T.paper)
                    Text("\(library.films.count) looks \u{00B7} \(familyCount) families")
                        .ffLabel(color: T.paperDim)
                        .frame(height: T.rows(1))
                }
                .padding(.top, T.rows(2))
                .padding(.bottom, T.rows(1))

                ForEach(FilmFamily.allCases, id: \.self) { family in
                    let films = library.films.filter { $0.family == family }
                    if !films.isEmpty {
                        FFSectionLabel(family.displayName, trailing: String(format: "%03d", films.count))
                            .padding(.top, T.rows(2))
                        ForEach(films) { film in
                            FilmRow(film: film)
                            FFHairline()
                        }
                    }
                }

                FFSectionLabel("Credits")
                    .padding(.top, T.rows(3))
                AttributionFooter()
                    .padding(.top, T.rows(1))
                    .padding(.bottom, T.rows(3))
            }
            .padding(.horizontal, T.cells(4))
        }
        .frame(minWidth: 420, minHeight: 360)
        .fieldFramesWindow()
    }

    private var familyCount: Int {
        FilmFamily.allCases.filter { family in library.films.contains { $0.family == family } }.count
    }
}

private struct FilmRow: View {
    let film: Film

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(film.displayName)
                    .font(T.display(21, weight: .medium))
                    .foregroundStyle(T.paper)
                Spacer(minLength: T.cells(2))
                Text(film.iso > 0 ? "\(film.brand) \u{00B7} ISO \(film.iso)" : film.brand)
                    .ffLabel()
            }
            if !film.description.isEmpty {
                Text(film.description)
                    .font(.system(size: 12))
                    .foregroundStyle(T.paperMid)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, T.rows(1) / 2)
        .accessibilityElement(children: .combine)
    }
}

/// The licence credit for the bundled film looks.
public struct AttributionFooter: View {
    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: T.rows(1) / 2 + 2) {
            Text("Film looks are from the RawTherapee Film Simulation Collection by Pat David (with Pavlov Dmitry and Michael Ezra), licensed under CC BY-SA 4.0. Film stock names are used for information only.")
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
        }
    }
}
