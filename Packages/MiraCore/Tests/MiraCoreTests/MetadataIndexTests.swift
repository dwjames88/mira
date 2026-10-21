import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MiraCore

/// A small JPEG with the given EXIF, written with CGImageDestination.
private func exifJPEG(make: String? = "FUJIFILM", model: String? = "X-T5", lens: String? = "XF35mmF1.4 R",
                      iso: Int? = 400, width: Int = 64, height: Int = 48, padding: Int = 0) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.4, green: 0.5, blue: 0.3, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let out = NSMutableData()
    let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil)!
    var tiff: [String: Any] = [:]
    if let make { tiff[kCGImagePropertyTIFFMake as String] = make }
    if let model { tiff[kCGImagePropertyTIFFModel as String] = model }
    var exif: [String: Any] = [kCGImagePropertyExifFocalLength as String: 35.0,
                               kCGImagePropertyExifFNumber as String: 1.8,
                               kCGImagePropertyExifExposureTime as String: 0.004]
    if let lens { exif[kCGImagePropertyExifLensModel as String] = lens }
    if let iso { exif[kCGImagePropertyExifISOSpeedRatings as String] = [iso] }
    let props: [String: Any] = [kCGImagePropertyTIFFDictionary as String: tiff, kCGImagePropertyExifDictionary as String: exif]
    CGImageDestinationAddImage(dest, ctx.makeImage()!, props as CFDictionary)
    CGImageDestinationFinalize(dest)
    var data = out as Data
    if padding > 0 { data.append(Data(repeating: 0, count: padding)) }
    return data
}

private func tempFile(_ name: String = UUID().uuidString) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("mira-tests-\(name)/index.jsonl")
}

@Suite("Metadata parse")
struct MetadataParseTests {
    @Test func parsesCameraLensAndExposureFromAFixtureJPEG() throws {
        let parsed = try #require(EXIFParser.parse(data: exifJPEG()))
        #expect(parsed.make == "FUJIFILM")
        #expect(parsed.model == "X-T5")
        #expect(parsed.lens == "XF35mmF1.4 R")
        #expect(parsed.iso == 400)
        #expect(parsed.focalLength == 35)
        #expect(parsed.fNumber == 1.8)
        #expect(parsed.exposureTime == 0.004)
        #expect(parsed.hasCamera)
    }

