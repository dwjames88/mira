import Foundation
import Testing
import MiraCore
@testable import MiraCameraKit

/// Fakes record calls; `Mutex`-free via an actor-backed log.
actor CallLog {
    private(set) var entries: [String] = []
    func add(_ s: String) { entries.append(s) }
}

struct FakeLibrary: PhotoLibraryWriting {
    var accessLevel: LibraryAccess
    var log: CallLog
    var filesExistAtCreate: Bool = false
    func access() async -> LibraryAccess { accessLevel }
    func createAsset(photo: URL, alternateRaw: URL?) async throws -> String {
        await log.add("createAsset exists=\(FileManager.default.fileExists(atPath: photo.path))")
        return "asset-1"
    }
    func createBakedCopy(jpeg: URL) async throws -> String {
        await log.add("createBakedCopy exists=\(FileManager.default.fileExists(atPath: jpeg.path))")
        return "baked-1"
    }
}

actor FakePrintWriter: PrintWriting {
    enum Behavior: Sendable { case succeed, fail, missing }
    var behavior: [String: Behavior] = [:]
    var defaultBehavior: Behavior = .succeed
    private(set) var attached: [(recipe: Recipe, id: String, rawBase: Bool)] = []
    private(set) var attempts: [String] = []

    func set(_ b: Behavior, for id: String? = nil) {
        if let id { behavior[id] = b } else { defaultBehavior = b }
    }
    func attach(recipe: Recipe, toAsset id: String, rawBase: Bool) async throws {
        attempts.append(id)
        switch behavior[id] ?? defaultBehavior {
        case .succeed: attached.append((recipe, id, rawBase))
        case .fail: throw PrintError.failed("nope")
        case .missing: throw PrintError.assetMissing
        }
    }
}

struct FakeBaker: PrintBaking {
    var log: CallLog
    var fails = false
    func bake(recipe: Recipe, photo: URL, raw: URL?) async throws -> URL {
        await log.add("bake exists=\(FileManager.default.fileExists(atPath: photo.path))")
        if fails { throw PrintError.failed("bake") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("baked-\(UUID().uuidString).jpg")
        try Data("jpeg".utf8).write(to: url)
        return url
    }
}

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("miracam-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func makeFrame(raw: Bool) throws -> CapturedFrame {
    let dir = tempDir()
    let heic = dir.appendingPathComponent("a.heic")
    try Data("heic".utf8).write(to: heic)
    var dng: URL?
    if raw {
        dng = dir.appendingPathComponent("a.dng")
        try Data("dng".utf8).write(to: dng!)
    }
    return CapturedFrame(heicURL: heic, dngURL: dng, pixelSize: PixelSize(width: 4032, height: 3024), exposureTime: 0.01)
}

@Suite struct PendingPrintTests {
    let recipe = Recipe(filmID: "kodak-portra-400", exposure: 0.2)

    @Test func survivesReinit() async throws {
        let dir = tempDir()
        let writer = FakePrintWriter()
        let q1 = PrintQueue(store: PendingPrintStore(directory: dir), writer: writer)
        try await q1.enqueue(assetID: "a", recipe: recipe, rawBase: true)
        try await q1.enqueue(assetID: "b", recipe: recipe, rawBase: false)
        #expect(await q1.pendingCount == 2)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("pending-prints.json").path))

        let q2 = PrintQueue(store: PendingPrintStore(directory: dir), writer: writer)
        #expect(await q2.pendingCount == 2)
        let items = await q2.pending
        #expect(items.map(\.assetID) == ["a", "b"] && items[0].recipe == recipe && items[0].rawBase && !items[1].rawBase)
        await q2.drain()
        #expect(await q2.pendingCount == 0)
        #expect(await PrintQueue(store: PendingPrintStore(directory: dir), writer: writer).pendingCount == 0)
        #expect(await writer.attempts == ["a", "b"])
    }

    @Test func failingItemStaysQueuedAndDrainMovesOn() async throws {
        let writer = FakePrintWriter()
        await writer.set(.fail, for: "a")
        let q = PrintQueue(store: PendingPrintStore(directory: tempDir()), writer: writer)
        try await q.enqueue(assetID: "a", recipe: recipe, rawBase: true)
        try await q.enqueue(assetID: "b", recipe: recipe, rawBase: true)
        await q.drain()
        #expect(await writer.attempts == ["a", "b"])
        let left = await q.pending
        #expect(left.map(\.assetID) == ["a"] && left[0].attempts == 1)
        await q.drain()
        #expect(await q.pending[0].attempts == 2)
        // Retry succeeds once the writer recovers.
        await writer.set(.succeed, for: "a")
        await q.drain()
        #expect(await q.pendingCount == 0)
    }

    @Test func assetMissingDropsTheItem() async throws {
        let writer = FakePrintWriter()
        await writer.set(.missing, for: "gone")
        let dir = tempDir()
        let q = PrintQueue(store: PendingPrintStore(directory: dir), writer: writer)
        try await q.enqueue(assetID: "gone", recipe: recipe, rawBase: true)
        await q.drain()
        #expect(await q.pendingCount == 0)
        #expect(PendingPrintStore(directory: dir).load().isEmpty)
    }

