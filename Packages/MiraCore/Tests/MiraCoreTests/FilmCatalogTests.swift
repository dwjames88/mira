import Foundation
import Testing
@testable import MiraCore

@Suite struct FilmCatalogTests {
    static let dir = FilmTests.filmsDirectory()

    static func library() throws -> FilmLibrary { try FilmLibrary(directory: dir) }

    // MARK: films.json integrity

    @Test func filesExistAndIDsAreUnique() throws {
        let films = try Self.library().films
        #expect(Set(films.map(\.id)).count == films.count, "duplicate ids")
        #expect(Set(films.map(\.file)).count == films.count, "two films share a file")
        for f in films {
            #expect(FileManager.default.fileExists(atPath: Self.dir.appendingPathComponent(f.file).path), "\(f.id): missing \(f.file)")
        }
    }

    @Test func parentsAndVariantLabels() throws {
        let films = try Self.library().films
        let byID = Dictionary(uniqueKeysWithValues: films.map { ($0.id, $0) })
        for f in films {
            if let parent = f.parent {
                let p = byID[parent]
                #expect(p != nil, "\(f.id): unknown parent \(parent)")
                #expect(p?.parent == nil, "\(f.id): parent \(parent) is itself a variant")
                #expect(!(f.variant ?? "").isEmpty, "\(f.id): variant without a label")
            } else {
                #expect(f.variant == nil, "\(f.id): stock with a variant label")
            }
        }
    }

