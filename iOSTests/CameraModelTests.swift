import MiraCamera
import MiraCameraKit
import MiraCore
import XCTest
@testable import Mira

@MainActor
final class CameraModelTests: XCTestCase {
    func makeModel(access: LibraryAccess = .full, log: CallRecorder = CallRecorder(),
                   onFrameSaved: @escaping @MainActor (String) -> Void = { _ in }) -> CameraModel {
        let defaults = UserDefaults(suiteName: "mira.camera.tests.\(UUID().uuidString)")!
        return CameraModel(
            printWriter: StubPrintWriter(log: log), renderer: nil, initialRecipe: Recipe(),
            backend: (FakeCaptureDevice(fixtureURL: CameraFixtures.sampleURL), FakeFrameSource(fixtureURL: CameraFixtures.sampleURL)),
            library: StubLibrary(level: access, log: log), baker: StubBaker(),
            requestLibraryAccess: { access },
            settingsStore: CameraSettingsStore(defaults: defaults),
            pendingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("cam-\(UUID().uuidString)"),
            onFrameSaved: onFrameSaved)
    }

    func until(_ what: String, timeout: Double = 5, _ condition: @MainActor () async -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(40))
        }
        XCTFail("timed out waiting for \(what)")
    }

    func testStartReachesRunningWithLenses() async {
        let model = makeModel()
        await model.start()
        await until("running") { model.state == .running }
        XCTAssertEqual(model.authorization, .authorized)
        XCTAssertEqual(model.lenses.map(\.equivalentMM).count, 4)
        XCTAssertEqual(model.selectedLens?.isCrop, false)
        await until("ready") { model.readiness == .ready }
        await model.stop()
        XCTAssertEqual(model.state, .idle)
    }

    func testEVSnapsToThirdsAndClamps() {
        let model = makeModel()
        model.setEV(0.4)
        XCTAssertEqual(model.evBias, 1.0 / 3, accuracy: 1e-9)
        model.setEV(9)
        XCTAssertEqual(model.evBias, 3)
        model.setEV(-9)
        XCTAssertEqual(model.evBias, -3)
    }

    func testLensSelectionAndPinchReadout() async {
        let model = makeModel()
        await model.start()
        await until("lenses") { !model.lenses.isEmpty }
        let crop = model.lenses.first { $0.isCrop }!
        model.selectLens(crop)
        XCTAssertEqual(model.selectedLens, crop)
        XCTAssertEqual(model.zoom, crop.zoomFactor)
        // The pinch starts from the live zoom: a 1.5x spread from the crop lens reads 1.5 x 48 mm.
        model.pinch(scale: 1.5)
        XCTAssertEqual(model.zoom, crop.zoomFactor * 1.5, accuracy: 1e-9)
        XCTAssertEqual(model.pinchMM, Int((Double(crop.equivalentMM) * 1.5).rounded()))
        model.pinchEnded()
        await model.stop()
    }

    func testShutterSavesWithTheUsersRecipe() async {
        let log = CallRecorder()
        let model = makeModel(access: .full, log: log)
        await model.start()
        await until("ready") { model.readiness == .ready && model.state.canCapture }
        var recipe = Recipe(filmID: "kodak-portra-400", exposure: 0.2)
        recipe.grainAmount = 0.4
        model.recipe = recipe
        model.shutter()
        await until("print attached") { await log.attached.count == 1 }
        let attached = await log.attached
        XCTAssertEqual(attached.first?.recipe, recipe, "the saved recipe is the user's, with no finder-only changes")
        XCTAssertEqual(attached.first?.id, "stub-asset")
        XCTAssertEqual(attached.first?.rawBase, false)
        await model.stop()
    }

    func testLimitedAccessShowsTheNotice() async {
        let log = CallRecorder()
        let model = makeModel(access: .limited, log: log)
        await model.start()
        await until("ready") { model.readiness == .ready && model.state.canCapture }
        model.shutter()
        await until("notice") { model.notice != nil }
        XCTAssertEqual(model.notice, CaptureSaver.limitedAccessNotice)
        let created = await log.created
        XCTAssertEqual(created, ["asset", "baked"])
        let attached = await log.attached
        XCTAssertTrue(attached.isEmpty)
        await model.stop()
    }

    /// Auto-add hook: the developed frame's id on full access, the baked copy's (not the original's) on limited.
    func testFrameSavedReportsTheKeptAsset() async {
        for (access, expected) in [(LibraryAccess.full, "stub-asset"), (.limited, "stub-baked")] {
            var saved: [String] = []
            let model = makeModel(access: access, onFrameSaved: { saved.append($0) })
            await model.start()
            await until("ready") { model.readiness == .ready && model.state.canCapture }
            model.shutter()
            await until("frame saved") { !saved.isEmpty }
            XCTAssertEqual(saved, [expected])
            await model.stop()
        }
    }
}