    @Test func attemptsPersistAcrossReinit() async throws {
        let dir = tempDir()
        let writer = FakePrintWriter()
        await writer.set(.fail)
        let q = PrintQueue(store: PendingPrintStore(directory: dir), writer: writer)
        try await q.enqueue(assetID: "a", recipe: recipe, rawBase: true)
        await q.drain()
        #expect(await PrintQueue(store: PendingPrintStore(directory: dir), writer: writer).pending.first?.attempts == 1)
    }

    @Test func developedStreamAnnouncesAssets() async throws {
        let writer = FakePrintWriter()
        let q = PrintQueue(store: PendingPrintStore(directory: tempDir()), writer: writer)
        try await q.enqueue(assetID: "x", recipe: recipe, rawBase: true)
        await q.drain()
        var it = q.developed.makeAsyncIterator()
        #expect(await it.next() == "x")
    }

    @Test func drainIsSerialUnderConcurrentCalls() async throws {
        let writer = FakePrintWriter()
        let q = PrintQueue(store: PendingPrintStore(directory: tempDir()), writer: writer)
        for i in 0..<5 { try await q.enqueue(assetID: "i\(i)", recipe: recipe, rawBase: true) }
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<4 { g.addTask { await q.drain() } }
        }
        #expect(await q.pendingCount == 0)
        #expect(await writer.attempts == (0..<5).map { "i\($0)" })
    }

    @Test func corruptFileLoadsEmpty() throws {
        let dir = tempDir()
        try Data("garbage".utf8).write(to: dir.appendingPathComponent("pending-prints.json"))
        #expect(PendingPrintStore(directory: dir).load().isEmpty)
    }
}

@Suite struct CaptureSaverTests {
    let recipe = Recipe(filmID: "kodak-portra-400", exposure: 0.3, grainAmount: 0.8)

    private func make(_ access: LibraryAccess, bakeFails: Bool = false, writer: FakePrintWriter = FakePrintWriter())
        -> (CaptureSaver, CallLog, FakePrintWriter, PrintQueue) {
        let log = CallLog()
        let queue = PrintQueue(store: PendingPrintStore(directory: tempDir()), writer: writer)
        let saver = CaptureSaver(library: FakeLibrary(accessLevel: access, log: log), baker: FakeBaker(log: log, fails: bakeFails), queue: queue)
        return (saver, log, writer, queue)
    }

    @Test func fullAccessCreatesAssetThenAttachesRecipe() async throws {
        let (saver, log, writer, queue) = make(.full)
        let frame = try makeFrame(raw: true)
        await saver.captureStarted()
        let outcome = try await saver.save(frame, recipe: recipe)
        #expect(outcome == .developed(assetID: "asset-1"))
        #expect(await log.entries == ["createAsset exists=true"])
        let attached = await writer.attached
        #expect(attached.count == 1 && attached[0].id == "asset-1" && attached[0].rawBase)
        #expect(await queue.pendingCount == 0)
        // Step 1 succeeded, so the temp files are gone.
        #expect(!FileManager.default.fileExists(atPath: frame.heicURL.path))
        #expect(!FileManager.default.fileExists(atPath: frame.dngURL!.path))
        var it = saver.developedFrames.makeAsyncIterator()
        #expect(await it.next() == "asset-1")
        #expect(await saver.developingCount == 0)
    }

    @Test func heicOnlyFrameIsNotRawBased() async throws {
        let (saver, _, writer, _) = make(.full)
        _ = try await saver.save(try makeFrame(raw: false), recipe: recipe)
        #expect(await writer.attached.first?.rawBase == false)
    }

    @Test func failedPrintStaysPendingButTheNegativeIsSaved() async throws {
        let writer = FakePrintWriter()
        await writer.set(.fail)
        let (saver, _, _, queue) = make(.full, writer: writer)
        let outcome = try await saver.save(try makeFrame(raw: true), recipe: recipe)
        #expect(outcome == .printPending(assetID: "asset-1"))
        #expect(await queue.pendingCount == 1)
    }

    @Test func limitedAndAddOnlySaveOriginalPlusBakedCopy() async throws {
        for access in [LibraryAccess.limited, .addOnly] {
            let (saver, log, writer, queue) = make(access)
            let frame = try makeFrame(raw: true)
            let outcome = try await saver.save(frame, recipe: recipe)
            #expect(outcome == .bakedCopy(notice: "Allow full Photos access to keep frames re-editable.", originalAssetID: "asset-1", bakedAssetID: "baked-1"))
            // Baked before the library could take the files; copy created after the original.
            #expect(await log.entries == ["bake exists=true", "createAsset exists=true", "createBakedCopy exists=true"])
            let attempts = await writer.attempts
            let pending = await queue.pendingCount
            #expect(attempts.isEmpty && pending == 0)
            #expect(!FileManager.default.fileExists(atPath: frame.heicURL.path))
            var it = saver.developedFrames.makeAsyncIterator()
            #expect(await it.next() == "baked-1")
        }
    }