    @Test func everyFilmHasMatchingAttributionRow() throws {
        let films = try Self.library().films
        let text = try String(contentsOf: Self.dir.appendingPathComponent("ATTRIBUTION.md"), encoding: .utf8)
        var rows: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("| ") {
            let cells = line.split(separator: "|", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 2, cells[0] != "id", !cells[0].hasPrefix("---") else { continue }
            #expect(rows[cells[0]] == nil, "duplicate attribution row \(cells[0])")
            rows[cells[0]] = cells[1]
        }
        for f in films {
            #expect(rows[f.id] != nil, "\(f.id): no attribution row")
            #expect(f.source != nil && rows[f.id] == f.source, "\(f.id): attribution source differs from films.json")
        }
        #expect(rows.count == films.count, "attribution has rows for films that don't exist")
    }

    @Test func everyHaldFileIsReferencedOnceAndValid() throws {
        let films = try Self.library().films
        let hald = Self.dir.appendingPathComponent("HaldCLUT", isDirectory: true)
        let onDisk = try FileManager.default.contentsOfDirectory(atPath: hald.path).filter { !$0.hasPrefix(".") }
        let referenced = films.map { ($0.file as NSString).lastPathComponent }
        #expect(Set(referenced).count == referenced.count)
        #expect(Set(onDisk) == Set(referenced), "unreferenced or missing files: \(Set(onDisk).symmetricDifference(referenced).sorted())")

        for f in films {
            let url = Self.dir.appendingPathComponent(f.file)
            let lut = try LUT.loadHald(url: url)
            #expect(lut.dimension >= 2 && lut.dimension <= LUT.maxHaldDimension, "\(f.id): dimension \(lut.dimension)")
            // The decoded cube is 4 Float32 channels per texel.
            #expect(lut.data.count == lut.dimension * lut.dimension * lut.dimension * 16)
        }
    }

    // MARK: stock / variant grouping

    @Test func variantsOfListsStockFirst() throws {
        let lib = try Self.library()
        #expect(!lib.stocks.contains { $0.isVariant })
        #expect(lib.stocks.count < lib.films.count)
        var checkedVariants = 0
        for stock in lib.stocks {
            let list = lib.variants(of: stock.id)
            #expect(list.first?.id == stock.id)
            #expect(list.dropFirst().allSatisfy { $0.parent == stock.id })
            #expect(list.count == 1 + lib.films.filter { $0.parent == stock.id }.count)
            for v in list.dropFirst() {
                #expect(lib.variants(of: v.id).map(\.id) == list.map(\.id))
                checkedVariants += 1
            }
        }
        #expect(checkedVariants == lib.films.count - lib.stocks.count)
        #expect(lib.variants(of: "nope").isEmpty)

        let portra = lib.variants(of: "kodak-portra-400").map(\.id)
        #expect(portra.first == "kodak-portra-400")
        #expect(portra.contains("kodak-portra-400-minus-1") && portra.contains("kodak-portra-400-plus-1"))
        #expect(portra.firstIndex(of: "kodak-portra-400-minus-1")! < portra.firstIndex(of: "kodak-portra-400-plus-1")!)
    }

    // MARK: character defaults and overrides

    @Test func characterDefaultsFollowISOAndFamily() {
        let lo = FilmCharacter.defaults(family: .colorNegative, iso: 100, monochrome: false)
        let hi = FilmCharacter.defaults(family: .colorNegative, iso: 1600, monochrome: false)
        #expect(hi.grainStrength > lo.grainStrength)
        #expect(hi.grainSize > lo.grainSize)

        let bw = FilmCharacter.defaults(family: .blackAndWhite, iso: 400, monochrome: true)
        #expect(bw.grainChroma == 0)
        #expect(bw.halationTint == [1, 1, 1])
        let instantBW = FilmCharacter.defaults(family: .instant, iso: 3000, monochrome: true)
        #expect(instantBW.grainChroma == 0)
        #expect(instantBW.halationTint == [1, 1, 1])

        let neg = FilmCharacter.defaults(family: .colorNegative, iso: 400, monochrome: false)
        let slide = FilmCharacter.defaults(family: .slide, iso: 400, monochrome: false)
        #expect(slide.halationStrength < neg.halationStrength)
        #expect(slide.latitude < neg.latitude)
    }

    @Test func newFamiliesHaveTheirOwnDefaults() throws {
        let slide = FilmCharacter.defaults(family: .slide, iso: 100, monochrome: false)
        let kodachrome = FilmCharacter.defaults(family: .kodachrome, iso: 100, monochrome: false)
        #expect(kodachrome.grainStrength < slide.grainStrength)
        let motion = FilmCharacter.defaults(family: .motionPicture, iso: 500, monochrome: false)
        #expect(motion.remJet)
        #expect(!FilmCharacter.defaults(family: .colorNegative, iso: 500, monochrome: false).remJet)
        let print = FilmCharacter.defaults(family: .print, iso: 100, monochrome: false)
        #expect(print.grainStrength > 0)
        #expect(FilmFamily.allCases.contains(.print))

        let lib = try Self.library()
        for f in lib.films where f.id.hasPrefix("kodak-kodachrome") {
            #expect(f.family == .kodachrome, "\(f.id)")
        }
    }

    @Test func catalogCharacterOverridesAreApplied() throws {
        let lib = try Self.library()
        let ektar = try #require(lib.film(id: "kodak-ektar-100"))
        let base = FilmCharacter.defaults(family: ektar.family, iso: ektar.iso, monochrome: ektar.isMonochrome)
        let override = try #require(ektar.character?.grainStrength)
        #expect(ektar.resolvedCharacter.grainStrength == override)
        #expect(override != base.grainStrength)
        #expect(ektar.resolvedCharacter.halationStrength == base.halationStrength)

        // Black-and-white instant films are monochrome through the flag, not the family.
        for f in lib.films where f.family == .instant && f.monochrome == true {
            #expect(f.resolvedCharacter.grainChroma == 0, "\(f.id)")
            #expect(f.resolvedCharacter.halationTint == [1, 1, 1], "\(f.id)")
        }
        // Variants carry their stock's character.
        for f in lib.films where f.isVariant {
            let stock = try #require(lib.film(id: f.stockID))
            #expect(f.resolvedCharacter == stock.resolvedCharacter, "\(f.id)")
        }
        // Overrides stay modest.
        for f in lib.films {
            guard let g = f.character?.grainStrength else { continue }
            let d = FilmCharacter.defaults(family: f.family, iso: f.iso, monochrome: f.isMonochrome).grainStrength
            #expect(abs(g - d) / d <= 0.4, "\(f.id): grain override \(g) vs default \(d)")
        }
    }

    // MARK: memory cache

    @Test func memoryCacheIsBounded() throws {
        let lib = try Self.library()
        let limit = FilmLibrary.memoryCacheLimit
        let films = Array(lib.films.prefix(limit + 8))
        try #require(films.count > limit)
        for f in films {
            _ = try lib.lut(for: f)
            #expect(lib.memoryCacheCount <= limit)
        }
        #expect(lib.memoryCacheCount == limit)
        // Evicted films are simply reloaded.
        #expect(try lib.lut(for: films[0]).dimension > 1)
        #expect(lib.memoryCacheCount == limit)
    }
}
