import Foundation
import Testing
@testable import EmulsionCore

@Suite struct RecipeTests {
    @Test func roundTrip() throws {
        var r = Recipe()
        r.filmID = "kodak-portra-400"
        r.exposure = 0.5; r.grainAmount = 0.3; r.borderEnabled = true
        let data = try r.encoded()
        #expect(try Recipe.decode(data) == r)
        #expect(try r.encoded() == data)
    }

    @Test func emptyObjectGivesDefaults() throws {
        #expect(try Recipe.decode(Data("{}".utf8)) == Recipe.neutral)
    }

    @Test func unknownKeysAreIgnored() throws {
        let r = try Recipe.decode(Data(#"{"exposure":1.5,"futureThing":{"a":1},"version":2}"#.utf8))
        #expect(r.exposure == 1.5)
        #expect(r.version == 2)
        #expect(r.strength == 1)
    }

    @Test func formatIdentifiers() {
        #expect(EmulsionFormat.adjustmentFormatIdentifier == "com.dwjames.emulsion")
        #expect(EmulsionFormat.formatVersion == "1")
    }
}