    @Test func parsesFromTheSampleFixtureWithoutCrashing() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/sample.jpg")
        let data = try Data(contentsOf: url)
        let parsed = try #require(EXIFParser.parse(data: data))
        // Whatever the sample carries, every present field must be sane.
        if let iso = parsed.iso { #expect(iso > 0) }
        if let f = parsed.fNumber { #expect(f > 0) }
        #expect(parsed.make == nil || !parsed.make!.isEmpty)
        // And the head of the file alone gives the same camera as the whole file.
        let head = Data(data.prefix(64 * 1024))
        #expect(EXIFParser.parse(data: head, isFinal: false)?.model == parsed.model)
    }

    @Test func missingFieldsStayNil() throws {
        let parsed = try #require(EXIFParser.parse(data: exifJPEG(make: nil, model: nil, lens: nil, iso: nil)))
        #expect(!parsed.hasCamera)
        #expect(parsed.lens == nil)
        #expect(parsed.iso == nil)
    }

    @Test func accumulatorStopsAsSoonAsTheCameraIsKnownAndFeedsInChunks() {
        let data = exifJPEG(padding: 300_000)
        let acc = EXIFAccumulator(limit: 256 * 1024, firstAttempt: 1024, step: 1024)
        var outcome = EXIFAccumulator.Outcome.needMore
        var fed = 0
        while fed < data.count, outcome == .needMore {
            let end = min(fed + 512, data.count)
            outcome = acc.append(data.subdata(in: fed..<end))
            fed = end
        }
        guard case .done(let parsed) = outcome else { Issue.record("never finished"); return }
        #expect(parsed.model == "X-T5")
        #expect(fed < 256 * 1024, "stopped long before the cap")
    }

    @Test func accumulatorStopsAtTheByteLimitWithoutACamera() {
        let data = exifJPEG(make: nil, model: nil, padding: 400_000)
        let acc = EXIFAccumulator(limit: 64 * 1024, firstAttempt: 8 * 1024, step: 16 * 1024)
        var outcome = EXIFAccumulator.Outcome.needMore
        var fed = 0
        while fed < data.count, outcome == .needMore {
            let end = min(fed + 4096, data.count)
            outcome = acc.append(data.subdata(in: fed..<end))
            fed = end
        }
        guard case .done(let parsed) = outcome else { Issue.record("never finished"); return }
        #expect(!parsed.hasCamera)
        #expect(fed <= 64 * 1024 + 4096)
    }

    @Test func cameraNameDoesNotRepeatTheMake() {
        #expect(AssetMetadata(id: "a", make: "Canon", model: "Canon EOS R5").cameraName == "Canon EOS R5")
        #expect(AssetMetadata(id: "a", make: "FUJIFILM", model: "X-T5").cameraName == "FUJIFILM X-T5")
        #expect(AssetMetadata(id: "a", make: "Apple", model: nil).cameraName == "Apple")
        #expect(AssetMetadata(id: "a").cameraName == nil)
    }
}

@Suite("Metadata store")
struct MetadataStoreTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000.123)

    @Test func roundTripsThroughTheFile() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MetadataStore(fileURL: url)
        var a = AssetMetadata(id: "A/1", modificationDate: t0, creationDate: t0, filename: "IMG_1.CR3", pixelWidth: 6000, pixelHeight: 4000, isRAW: true)
        a.apply(ParsedEXIF(make: "Canon", model: "Canon EOS R5", lens: "RF50mm", iso: 100, focalLength: 50, fNumber: 1.2, exposureTime: 0.001))
        store.put([a, AssetMetadata(id: "B/2", modificationDate: t0, unavailable: true)])
        let again = MetadataStore(fileURL: url)
        #expect(again.load() == 2)
        #expect(again.metadata(for: "A/1") == a)
        #expect(again.metadata(for: "B/2")?.unavailable == true)
        #expect(again.metadata(for: "nope") == nil)
    }

    @Test func laterLinesWinAndCompactionKeepsOneLinePerEntry() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MetadataStore(fileURL: url)
        for i in 0..<2500 { store.put([AssetMetadata(id: "x", modificationDate: t0, filename: "v\(i)")]) }
        store.put([AssetMetadata(id: "y", modificationDate: t0, filename: "y")])
        let again = MetadataStore(fileURL: url)
        #expect(again.load() == 2)
        #expect(again.metadata(for: "x")?.filename == "v2499")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
        #expect(lines == 2, "loading compacted the superseded lines")
    }

    @Test func skipsCorruptLinesAndAppendsAfterATruncatedTail() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MetadataStore(fileURL: url)
        store.put([AssetMetadata(id: "a", filename: "a.jpg")])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"i\":\"half".utf8))
        try handle.close()
        store.put([AssetMetadata(id: "b", filename: "b.jpg")])
        let again = MetadataStore(fileURL: url)
        #expect(again.load() == 2)
        #expect(again.metadata(for: "a")?.filename == "a.jpg")
        #expect(again.metadata(for: "b")?.filename == "b.jpg")
    }

    @Test func modificationDateChangeInvalidatesTheEntry() {
        let store = MetadataStore(fileURL: nil)
        #expect(store.needsIndex(id: "a", modificationDate: t0), "unknown asset")
        store.put([AssetMetadata(id: "a", modificationDate: t0)])
        #expect(!store.needsIndex(id: "a", modificationDate: t0))
        #expect(!store.needsIndex(id: "a", modificationDate: t0.addingTimeInterval(0.0001)), "sub-millisecond noise is the same date")
        #expect(store.needsIndex(id: "a", modificationDate: t0.addingTimeInterval(60)))
        #expect(store.needsIndex(id: "a", modificationDate: nil))
    }

    @Test func unavailableEntriesAreRetriedOncePerLaunch() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MetadataStore(fileURL: url)
        store.put([AssetMetadata(id: "cloud", modificationDate: t0, unavailable: true)])
        #expect(!store.needsIndex(id: "cloud", modificationDate: t0), "just tried this session")
        let nextLaunch = MetadataStore(fileURL: url)
        nextLaunch.load()
        #expect(nextLaunch.needsIndex(id: "cloud", modificationDate: t0), "retry after relaunch")
        nextLaunch.put([AssetMetadata(id: "cloud", modificationDate: t0, make: "Apple")])
        #expect(!nextLaunch.needsIndex(id: "cloud", modificationDate: t0))
    }

    @Test func removeAllClearsMemoryAndFile() {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = MetadataStore(fileURL: url)
        store.put([AssetMetadata(id: "a")])
        store.removeAll()
        #expect(store.count == 0)
        #expect(MetadataStore(fileURL: url).load() == 0)
    }

    @Test func progressLine() {
        #expect(IndexProgress(indexed: 3, total: 10, finished: false).line == "INDEXING 3 / 10")
        #expect(IndexProgress(indexed: 10, total: 10, finished: true).line == nil)
    }
}
