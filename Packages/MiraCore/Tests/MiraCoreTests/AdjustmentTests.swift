import Foundation
import Photos
import Testing
@testable import MiraCore

@Suite struct AdjustmentTests {
    static let recipe = Recipe(filmID: "kodak-portra-400", strength: 0.7, exposure: 0.3, grainAmount: 0.4, borderEnabled: true)

    @Test func encodeDecodeRoundTrip() throws {
        let data = try MiraAdjustment.encode(Self.recipe)
        let back = MiraAdjustment.decode(formatIdentifier: "com.fieldframes.mira", formatVersion: "1", data: data)
        #expect(back == Self.recipe)
    }

    @Test func rejectsForeignIdentifierAndVersion() throws {
        let data = try MiraAdjustment.encode(Self.recipe)
        #expect(MiraAdjustment.decode(formatIdentifier: "com.other", formatVersion: "1", data: data) == nil)
        #expect(MiraAdjustment.decode(formatIdentifier: "com.fieldframes.mira", formatVersion: "9", data: data) == nil)
        #expect(MiraAdjustment.decode(formatIdentifier: "com.fieldframes.mira", formatVersion: "1", data: Data("nope".utf8)) == nil)
        #expect(!MiraAdjustment.canHandle(formatIdentifier: "com.fieldframes.mira", formatVersion: "2"))
        #expect(!MiraAdjustment.canHandle(formatIdentifier: "com.fieldframes.mira.x", formatVersion: "1"))
        #expect(MiraAdjustment.canHandle(formatIdentifier: "com.fieldframes.mira", formatVersion: "1"))
    }

    @Test func legacyIdentifierStillDecodes() throws {
        let data = try MiraAdjustment.encode(Self.recipe)
        #expect(MiraAdjustment.legacyFormatIdentifiers.contains("com.dwjames.emulsion"))
        #expect(MiraAdjustment.canHandle(formatIdentifier: "com.dwjames.emulsion", formatVersion: "1"))
        #expect(!MiraAdjustment.canHandle(formatIdentifier: "com.dwjames.emulsion", formatVersion: "2"))
        #expect(MiraAdjustment.decode(formatIdentifier: "com.dwjames.emulsion", formatVersion: "1", data: data) == Self.recipe)
        let legacy = PHAdjustmentData(formatIdentifier: "com.dwjames.emulsion", formatVersion: "1", data: data)
        #expect(MiraAdjustment.canHandle(legacy))
        #expect(MiraAdjustment.recipe(from: legacy) == Self.recipe)
    }

    @Test func encodeAlwaysWritesNewIdentifier() throws {
        let adj = try MiraAdjustment.adjustmentData(for: Self.recipe)
        #expect(adj.formatIdentifier == "com.fieldframes.mira")
        #expect(adj.formatVersion == "1")
    }

    @Test func photosAdjustmentDataRoundTrip() throws {
        let adj = try MiraAdjustment.adjustmentData(for: Self.recipe)
        #expect(adj.formatIdentifier == MiraFormat.adjustmentFormatIdentifier)
        #expect(MiraAdjustment.canHandle(adj))
        #expect(MiraAdjustment.recipe(from: adj) == Self.recipe)
        let foreign = PHAdjustmentData(formatIdentifier: "com.apple.photo", formatVersion: "1", data: adj.data)
        #expect(!MiraAdjustment.canHandle(foreign))
        #expect(MiraAdjustment.recipe(from: foreign) == nil)
    }
}

@Suite struct SidecarTests {
    static func tempDir() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mira-sidecar-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func sidecarURLKeepsExtension() {
        let u = SidecarStore.sidecarURL(for: URL(fileURLWithPath: "/a/b/IMG_1.CR3"))
        #expect(u.path == "/a/b/IMG_1.CR3.mira.json")
    }

