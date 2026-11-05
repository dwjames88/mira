import MiraCore
import MiraUI
import Photos
import SwiftUI
import UIKit
import XCTest
@testable import Mira

private struct InputBox: @unchecked Sendable { let input: PHContentEditingInput }

/// A fake Photos request. `.never` never calls back; `.late` delivers after `delay`; `.twice` delivers
/// synchronously and again asynchronously; `.downloading` reports 30% and 60%, then delivers.
private final class FakeRequester: EditingInputRequesting, @unchecked Sendable {
    typealias Input = PHContentEditingInput
    enum Mode: Sendable { case never, late(Double), twice, downloading }

    private let lock = NSLock()
    private var _starts = 0, _cancels = 0
    private let mode: Mode
    private let box: InputBox
    init(_ mode: Mode, input: InputBox) { self.mode = mode; box = input }

    var starts: Int { lock.withLock { _starts } }
    var cancels: Int { lock.withLock { _cancels } }

    func start(progress: @escaping @Sendable (Double) -> Void,
               completion: @escaping @Sendable (PHContentEditingInput?) -> Void) -> Int {
        let id = lock.withLock { _starts += 1; return _starts }
        let box = box
        let q = DispatchQueue.global()
        switch mode {
        case .never: break
        case .late(let delay):
            q.asyncAfter(deadline: .now() + delay) { completion(box.input) }
        case .twice:
            completion(box.input)
            q.asyncAfter(deadline: .now() + 0.2) { completion(box.input) }
        case .downloading:
            q.asyncAfter(deadline: .now() + 0.15) { progress(0.3) }
            q.asyncAfter(deadline: .now() + 0.6) { progress(0.6) }
            q.asyncAfter(deadline: .now() + 1.1) { completion(box.input) }
        }
        return id
    }

    func cancel(_ requestID: Int) { lock.withLock { _cancels += 1 } }
}

@MainActor
final class OpenBackstopTests: XCTestCase {
    let short = EditingInputPolicy(firstDeliveryTimeout: .milliseconds(400), downloadStallTimeout: .seconds(1), attempts: 2)

    override func setUp() async throws {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        try XCTSkipUnless(s == .authorized || s == .limited, "Photos not authorized (\(s.rawValue))")
    }

    // MARK: helpers

    /// The two newest assets of the "Mira Open Stall Test" album, creating JPEGs there only when fewer exist.
    private func testAssets() async throws -> (PHAsset, PHAsset) {
        let album = try await AssetOpenStallTests.album()
        func newest() -> [PHAsset] {
            let o = PHFetchOptions()
            o.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let r = PHAsset.fetchAssets(in: album, options: o)
            return (0..<min(2, r.count)).map { r.object(at: $0) }
        }
        var found = newest()
        while found.count < 2 {
            _ = try await AssetOpenStallTests.createAsset(file: try AssetOpenStallTests.makeJPEGFile())
            found = newest()
        }
        return (found[0], found[1])
    }

    private func realInput(_ asset: PHAsset) async throws -> InputBox {
        do {
            return InputBox(input: try await EditingInputFetch.fetch(PhotoKitEditingInputRequester(asset: asset)))
        } catch {
            throw XCTSkip("Photos did not hand over the test asset: \(error)")
        }
    }

