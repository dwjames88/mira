import Foundation
import Testing
@testable import MiraCore

@Suite struct FilmStockTests {
    static func library() throws -> FilmLibrary { try FilmCatalogTests.library() }

    private func isoLabels(_ lib: FilmLibrary, _ id: String) -> [String] { lib.isoChoices(stockID: id).map(\.label) }
    private func variations(_ lib: FilmLibrary, _ id: String, _ iso: Int) -> [String] {
        lib.variationChoices(stockID: id, iso: iso).map(\.label)
    }

    @Test func everyFilmBelongsToExactlyOneStockWithOneBase() throws {
        let lib = try Self.library()
        #expect(lib.films.allSatisfy { $0.stock != nil })
        #expect(lib.filmStocks.map(\.films.count).reduce(0, +) == lib.films.count)
        #expect(Set(lib.filmStocks.map(\.id)).count == lib.filmStocks.count)
        for stock in lib.filmStocks {
            #expect(stock.films.filter(\.isStockBase).count == 1, "\(stock.id): bases")
            let base = try #require(lib.film(id: stock.baseFilmID))
            #expect(base.isStockBase && base.stockName != nil, "\(stock.id): base needs stockName")
            #expect(stock.films.allSatisfy { $0.family == stock.family && $0.brand == stock.brand }, "\(stock.id)")
            #expect(stock.films.filter { !$0.isStockBase }.allSatisfy { $0.stockName == nil }, "\(stock.id)")
            for f in stock.films { #expect(lib.stock(for: f.id)?.id == stock.id) }
            // Each (iso, variation) pair names one film.
            let keys = stock.films.map { "\($0.iso)|\($0.variationLabel ?? "")" }
            #expect(Set(keys).count == keys.count, "\(stock.id): duplicate iso/variation")
        }
        #expect(lib.stocks.count == lib.filmStocks.count)
        #expect(lib.filmStocks.count == 51)
    }

    @Test func familyTabsOnlyShowFamiliesWithStocks() throws {
        let lib = try Self.library()
        let families = FilmBrowsing.families(in: lib)
        #expect(Set(families) == Set(lib.filmStocks.map(\.family)))
        for family in families {
            #expect(FilmBrowsing.stocks(in: lib, family: family).count == lib.filmStocks.filter { $0.family == family }.count)
        }
    }

    @Test func portraChoices() throws {
        let lib = try Self.library()
        #expect(isoLabels(lib, "kodak-portra") == ["160", "400", "800"])
        #expect(variations(lib, "kodak-portra", 400)
                == ["Standard", "\u{2212}1", "+1", "+2", "NC \u{2212}1", "NC", "NC +1", "NC +2", "UC \u{2212}1", "UC", "UC +1", "UC +2",
                    "VC \u{2212}1", "VC", "VC +1", "VC +2"])
        #expect(variations(lib, "kodak-portra", 800) == ["Standard", "\u{2212}1", "+1", "+2", "High contrast"])
        #expect(lib.film(stockID: "kodak-portra", iso: 800, variation: "+1")?.id == "kodak-portra-800-plus-1")
        #expect(lib.film(stockID: "kodak-portra", iso: 160, variation: "NC +2")?.id == "kodak-portra-160-nc-plus-2")
        #expect(lib.film(stockID: "kodak-portra", iso: 400, variation: nil)?.id == "kodak-portra-400")
        // Switching ISO keeps the variation where the new ISO has it, else drops to Standard.
        #expect(lib.film(stockID: "kodak-portra", iso: 160, variation: "+1")?.id == "kodak-portra-160-plus-1")
        #expect(lib.film(stockID: "kodak-portra", iso: 800, variation: "NC")?.id == "kodak-portra-800")
    }

    @Test func superiaChoices() throws {
        let lib = try Self.library()
        #expect(isoLabels(lib, "fuji-superia") == ["100", "200", "400", "800", "1600"])
        #expect(variations(lib, "fuji-superia", 100) == ["Standard", "\u{2212}1", "+1", "+2", "Reala"])
        #expect(variations(lib, "fuji-superia", 200) == ["Standard"])
        #expect(variations(lib, "fuji-superia", 1600) == ["Standard", "\u{2212}1", "+1", "+2", "HG"])
        #expect(lib.film(stockID: "fuji-superia", iso: 1600, variation: "HG")?.id == "fuji-superia-hg-1600")
        #expect(lib.film(stockID: "fuji-superia", iso: 800, variation: "X-Tra")?.id == "fuji-superia-x-tra-800")
        #expect(lib.film(stockID: "fuji-superia", iso: 100, variation: "Reala")?.id == "fuji-superia-reala-100")
    }

