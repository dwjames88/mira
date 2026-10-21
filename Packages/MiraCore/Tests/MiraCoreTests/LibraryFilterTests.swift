import Foundation
import Testing
@testable import MiraCore

private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = .current
    return c.date(from: DateComponents(year: y, month: m, day: d, hour: 12))!
}

private let r5 = AssetMetadata(id: "1", filename: "IMG_0001.CR3", make: "Canon", model: "Canon EOS R5", lens: "RF24-70mm F2.8", isRAW: true)
private let xt5 = AssetMetadata(id: "2", filename: "DSCF1234.JPG", make: "FUJIFILM", model: "X-T5", lens: "XF35mmF1.4 R")
private let xt5b = AssetMetadata(id: "3", filename: "DSCF9999.RAF", make: "FUJIFILM", model: "X-T5", lens: "XF16mmF1.4")
private func facts(_ id: String = "1", _ d: Date? = date(2025, 7, 15), raw: Bool = false, edited: Bool = false, fav: Bool = false) -> AssetFacts {
    AssetFacts(id: id, creationDate: d, isRAW: raw, isEdited: edited, isFavorite: fav)
}

@Suite("Library filter")
struct LibraryFilterTests {
    @Test func emptyFilterMatchesEverythingEvenUnindexed() {
        let f = LibraryFilter()
        #expect(!f.isActive)
        #expect(f.activeCount == 0)
        #expect(f.matches(nil, facts: facts()))
        #expect(f.matches(r5, facts: facts()))
    }

    @Test func eachSimpleCriterion() {
        var f = LibraryFilter(); f.rawOnly = true
        #expect(f.matches(nil, facts: facts(raw: true)))
        #expect(!f.matches(nil, facts: facts(raw: false)))
        f = LibraryFilter(); f.editedOnly = true
        #expect(f.matches(nil, facts: facts(edited: true)))
        #expect(!f.matches(nil, facts: facts()))
        f = LibraryFilter(); f.favoritesOnly = true
        #expect(f.matches(nil, facts: facts(fav: true)))
        #expect(!f.matches(nil, facts: facts()))
    }

    @Test func cameraAndLensNeedIndexedMetadata() {
        var f = LibraryFilter(); f.cameras = ["FUJIFILM X-T5"]
        #expect(f.matches(xt5, facts: facts()))
        #expect(!f.matches(r5, facts: facts()))
        #expect(!f.matches(nil, facts: facts()), "unindexed assets do not match a camera criterion")
        f.cameras = ["FUJIFILM X-T5", "Canon EOS R5"]
        #expect(f.matches(r5, facts: facts()) && f.matches(xt5, facts: facts()))
        f = LibraryFilter(); f.lenses = ["XF16mmF1.4"]
        #expect(f.matches(xt5b, facts: facts()))
        #expect(!f.matches(xt5, facts: facts()))
        #expect(!f.matches(nil, facts: facts()))
    }

    @Test func criteriaCompose() {
        var f = LibraryFilter()
        f.cameras = ["FUJIFILM X-T5"]; f.lenses = ["XF35mmF1.4 R"]; f.editedOnly = true; f.favoritesOnly = true
        #expect(f.matches(xt5, facts: facts(edited: true, fav: true)))
        #expect(!f.matches(xt5, facts: facts(edited: false, fav: true)))
        #expect(!f.matches(xt5, facts: facts(edited: true, fav: false)))
        #expect(!f.matches(xt5b, facts: facts(edited: true, fav: true)), "right camera, wrong lens")
        f.rawOnly = true
        #expect(!f.matches(xt5, facts: facts(raw: false, edited: true, fav: true)))
        #expect(f.matches(xt5, facts: facts(raw: true, edited: true, fav: true)))
        f.search = "dscf12"
        #expect(f.matches(xt5, facts: facts(raw: true, edited: true, fav: true)))
        f.search = "dscf99"
        #expect(!f.matches(xt5, facts: facts(raw: true, edited: true, fav: true)))
    }

    @Test func activeCountCountsCriteriaNotItems() {
        var f = LibraryFilter()
        f.scope = .myLibrary; f.rawOnly = true; f.cameras = ["a", "b", "c"]; f.search = "  "
        #expect(f.activeCount == 3, "whitespace-only search is not a criterion")
        f.search = "x"; f.lenses = ["l"]; f.editedOnly = true; f.favoritesOnly = true
        #expect(f.activeCount == 7)
        #expect(f.needsAssetPass && f.needsMetadata)
        #expect(f.fetchCriteria == [true, true])
        f = LibraryFilter(); f.favoritesOnly = true
        #expect(!f.needsAssetPass, "favorites are answered by the fetch predicate")
    }

