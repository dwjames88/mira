import Testing
@testable import MiraCore

@Suite struct FilmBrowsingTests {
    @Test func familiesFollowDisplayOrderAndOnlyThoseWithStocks() throws {
        let lib = try FilmCatalogTests.library()
        let families = FilmBrowsing.families(in: lib)
        let present = Set(lib.stocks.map(\.family))
        #expect(families == FilmFamily.displayOrder.filter { present.contains($0) })
        #expect(families.count == present.count)
        #expect(!families.isEmpty)
    }

    @Test func stockCardsExcludeVariants() throws {
        let lib = try FilmCatalogTests.library()
        let all = FilmBrowsing.stocks(in: lib, family: nil)
        #expect(all.count == lib.stocks.count)
        #expect(all.allSatisfy { !$0.isVariant })
        #expect(all.count < lib.films.count)
        for family in FilmBrowsing.families(in: lib) {
            let cards = FilmBrowsing.stocks(in: lib, family: family)
            #expect(!cards.isEmpty)
            #expect(cards.allSatisfy { $0.family == family && !$0.isVariant })
        }
    }

    @Test func pushLabels() {
        #expect(FilmBrowsing.pushSteps.count == 13)
        #expect(FilmBrowsing.pushLabel(0) == "0")
        #expect(FilmBrowsing.pushLabel(1) == "+1")
        #expect(FilmBrowsing.pushLabel(4.0 / 3) == "+1\u{2153}")
        #expect(FilmBrowsing.pushLabel(1.0 / 3) == "+\u{2153}")
        #expect(FilmBrowsing.pushLabel(-2.0 / 3) == "\u{2212}\u{2154}")
        #expect(FilmBrowsing.pushLabel(-2) == "\u{2212}2")
        #expect(FilmBrowsing.pushSteps.map(FilmBrowsing.pushLabel).first == "\u{2212}2")
    }

    @Test func toningOnlyForMonochrome() throws {
        let lib = try FilmCatalogTests.library()
        let mono = lib.stocks.first { $0.isMonochrome }
        let colour = lib.stocks.first { !$0.isMonochrome }
        #expect(FilmBrowsing.offersToning(mono))
        #expect(!FilmBrowsing.offersToning(colour))
        #expect(!FilmBrowsing.offersToning(nil))
    }
}