    @Test func proviaAndVelviaChoices() throws {
        let lib = try Self.library()
        #expect(isoLabels(lib, "fuji-provia") == ["100F", "400"])
        #expect(variations(lib, "fuji-provia", 100) == ["Standard", "Generic"])
        #expect(variations(lib, "fuji-provia", 400) == ["F", "X"])
        #expect(lib.film(stockID: "fuji-provia", iso: 400, variation: "X")?.id == "fuji-provia-400x")
        #expect(lib.film(stockID: "fuji-provia", iso: 400, variation: "F")?.id == "fuji-provia-400f")
        // 400 has no plain film: fall back to the first film at that ISO.
        #expect(lib.film(stockID: "fuji-provia", iso: 400, variation: nil)?.id == "fuji-provia-400f")
        #expect(lib.film(stockID: "fuji-provia", iso: 400, variation: "Generic")?.id == "fuji-provia-400f")
        #expect(lib.film(stockID: "fuji-provia", iso: 100, variation: "Generic")?.id == "fuji-provia-100f-generic")
        #expect(isoLabels(lib, "fuji-velvia") == ["50", "100"])
        #expect(variations(lib, "fuji-velvia", 50) == ["Standard"])
        #expect(lib.film(stockID: "fuji-velvia", iso: 100, variation: nil)?.id == "fuji-velvia-100")
        #expect(lib.stock(id: "fuji-velvia")?.baseFilmID == "fuji-velvia-50")
    }

    @Test func instantStockChoices() throws {
        let lib = try Self.library()
        #expect(isoLabels(lib, "polaroid-690") == ["80"])
        #expect(variations(lib, "polaroid-690", 80)
                == ["Standard", "\u{2212}2", "\u{2212}1", "+1", "+2", "Cold \u{2212}2", "Cold \u{2212}1", "Cold", "Cold +1", "Cold +2",
                    "Warm \u{2212}2", "Warm \u{2212}1", "Warm", "Warm +1", "Warm +2"])
        #expect(lib.film(stockID: "polaroid-690", iso: 80, variation: "Warm \u{2212}1")?.id == "polaroid-690-warm-minus-1")
        #expect(lib.stock(id: "polaroid-690")?.name == "690")
        #expect(variations(lib, "fuji-fp-100c", 100).prefix(7)
                == ["Standard", "\u{2212}2", "\u{2212}1", "+1", "+2", "+3", "Alt"])
        #expect(variations(lib, "fuji-fp-100c", 100).contains("Negative +3"))
        #expect(lib.film(stockID: "fuji-fp-100c", iso: 100, variation: "Negative")?.id == "fuji-fp-100c-negative")
        #expect(lib.film(stockID: "fuji-fp-100c", iso: 100, variation: "Negative +2 Alt")?.id == "fuji-fp-100c-negative-plus-2-alt")
        #expect(lib.film(stockID: "fuji-fp-100c", iso: 100, variation: "+2 Alt")?.id == "fuji-fp-100c-plus-2-alt")
        #expect(lib.stock(id: "polaroid-664") != nil && lib.stock(id: "polaroid-672") != nil)
    }

    @Test func oldFilmIDsResolveToStocks() throws {
        let lib = try Self.library()
        let stock = try #require(lib.stock(for: "kodak-portra-400-plus-1"))
        #expect(stock.id == "kodak-portra" && stock.name == "Portra")
        let film = try #require(lib.film(id: "kodak-portra-400-plus-1"))
        #expect(film.iso == 400 && film.variationLabel == "+1" && !film.isStockBase)
        #expect(lib.stock(for: "fuji-superia-200-xpro")?.id == "fuji-superia-200-xpro")
        #expect(lib.stock(for: "nope") == nil)
        for f in lib.films {
            #expect(lib.film(stockID: f.stockID, iso: f.iso, variation: f.variationLabel)?.id == f.id, "\(f.id)")
        }
    }

    @Test func legacyLibrariesWithoutStockFieldsStillGroup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stocks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = """
        [{"id":"a","displayName":"A 100","brand":"X","family":"colorNegative","iso":100,"file":"a.png"},
         {"id":"a-p1","displayName":"A 100 +1","brand":"X","family":"colorNegative","iso":100,"file":"b.png","parent":"a","variant":"+1"}]
        """
        try json.write(to: dir.appendingPathComponent("films.json"), atomically: true, encoding: .utf8)
        let lib = try FilmLibrary(directory: dir)
        #expect(lib.filmStocks.count == 1)
        #expect(lib.stock(for: "a-p1")?.baseFilmID == "a")
        #expect(lib.variationChoices(stockID: "a", iso: 100).map(\.label) == ["Standard", "+1"])
        #expect(lib.film(stockID: "a", iso: 100, variation: "+1")?.id == "a-p1")
    }
}