    @Test func searchMatchesFilenameCameraLensCaseInsensitively() {
        func hit(_ q: String, _ m: AssetMetadata?) -> Bool { var f = LibraryFilter(); f.search = q; return f.matches(m, facts: facts()) }
        #expect(hit("img_0001", r5))
        #expect(hit("IMG_0001.cr3", r5))
        #expect(hit("eos r5", r5))
        #expect(hit("FUJIFILM", xt5))
        #expect(hit("x-t5 xf35", xt5), "all words must match, in any order")
        #expect(hit("f1.4 xf35", xt5))
        #expect(!hit("xf35 canon", xt5))
        #expect(!hit("nothing", xt5))
        #expect(!hit("dscf", nil), "unindexed assets have no text to match")
    }

    @Test func searchMatchesDateText() {
        let july = date(2025, 7, 15)
        for q in ["2025", "July 2025", "Jul 2025", "2025-07", "2025-07-15", "15 July 2025", "july", "JUL 2025"] {
            #expect(LibraryFilter.dateMatches(q, july), "\(q)")
        }
        for q in ["2024", "June 2025", "Jun 2025", "2025-06", "july 2024", "2025-08", ""] {
            #expect(!LibraryFilter.dateMatches(q, july), "\(q)")
        }
        #expect(!LibraryFilter.dateMatches("2025", nil))
        var f = LibraryFilter(); f.search = "Jul 2025"
        #expect(f.matches(nil, facts: facts("1", july)), "dates match even before indexing")
        #expect(!f.matches(nil, facts: facts("1", date(2025, 8, 1))))
        f.search = "fuji 2025"
        #expect(f.matches(xt5, facts: facts("2", july)), "text and date words combine")
        #expect(!f.matches(xt5, facts: facts("2", date(2024, 7, 15))))
    }

    @Test func facetCountsAreSortedAndSkipMissingFields() {
        let facets = LibraryFilter.facets(of: [r5, xt5, xt5b, nil, AssetMetadata(id: "9")])
        #expect(facets.cameras == [FacetCount(name: "FUJIFILM X-T5", count: 2), FacetCount(name: "Canon EOS R5", count: 1)])
        #expect(facets.lenses.map(\.count) == [1, 1, 1])
        #expect(facets.lenses.map(\.name) == ["RF24-70mm F2.8", "XF16mmF1.4", "XF35mmF1.4 R"])
        #expect(LibraryFilter.facets(of: [AssetMetadata?]()) == FilterFacets())
    }

    @Test func matchingIndicesKeepInputOrder() {
        let metas: [AssetMetadata?] = [xt5, r5, nil, xt5b, xt5]
        var f = LibraryFilter(); f.cameras = ["FUJIFILM X-T5"]
        let idx = f.matchingIndices(count: metas.count, facts: { facts("\($0)") }, meta: { metas[$0] })
        #expect(idx == [0, 3, 4])
    }

    /// 48,000 synthetic assets: the whole filter pass (search + camera + RAW) and the facet count.
    @Test func filterPassOver48kAssetsIsFast() {
        let n = 48_000
        let cameras = ["Canon EOS R5", "FUJIFILM X-T5", "Apple iPhone 15 Pro", "SONY ILCE-7M4", "NIKON Z 8"]
        let lenses = ["RF24-70mm F2.8", "XF35mmF1.4 R", "iPhone 15 Pro back camera 6.86mm f/1.78", "FE 24-70mm F2.8 GM", "NIKKOR Z 50mm f/1.8 S"]
        var metas: [AssetMetadata?] = []
        var allFacts: [AssetFacts] = []
        metas.reserveCapacity(n); allFacts.reserveCapacity(n)
        let base = date(2018, 1, 1)
        for i in 0..<n {
            let d = base.addingTimeInterval(Double(i) * 3600 * 4)
            allFacts.append(AssetFacts(id: "ID-\(i)", creationDate: d, isRAW: i % 3 == 0, isEdited: i % 7 == 0, isFavorite: i % 11 == 0))
            // The last 10% are not indexed yet.
            metas.append(i >= n - n / 10 ? nil : AssetMetadata(id: "ID-\(i)", creationDate: d, filename: "IMG_\(10000 + i).HEIC",
                                                               make: nil, model: cameras[i % 5], lens: lenses[i % 5]))
        }
        var f = LibraryFilter()
        f.search = "iphone 2021"; f.rawOnly = true; f.cameras = ["Apple iPhone 15 Pro", "NIKON Z 8"]
        let clock = ContinuousClock()
        var matched: [Int] = []
        let passTime = clock.measure {
            matched = f.matchingIndices(count: n, facts: { allFacts[$0] }, meta: { metas[$0] })
        }
        var facets = FilterFacets()
        let facetTime = clock.measure { facets = LibraryFilter.facets(of: metas) }
        print("FILTER-PERF 48k: pass \(passTime), facets \(facetTime), matched \(matched.count)")
        #expect(matched.count > 0)
        #expect(matched == matched.sorted())
        #expect(facets.cameras.count == 5)
        #expect(passTime < .seconds(2))
        #expect(facetTime < .seconds(1))
    }
}
