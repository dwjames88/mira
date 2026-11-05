import Testing
@testable import MiraCore

@Suite struct RAWClassificationTests {
    let ids = ["a", "b", "c", "d", "e"]

    @Test func albumIsAuthoritative() {
        let c = RAWClassification(rawIDs: ["b", "d"])
        #expect(c.matchingIndices(in: ids) == [1, 3])
        #expect(c.unresolved(in: ids).isEmpty)
        #expect(c.isRAW("zzz") == false)
    }

    @Test func perAssetLookupsAreIncremental() {
        var c = RAWClassification()
        #expect(c.unresolved(in: ids) == [0, 1, 2, 3, 4])
        #expect(c.matchingIndices(in: ids).isEmpty)
        c.record(id: "a", isRAW: false)
        c.record(id: "b", isRAW: true)
        #expect(c.unresolved(in: ids, range: 0..<3) == [2])
        #expect(c.matchingIndices(in: ids, range: 0..<3) == [1])
        c.record(id: "e", isRAW: true)
        #expect(c.matchingIndices(in: ids, range: 3..<5) == [4])
        #expect(c.matchingIndices(in: ids) == [1, 4])
    }

    @Test func rawOnlyFilterRuleMatchesLibraryFilter() {
        var f = LibraryFilter()
        f.rawOnly = true
        #expect(f.matches(nil, facts: AssetFacts(id: "x", isRAW: true)))
        #expect(!f.matches(nil, facts: AssetFacts(id: "x", isRAW: false)))
        #expect(f.needsAssetPass)
    }
}