    private func wait(_ seconds: Double, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func isIdle(_ g: GalleryModel) -> Bool { if case .idle = g.openPhase { true } else { false } }
    private func failedMessage(_ g: GalleryModel) -> String? {
        if case .failed(_, let m) = g.openPhase { m } else { nil }
    }

    private func use(_ editor: EditorViewModel, _ fake: FakeRequester) {
        let policy = short
        editor.makeSession = { AssetEditSession(asset: $0, policy: policy, makeRequester: { _ in fake }) }
    }

    private func useReal(_ editor: EditorViewModel) {
        editor.makeSession = { AssetEditSession(asset: $0) }
    }

    // MARK: tests

    func testNeverDeliversFailsThenLaterTapsWork() async throws {
        let (asset, _) = try await testAssets()
        let input = try await realInput(asset)
        let gallery = GalleryModel(), editor = EditorViewModel()
        let fake = FakeRequester(.never, input: input)
        use(editor, fake)

        let first = Task { await gallery.open(asset, in: editor) }
        let failed = await wait(3) { failedMessage(gallery) != nil }
        XCTAssertTrue(failed, "never-delivering open did not fail within 3 s")
        XCTAssertEqual(failedMessage(gallery), FFOpenFailureCard.defaultMessage)
        XCTAssertFalse(editor.hasPhoto)
        XCTAssertEqual(fake.starts, 2)
        XCTAssertEqual(fake.cancels, 2)
        _ = await first.value

        // A later tap works after a failure.
        useReal(editor)
        let second = Task { await gallery.open(asset, in: editor) }
        let opened = await wait(15) { isIdle(gallery) && editor.hasPhoto }
        XCTAssertTrue(opened, "second open did not succeed")
        _ = await second.value
    }

    func testRetryFromFailedState() async throws {
        let (asset, _) = try await testAssets()
        let input = try await realInput(asset)
        let gallery = GalleryModel(), editor = EditorViewModel()
        use(editor, FakeRequester(.never, input: input))
        let first = Task { await gallery.open(asset, in: editor) }
        let failed = await wait(3) { failedMessage(gallery) != nil }
        XCTAssertTrue(failed)
        _ = await first.value

        // BACK returns to idle; a fresh failure then RETRY with a working requester opens.
        gallery.dismissFailure()
        XCTAssertTrue(isIdle(gallery))
        let again = Task { await gallery.open(asset, in: editor) }
        let failedAgain = await wait(3) { failedMessage(gallery) != nil }
        XCTAssertTrue(failedAgain)
        _ = await again.value

        useReal(editor)
        let retry = Task { await gallery.retry(in: editor) }
        let opened = await wait(15) { isIdle(gallery) && editor.hasPhoto }
        XCTAssertTrue(opened, "retry did not open the asset")
        _ = await retry.value
    }

    func testLateDeliveryAfterTimeoutDoesNotReplaceNewerOpen() async throws {
        let (a, b) = try await testAssets()
        XCTAssertNotEqual(a.localIdentifier, b.localIdentifier)
        let inputA = try await realInput(a)
        let gallery = GalleryModel(), editor = EditorViewModel()
        use(editor, FakeRequester(.late(1.5), input: inputA))

        let openA = Task { await gallery.open(a, in: editor) }
        let failed = await wait(3) { failedMessage(gallery) != nil }
        XCTAssertTrue(failed, "A did not time out")
        _ = await openA.value

        useReal(editor)
        let openB = Task { await gallery.open(b, in: editor) }
        let opened = await wait(15) { isIdle(gallery) && editor.hasPhoto }
        XCTAssertTrue(opened, "B did not open")
        _ = await openB.value

        // Past A's late deliveries (1.5 s after each attempt start).
        try await Task.sleep(for: .seconds(2.5))
        guard case .asset(let session) = editor.editTarget else { return XCTFail("editor lost its asset") }
        XCTAssertEqual(session.asset.localIdentifier, b.localIdentifier)
        XCTAssertEqual(editor.sourcePixelSize.width, CGFloat(b.pixelWidth))
        XCTAssertEqual(editor.sourcePixelSize.height, CGFloat(b.pixelHeight))
        XCTAssertTrue(isIdle(gallery))
        XCTAssertTrue(editor.hasPhoto)
    }

    func testDoubleCompletionOpensOnce() async throws {
        let (asset, _) = try await testAssets()
        let input = try await realInput(asset)
        let gallery = GalleryModel(), editor = EditorViewModel()
        let fake = FakeRequester(.twice, input: input)
        use(editor, fake)
        let t = Task { await gallery.open(asset, in: editor) }
        let opened = await wait(15) { isIdle(gallery) && editor.hasPhoto }
        XCTAssertTrue(opened)
        _ = await t.value
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(isIdle(gallery))
        XCTAssertTrue(editor.hasPhoto)
        XCTAssertFalse(editor.status.hasPrefix("ERROR"), editor.status)
        XCTAssertEqual(fake.starts, 1)
    }

    func testDownloadingProgressShowsInOpenPhase() async throws {
        let (asset, _) = try await testAssets()
        let input = try await realInput(asset)
        let gallery = GalleryModel(), editor = EditorViewModel()
        use(editor, FakeRequester(.downloading, input: input))
        let t = Task { await gallery.open(asset, in: editor) }
        var details: [String] = []
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if case .opening(let d?) = gallery.openPhase, details.last != d { details.append(d) }
            if isIdle(gallery), editor.hasPhoto { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await t.value
        XCTAssertTrue(details.contains("DOWNLOADING FROM ICLOUD \u{00B7} 30%"), "\(details)")
        XCTAssertTrue(details.contains("DOWNLOADING FROM ICLOUD \u{00B7} 60%"), "\(details)")
        XCTAssertTrue(isIdle(gallery))
        XCTAssertTrue(editor.hasPhoto)
    }

    func testPhotosDidNotDeliverMessageMatchesCard() {
        XCTAssertEqual(AssetEditError.photosDidNotDeliver.errorDescription, FFOpenFailureCard.defaultMessage)
    }

    func testOpenFailureSnapshot() async {
        let card = ZStack {
            Color.black.opacity(0.45)
            FFOpenFailureCard(onRetry: {}, onBack: {}).padding(FieldFramesTheme.cells(2))
        }
        let image = await Snapshot.render(card, device: .iPhone16Pro, name: "open-failure")
        XCTAssertGreaterThan(image.size.width, 0)
    }
}
