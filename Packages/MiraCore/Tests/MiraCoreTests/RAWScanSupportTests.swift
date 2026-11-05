import Foundation
import Testing
@testable import MiraCore

@Suite struct RAWScanSupportTests {
    @Test func modificationDateInvalidatesEntry() {
        var c = RAWResultCache()
        let d1 = Date(timeIntervalSinceReferenceDate: 1000), d2 = Date(timeIntervalSinceReferenceDate: 2000)
        c.record(id: "a", modificationDate: d1, isRAW: true)
        #expect(c.lookup(id: "a", modificationDate: d1) == true)
        #expect(c.lookup(id: "a", modificationDate: d2) == nil)
        #expect(c.lookup(id: "a", modificationDate: nil) == nil)
        c.record(id: "n", modificationDate: nil, isRAW: false)
        #expect(c.lookup(id: "n", modificationDate: nil) == false)
        c.invalidate(ids: ["a"])
        #expect(c.lookup(id: "a", modificationDate: d1) == nil)
    }

    @Test func cacheIsBoundedAndKeepsNewest() {
        var c = RAWResultCache(capacity: 20)
        for i in 0..<100 { c.record(id: "id\(i)", modificationDate: nil, isRAW: true) }
        #expect(c.count <= 20)
        #expect(c.lookup(id: "id99", modificationDate: nil) == true)
        #expect(c.lookup(id: "id0", modificationDate: nil) == nil)
    }

    @Test func cachePersistsRoundTrip() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("raw-\(UUID().uuidString)/c.json")
        var c = RAWResultCache()
        c.record(id: "x", modificationDate: Date(timeIntervalSinceReferenceDate: 5), isRAW: true)
        try c.write(to: url)
        let loaded = RAWResultCache.load(from: url)
        #expect(loaded.lookup(id: "x", modificationDate: Date(timeIntervalSinceReferenceDate: 5)) == true)
        #expect(RAWResultCache.load(from: url.appendingPathExtension("missing")).count == 0)
    }

    @Test func resourceClassification() {
        typealias F = RAWResourceFields
        #expect(RAWResourceClassifier.isRAW([F(role: .photo, typeIdentifier: "com.adobe.raw-image")]))
        #expect(RAWResourceClassifier.isRAW([F(role: .photo, typeIdentifier: "public.jpeg"),
                                             F(role: .alternatePhoto, typeIdentifier: "public.camera-raw-image")]))
        #expect(!RAWResourceClassifier.isRAW([F(role: .photo, typeIdentifier: "public.heic")]))
        #expect(!RAWResourceClassifier.isRAW([F(role: .other, typeIdentifier: "com.adobe.raw-image")]))
        #expect(!RAWResourceClassifier.isRAW([F]()))
    }

    @Test func batching() {
        #expect(RAWScanBatching.ranges(count: 5, size: 2) == [0..<2, 2..<4, 4..<5])
        #expect(RAWScanBatching.ranges(count: 0, size: 2).isEmpty)
        #expect(RAWScanBatching.ranges(count: 4, size: 4) == [0..<4])
        let s = RAWScanBatching.slices(Array(0..<10), lanes: 4)
        #expect(s.count <= 4 && s.flatMap { $0 } == Array(0..<10))
        #expect(RAWScanBatching.slices([Int](), lanes: 3).isEmpty)
    }
}
