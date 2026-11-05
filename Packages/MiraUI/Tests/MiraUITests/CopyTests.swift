import Foundation
import MiraCore
import Testing
@testable import MiraUI

@MainActor
@Suite("User-facing copy")
struct CopyTests {
    @Test func familyNamesAreUSEnglish() {
        #expect(FilmFamily.displayOrder.map(\.displayName) == ["Color Negative", "Slide", "Kodachrome", "Motion Picture", "Black & White", "Instant", "Print"])
    }

    @Test func filmCatalogUsesUSSpelling() throws {
        let root = SnapshotTests.root.appendingPathComponent("Films")
        let library = try FilmLibrary(directory: root)
        let banned = ["colour", "favourite", "grey", "licence", "organis", "centre"]
        for film in library.films {
            for word in banned {
                #expect(!film.displayName.lowercased().contains(word), "\(film.id) name")
                #expect(!film.description.lowercased().contains(word), "\(film.id) description")
            }
        }
    }

    @Test func versionLineHasShortVersionAndBuild() {
        #expect(AboutView.bundleVersion().hasPrefix("VERSION "))
    }

    @Test func openFailureCopy() {
        #expect(FFOpenFailureCard.defaultMessage == "Photos didn't hand over this photo.")
    }
}
