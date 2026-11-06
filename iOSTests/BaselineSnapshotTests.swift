import MiraCamera
import MiraCameraKit
import MiraCore
import MiraUI
import SwiftUI
import XCTest
@testable import Mira
@testable import MiraCamera

/// Round 3 "before/after" screens that no other iOS test renders whole: the Crop step (editor step 1), the Develop
/// step for a RAW and for a non-RAW photo inside the full editor scaffold, and the camera settings sheet.
/// Same hosting and output rules as `LayoutSnapshotTests` (`MIRA_SNAPSHOT_SET` picks the folder under
/// build/snapshots/ios-tests). Test code only; nothing here changes what the app does.
@MainActor
final class BaselineSnapshotTests: XCTestCase {
    private func makeModel() async -> EditorViewModel {
        let m = EditorViewModel()
        await m.loadSnapshotFixture()
        XCTAssertTrue(m.hasPhoto, "sample fixture failed to load")
        m.select(PhotoEngine.filmList.first?.id)
        for film in m.visibleStocks.prefix(8) { await m.requestThumbnail(film.id) }
        await m.requestThumbnail(nil)
        await m.settleHistogram()
        return m
    }

    private func photo() -> some View {
        Image(uiImage: LayoutSnapshotTests.sample)
            .resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 2)
    }

    // MARK: Editor step 1: Crop

    func testCropStep() async {
        for d in TestDevice.all {
            let m = await makeModel()
            m.beginCrop()
            m.workingCrop.straighten = 4
            let view = EditorScaffold(model: m, tab: .constant(.crop), onClose: {}) {
                photo()
            } panel: {
                CappedScroll { CropTab(model: m) }
            }
            let image = await Snapshot.render(view, device: d, name: "editor-crop-step")
            XCTAssertGreaterThan(image.size.width, 0)
        }
    }

    // MARK: Editor step 3: Develop, RAW and non-RAW, whole screen

    func testDevelopStepNonRaw() async {
        for d in TestDevice.all {
            let m = await makeModel()
            let view = EditorScaffold(model: m, tab: .constant(.develop), onClose: {}) {
                photo()
            } panel: {
                DevelopPanel(model: m, focus: "exposure")
            }
            await Snapshot.render(view, device: d, name: "editor-develop-nonraw")
        }
    }

    func testDevelopStepRaw() async {
        var supported = RawSupportedControls()
        supported.localToneMap = true; supported.luminanceNoiseReduction = true; supported.colorNoiseReduction = true
        supported.sharpness = true; supported.lensCorrection = true
        for d in TestDevice.all {
            let m = await makeModel()
            m.setRawInfoForTesting(asShot: (5200, 8), supported: supported)
            let view = EditorScaffold(model: m, tab: .constant(.develop), onClose: {}) {
                photo()
            } panel: {
                DevelopPanel(model: m, focus: "temperature")
            }
            await Snapshot.render(view, device: d, name: "editor-develop-raw")
        }
    }

    // MARK: Camera settings sheet

    func testCameraSettingsSheet() async {
        let log = CallRecorder()
        let model = CameraModel(
            printWriter: StubPrintWriter(log: log), renderer: nil, initialRecipe: Recipe(),
            backend: (FakeCaptureDevice(fixtureURL: CameraFixtures.sampleURL), FakeFrameSource(fixtureURL: CameraFixtures.sampleURL)),
            library: StubLibrary(level: .full, log: log), baker: StubBaker(),
            settingsStore: CameraSettingsStore(defaults: UserDefaults(suiteName: "mira.camera.settings.snap.\(UUID().uuidString)")!),
            pendingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("cam-\(UUID().uuidString)"))
        for d in TestDevice.all {
            await Snapshot.render(CameraSettingsSheet(model: model), device: d, name: "camera-settings-sheet")
        }
    }
}