    @Test func bakeFailureStillKeepsTheOriginal() async throws {
        let (saver, log, _, _) = make(.limited, bakeFails: true)
        let outcome = try await saver.save(try makeFrame(raw: false), recipe: recipe)
        #expect(outcome == .originalOnly(assetID: "asset-1", notice: CaptureSaver.limitedAccessNotice))
        #expect(await log.entries.contains { $0.hasPrefix("createAsset") })
    }

    @Test func aFailedBakedCopyDoesNotStrandTheBakedFile() async throws {
        struct Failing: PhotoLibraryWriting {
            let step: String
            func access() async -> LibraryAccess { .limited }
            func createAsset(photo: URL, alternateRaw: URL?) async throws -> String {
                if step == "asset" { throw PrintError.failed("asset") }
                return "asset-1"
            }
            func createBakedCopy(jpeg: URL) async throws -> String { throw PrintError.failed("copy") }
        }
        actor Baked { var urls: [URL] = []; func add(_ u: URL) { urls.append(u) } }
        struct RecordingBaker: PrintBaking {
            let baked: Baked
            func bake(recipe: Recipe, photo: URL, raw: URL?) async throws -> URL {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("baked-\(UUID().uuidString).jpg")
                try Data("jpeg".utf8).write(to: url)
                await baked.add(url)
                return url
            }
        }
        for step in ["asset", "copy"] {
            let baked = Baked()
            let queue = PrintQueue(store: PendingPrintStore(directory: tempDir()), writer: FakePrintWriter())
            let saver = CaptureSaver(library: Failing(step: step), baker: RecordingBaker(baked: baked), queue: queue)
            await #expect(throws: PrintError.failed(step)) { try await saver.save(try makeFrame(raw: false), recipe: recipe) }
            let urls = await baked.urls
            #expect(urls.count == 1)
            #expect(urls.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
            #expect(await saver.developingCount == 0)
        }
    }

    @Test func deniedAndNotDeterminedThrowWithMonoCopyAndKeepTheFiles() async throws {
        for access in [LibraryAccess.denied, .notDetermined] {
            let (saver, log, _, _) = make(access)
            let frame = try makeFrame(raw: true)
            await #expect(throws: CaptureSaveError.photosAccessOff) { try await saver.save(frame, recipe: recipe) }
            #expect(CaptureSaveError.photosAccessOff.monoCopy == "PHOTOS ACCESS IS OFF")
            #expect(await log.entries.isEmpty)
            #expect(FileManager.default.fileExists(atPath: frame.heicURL.path))
        }
    }

    @Test func backPressureAtThreeInFlight() async throws {
        let (saver, _, _, _) = make(.full)
        #expect(await saver.canAcceptCapture)
        await saver.captureStarted(); await saver.captureStarted()
        #expect(await saver.canAcceptCapture)
        #expect(await saver.developingCount == 2)
        await saver.captureStarted()
        #expect(await saver.canAcceptCapture == false)
        #expect(await saver.developingCount == 3)
        _ = try await saver.save(try makeFrame(raw: true), recipe: recipe)
        #expect(await saver.canAcceptCapture)
        #expect(await saver.developingCount == 2)
        await saver.captureFailed()
        #expect(await saver.developingCount == 1)
        // A failed save also releases its slot.
        let (denied, _, _, _) = make(.denied)
        await denied.captureStarted()
        _ = try? await denied.save(try makeFrame(raw: false), recipe: recipe)
        #expect(await denied.developingCount == 0)
        // Never goes negative.
        await denied.captureFailed()
        #expect(await denied.developingCount == 0)
    }

    @Test func savedRecipeNeverCarriesFinderOnlyState() async throws {
        let (saver, _, writer, _) = make(.full)
        // The finder renders without grain, but that is derived; the saver is handed the user's recipe.
        let finder = FinderRecipe.recipe(from: recipe, quality: FinderQuality(grainLive: false))
        #expect(finder.grainAmount == 0)
        _ = try await saver.save(try makeFrame(raw: true), recipe: recipe)
        let saved = try #require(await writer.attached.first).recipe
        #expect(try saved.encoded() == recipe.encoded())
        #expect(saved.grainAmount == 0.8)
        #expect(!String(decoding: try saved.encoded(), as: UTF8.self).localizedCaseInsensitiveContains("seed"))
    }
}

@Test func savedAssetIDIsTheAssetTheUserKeeps() {
    #expect(SaveOutcome.developed(assetID: "a").savedAssetID == "a")
    #expect(SaveOutcome.printPending(assetID: "a").savedAssetID == "a")
    #expect(SaveOutcome.bakedCopy(notice: "n", originalAssetID: "o", bakedAssetID: "b").savedAssetID == "b")
    #expect(SaveOutcome.originalOnly(assetID: "o", notice: "n").savedAssetID == "o")
}
