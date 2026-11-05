import Photos
import UIKit
import XCTest
@testable import Mira

/// Stress probe: opening a just-created asset must leave OPENING within seconds (no hung
/// requestContentEditingInput). Opt-in because it adds ~80 assets per run and never deletes them
/// (deletion pops a system alert): run with TEST_RUNNER_MIRA_STALL_PROBE=1 on a Photos-granted simulator.
/// Prints `STALLPROBE <test> iter=<n> ms=<elapsed> ok=<bool>` per iteration.
final class ChangeFlag: NSObject, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        lock.lock(); count += 1; lock.unlock()
    }
    nonisolated var changes: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class AssetOpenStallTests: XCTestCase {
    static let albumTitle = "Mira Open Stall Test"

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MIRA_STALL_PROBE"] == "1",
                          "Opt-in stress probe: set TEST_RUNNER_MIRA_STALL_PROBE=1")
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try XCTSkipUnless(s == .authorized || s == .limited, "Photos not authorized (\(s.rawValue))")
    }

    // MARK: helpers

    static func album() async throws -> PHAssetCollection {
        let o = PHFetchOptions()
        o.predicate = NSPredicate(format: "title = %@", albumTitle)
        if let a = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: o).firstObject { return a }
        var id = ""
        try await PHPhotoLibrary.shared().performChanges {
            id = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle).placeholderForCreatedAssetCollection.localIdentifier
        }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject!
    }

    static func makeJPEGFile() throws -> URL {
        let size = CGSize(width: 1200, height: 800)
        let fmt = UIGraphicsImageRendererFormat(); fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            for _ in 0..<12 {
                UIColor(red: .random(in: 0...1), green: .random(in: 0...1), blue: .random(in: 0...1), alpha: 1).setFill()
                ctx.fill(CGRect(x: .random(in: 0...1000), y: .random(in: 0...600), width: .random(in: 100...600), height: .random(in: 100...400)))
            }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stall-\(UUID().uuidString).jpg")
        try img.jpegData(compressionQuality: 0.9)!.write(to: url)
        return url
    }

    static func makeDNGFile() throws -> URL {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/raw/iphone-xs.dng")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stall-\(UUID().uuidString).dng")
        try FileManager.default.copyItem(at: src, to: url)
        return url
    }

    /// Creates an asset from `file` and adds it to the test album; returns its local identifier.
    static func createAsset(file: URL) async throws -> String {
        let album = try await album()
        var id = ""
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            req.addResource(with: .photo, fileURL: file, options: nil)
            let ph = req.placeholderForCreatedAsset!
            id = ph.localIdentifier
            PHAssetCollectionChangeRequest(for: album)?.addAssets([ph] as NSArray)
        }
        return id
    }

    static func makeAsset(raw: Bool) async throws -> PHAsset {
        let file = raw ? try makeDNGFile() : try makeJPEGFile()
        let id = try await createAsset(file: file)
        return try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
    }

    /// Runs `body` in an unstructured main-actor task and waits for it with a hard timeout. Returns nil on timeout.
    func hardTimeout<T: Sendable>(_ seconds: TimeInterval, _ body: @escaping @MainActor @Sendable () async -> T) async -> T? {
        let box = ResultBox<T>()
        let exp = expectation(description: "hard timeout")
        Task { @MainActor in
            let v = await body()
            box.set(v)
            exp.fulfill()
        }
        await fulfillment(of: [exp], timeout: seconds)
        return box.value
    }

    func report(_ test: String, _ iter: Int, _ start: Date, _ ok: Bool, _ extra: String = "") {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        print("STALLPROBE \(test) iter=\(iter) ms=\(ms) ok=\(ok)\(extra.isEmpty ? "" : " " + extra)")
    }

    func openOnce(test: String, iter: Int, raw: Bool, asset: PHAsset, timeout: TimeInterval) async {
        let start = Date()
        let gallery = await MainActor.run { GalleryModel() }
        let editor = await MainActor.run { EditorViewModel() }
        struct R: Sendable { let opening: Bool; let has: Bool; let status: String }
        let box = AssetBox(asset)
        let r = await hardTimeout(timeout) { @MainActor @Sendable in
            await gallery.open(box.asset, in: editor)
            return R(opening: gallery.isOpening, has: editor.hasPhoto, status: editor.status)
        }
        guard let r else {
            let opening = await MainActor.run { gallery.isOpening }
            report(test, iter, start, false, "TIMEOUT id=\(asset.localIdentifier) raw=\(raw) isOpening=\(opening)")
            XCTFail("\(test) iter \(iter) stalled > \(timeout)s id=\(asset.localIdentifier) raw=\(raw)")
            return
        }
        let ok = !r.opening && r.has && !r.status.hasPrefix("ERROR")
        report(test, iter, start, ok, ok ? "" : "id=\(asset.localIdentifier) raw=\(raw) status=\(r.status) hasPhoto=\(r.has)")
        if !ok { XCTFail("\(test) iter \(iter) bad result id=\(asset.localIdentifier) status=\(r.status) hasPhoto=\(r.has) opening=\(r.opening)") }
    }

    // MARK: tests

    func testOpenFreshJPEGImmediately() async throws {
        for i in 1...20 {
            let asset = try await Self.makeAsset(raw: false)
            await openOnce(test: "A-jpeg", iter: i, raw: false, asset: asset, timeout: 8)
        }
    }

    func testOpenFreshDNGImmediately() async throws {
        for i in 1...20 {
            let asset = try await Self.makeAsset(raw: true)
            await openOnce(test: "B-dng", iter: i, raw: true, asset: asset, timeout: 15)
        }
    }

    func testOpenAfterChangeNotification() async throws {
        let flag = ChangeFlag()
        PHPhotoLibrary.shared().register(flag)
        defer { PHPhotoLibrary.shared().unregisterChangeObserver(flag) }
        for (label, raw) in [("C-jpeg", false), ("C-dng", true)] {
            for i in 1...10 {
                let before = flag.changes
                let file = raw ? try Self.makeDNGFile() : try Self.makeJPEGFile()
                let id = try await Self.createAsset(file: file)
                let deadline = Date().addingTimeInterval(10)
                while flag.changes == before, Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                if flag.changes == before { print("STALLPROBE \(label) iter=\(i) no-change-notification id=\(id)") }
                let asset = try XCTUnwrap(PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject)
                await openOnce(test: label, iter: i, raw: raw, asset: asset, timeout: raw ? 15 : 8)
            }
        }
    }

    func testRawPhotoKitEditingInputFreshAsset() async throws {
        for i in 1...20 {
            let asset = try await Self.makeAsset(raw: false)
            let start = Date()
            let box = AssetBox(asset)
            let state = ReqState()
            let exp = expectation(description: "editing input")
            Self.request(box, state) { exp.fulfill() }
            await fulfillment(of: [exp], timeout: 8)
            if state.finished {
                report("D-photokit", i, start, true)
            } else {
                if let rid = state.requestID { asset.cancelContentEditingInputRequest(rid) }
                report("D-photokit", i, start, false, "TIMEOUT id=\(asset.localIdentifier) reqID=\(state.requestID.map(String.init) ?? "nil")")
                XCTFail("D iter \(i) PhotoKit editing input stalled id=\(asset.localIdentifier)")
            }
        }
    }

    nonisolated static func request(_ box: AssetBox, _ state: ReqState, done: @escaping @Sendable () -> Void) {
        let options = EditKit.makeOptions()
        let id = box.asset.requestContentEditingInput(with: options) { @Sendable input, _ in
            state.finish(input != nil)
            done()
        }
        state.requestID = id
    }
}

final class AssetBox: @unchecked Sendable { let asset: PHAsset; init(_ a: PHAsset) { asset = a } }
final class ResultBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock(); private var v: T?
    func set(_ x: T) { lock.lock(); v = x; lock.unlock() }
    var value: T? { lock.lock(); defer { lock.unlock() }; return v }
}
final class ReqState: @unchecked Sendable {
    private let lock = NSLock(); private var _finished = false; private var _id: PHContentEditingInputRequestID?
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return _finished }
    var requestID: PHContentEditingInputRequestID? {
        get { lock.lock(); defer { lock.unlock() }; return _id }
        set { lock.lock(); _id = newValue; lock.unlock() }
    }
    func finish(_ ok: Bool) { lock.lock(); _finished = true; lock.unlock() }
}