    @Test func legacySidecarIsReadThenMigratedAndRemoved() throws {
        let dir = try Self.tempDir(), fb = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: fb) }
        let image = dir.appendingPathComponent("a.jpg")
        try Data([1, 2, 3]).write(to: image)
        let legacy = dir.appendingPathComponent("a.jpg.emulsion.json")
        let json = #"{"formatIdentifier":"com.dwjames.emulsion","formatVersion":"1","recipe":{"filmID":"old"}}"#
        try Data(json.utf8).write(to: legacy)
        let store = SidecarStore(fallbackDirectory: fb)
        #expect(store.load(for: image)?.filmID == "old")
        #expect(store.location(for: image) == .adjacent(legacy))

        // Saving writes only the new file and drops the legacy one.
        let loc = try store.save(Recipe(filmID: "new"), for: image)
        #expect(loc == .adjacent(SidecarStore.sidecarURL(for: image)))
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(store.load(for: image)?.filmID == "new")

        // remove deletes legacy files too.
        try Data(json.utf8).write(to: legacy)
        try store.remove(for: image)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(store.load(for: image) == nil)
    }

    @Test func saveLoadRemove() throws {
        let dir = try Self.tempDir(), fb = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: fb) }
        let image = dir.appendingPathComponent("a.jpg")
        try Data([1, 2, 3]).write(to: image)
        let store = SidecarStore(fallbackDirectory: fb)
        #expect(store.load(for: image) == nil)
        #expect(store.location(for: image) == nil)

        let recipe = Recipe(filmID: "x", exposure: 0.5)
        let loc = try store.save(recipe, for: image)
        #expect(loc == .adjacent(SidecarStore.sidecarURL(for: image)))
        #expect(store.load(for: image) == recipe)
        #expect(store.location(for: image) == loc)
        #expect(try Data(contentsOf: image) == Data([1, 2, 3]))

        try store.remove(for: image)
        #expect(store.load(for: image) == nil)
        #expect(store.location(for: image) == nil)
    }

    @Test func fallsBackWhenFolderIsReadOnly() throws {
        let dir = try Self.tempDir(), fb = try Self.tempDir()
        let fm = FileManager.default
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? fm.removeItem(at: dir); try? fm.removeItem(at: fb)
        }
        let image = dir.appendingPathComponent("ro.dng")
        try Data([9]).write(to: image)
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        let store = SidecarStore(fallbackDirectory: fb)
        let recipe = Recipe(filmID: "y", contrast: 0.2)
        let loc = try store.save(recipe, for: image)
        guard case .fallback(let url) = loc else { Issue.record("expected fallback, got \(loc)"); return }
        #expect(url.deletingLastPathComponent().standardizedFileURL == fb.standardizedFileURL)
        #expect(!fm.fileExists(atPath: SidecarStore.sidecarURL(for: image).path))
        #expect(store.load(for: image) == recipe)
        #expect(store.location(for: image) == loc)

        try store.remove(for: image)
        #expect(store.load(for: image) == nil)
    }

    @Test func rejectsForeignFormat() throws {
        let dir = try Self.tempDir(), fb = try Self.tempDir()
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: fb) }
        let image = dir.appendingPathComponent("f.jpg")
        let json = #"{"formatIdentifier":"com.someone.else","formatVersion":"1","recipe":{"filmID":"z"},"extra":1}"#
        try Data(json.utf8).write(to: SidecarStore.sidecarURL(for: image))
        #expect(SidecarStore(fallbackDirectory: fb).load(for: image) == nil)
        // Unknown keys are ignored for our own format.
        let ours = #"{"formatIdentifier":"com.fieldframes.mira","formatVersion":"1","recipe":{"filmID":"z"},"extra":1}"#
        try Data(ours.utf8).write(to: SidecarStore.sidecarURL(for: image))
        #expect(SidecarStore(fallbackDirectory: fb).load(for: image)?.filmID == "z")
    }
}

@Suite struct ImageSourceTests {
    static func sample() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Fixtures/sample.jpg")
    }

    @Test func rawDetection() {
        for name in ["a.dng", "a.DNG", "IMG_1.cr3", "x.nef", "x.arw"] {
            #expect(ImageSource.isRAW(url: URL(fileURLWithPath: "/nonexistent/\(name)")), "\(name)")
        }
        #expect(!ImageSource.isRAW(url: URL(fileURLWithPath: "/nonexistent/a.jpg")))
        #expect(!ImageSource.isRAW(url: Self.sample()))
    }

    @Test func explicitOrientationSwapsDimensions() throws {
        let plain = try #require(ImageSource.load(url: Self.sample(), orientation: .up))
        let rotated = try #require(ImageSource.load(url: Self.sample(), orientation: .right))
        #expect(rotated.extent.width == plain.extent.height)
        #expect(rotated.extent.height == plain.extent.width)
        #expect(ImageSource.load(url: Self.sample()) != nil)
    }
}

@Suite struct LUTCacheTests {
    @Test func cacheHitMatchesAndCorruptFileIsTolerated() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("mira-luts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let dir = FilmTests.filmsDirectory()
        let first = try FilmLibrary(directory: dir, cacheDirectory: cache)
        let film = try #require(first.films.first)
        let a = try first.lut(for: film)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".lut") }
        #expect(files.count == 1)

        let second = try FilmLibrary(directory: dir, cacheDirectory: cache)
        let b = try second.lut(for: film)
        #expect(a.dimension == b.dimension)
        #expect(a.data == b.data)

        // Truncate the cache file: it must be ignored and rewritten.
        let file = cache.appendingPathComponent(files[0])
        let full = try Data(contentsOf: file)
        try full.prefix(100).write(to: file)
        let third = try FilmLibrary(directory: dir, cacheDirectory: cache)
        let c = try third.lut(for: film)
        #expect(c.data == a.data)
        #expect(try Data(contentsOf: file) == full)

        try Data("garbage".utf8).write(to: file)
        let fourth = try FilmLibrary(directory: dir, cacheDirectory: cache)
        #expect(try fourth.lut(for: film).data == a.data)
    }

    @Test func prewarmLoadsEverything() throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("mira-luts-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let lib = try FilmLibrary(directory: FilmTests.filmsDirectory(), cacheDirectory: cache)
        lib.prewarmSync(concurrency: 4)
        let files = try FileManager.default.contentsOfDirectory(atPath: cache.path).filter { $0.hasSuffix(".lut") }
        #expect(files.count == lib.films.count)
    }
}
