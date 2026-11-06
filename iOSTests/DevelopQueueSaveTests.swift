import CoreImage
import XCTest
@testable import Mira

@MainActor
final class DevelopQueueSaveTests: XCTestCase {
    private struct Boom: Error {}
    private var suites: [String] = []

    private func makeStore(_ ids: [String]) -> DevelopStore {
        let name = "DevelopQueueSaveTests.\(UUID().uuidString)"
        suites.append(name)
        let store = DevelopStore(defaults: UserDefaults(suiteName: name)!, key: "q")
        for id in ids.reversed() { store.add(id) }   // ids[0] ends up newest
        return store
    }

    private func makeModel(store: DevelopStore) -> EditorViewModel {
        let model = EditorViewModel()
        model.developStore = store
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        model.present(LoadedSource(image: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, size: CGSize(width: 8, height: 8)),
                      originalID: nil)
        return model
    }

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites = []
        super.tearDown()
    }

    func testInPlaceSaveRemovesTheOriginal() async {
        let store = makeStore(["a", "b", "c"])
        let model = makeModel(store: store)
        model.inPlaceAssetIDForTesting = "b"
        model.saveWriter = { target, _ in
            XCTAssertEqual(target, .inPlace("b")); return nil
        }
        await model.save()
        XCTAssertEqual(store.queue.ids, ["a", "c"])
    }

    func testNewAssetSaveRemovesOriginalAndCreated() async {
        let store = makeStore(["a", "b", "new", "c"])
        let model = makeModel(store: store)
        let image = CIImage(color: .gray).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        model.present(LoadedSource(image: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, size: CGSize(width: 8, height: 8)),
                      originalID: "b")
        model.saveWriter = { target, _ in
            XCTAssertEqual(target, .newAsset(original: "b")); return "new"
        }
        await model.save()
        XCTAssertEqual(store.queue.ids, ["a", "c"])
    }

    func testNewAssetWithUnknownOriginalRemovesOnlyCreated() async {
        let store = makeStore(["a", "new"])
        let model = makeModel(store: store)
        model.saveWriter = { _, _ in "new" }
        await model.save()
        XCTAssertEqual(store.queue.ids, ["a"])
    }

    func testFailedSaveLeavesTheQueueUnchanged() async {
        let store = makeStore(["a", "b"])
        let model = makeModel(store: store)
        model.inPlaceAssetIDForTesting = "a"
        model.saveWriter = { _, _ in throw Boom() }
        await model.save()
        XCTAssertEqual(store.queue.ids, ["a", "b"])
        XCTAssertTrue(model.status.hasPrefix("SAVE FAILED"))
    }

    func testCancelledSaveLeavesTheQueueUnchanged() async {
        let store = makeStore(["a", "b"])
        let model = makeModel(store: store)
        model.inPlaceAssetIDForTesting = "a"
        model.saveWriter = { _, _ in throw CancellationError() }
        await model.save()
        XCTAssertEqual(store.queue.ids, ["a", "b"])
    }

    func testOtherQueuedIDsAreUntouchedAndOrderKept() async {
        let store = makeStore(["x", "y", "z", "w"])
        let model = makeModel(store: store)
        model.inPlaceAssetIDForTesting = "y"
        model.saveWriter = { _, _ in nil }
        await model.save()
        XCTAssertEqual(store.queue.ids, ["x", "z", "w"])
        XCTAssertFalse(store.contains("y"))
    }
}
