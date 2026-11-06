import SwiftUI
import MiraCore
import MiraCameraKit
import MiraUI
import XCTest
@testable import Mira

final class FrameBox: @unchecked Sendable {
    var frames: [String: CGRect] = [:]
}

@MainActor
final class LayoutSnapshotTests: XCTestCase {
    /// An editor model with the sample photo open, a stock with ISO and variation choices applied, and thumbnails loaded.
    func makeModel() async -> EditorViewModel {
        let m = EditorViewModel()
        await m.loadSnapshotFixture()
        XCTAssertTrue(m.hasPhoto, "sample fixture failed to load")
        for film in PhotoEngine.filmList {
            m.select(film.id)
            if !m.isoChoices.isEmpty && !m.variationChoices.isEmpty { break }
        }
        for film in m.visibleStocks.prefix(8) { await m.requestThumbnail(film.id) }
        await m.requestThumbnail(nil)
        await m.settleHistogram()
        return m
    }

    static var sample: UIImage {
        let url = Bundle.main.url(forResource: "sample", withExtension: "jpg")!
        return UIImage(contentsOfFile: url.path)!
    }

    /// The photo stand-in: the sample picture aspect-fit in whatever room the layout gives it.
    func photo() -> some View {
        Image(uiImage: Self.sample)
            .resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 2)
    }

    /// Renders the editor layout and returns the frames it reported (stepBar, photo, panel, labels).
    @discardableResult
    func render(_ model: EditorViewModel, tab: EditorTab, device: TestDevice, name: String,
                @ViewBuilder panel: () -> some View) async -> [String: CGRect] {
        let box = FrameBox()
        let view = EditorScaffold(model: model, tab: .constant(tab), onClose: {}, onLayout: { box.frames = $0 }) {
            photo()
        } panel: { panel() }
        await Snapshot.render(view, device: device, name: name)
        return box.frames
    }

    /// Layout facts that hold for every step at every size.
    func assertLayout(_ f: [String: CGRect], device: TestDevice, hidden: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard let bar = f["stepBar"], let photo = f["photo"], let panel = f["panel"] else {
            return XCTFail("missing frames: \(f.keys)", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(bar.maxY, photo.minY + 0.5, "step bar sits above the photo", file: file, line: line)
        XCTAssertLessThanOrEqual(photo.maxY, panel.minY + 1.5, "photo and panel do not intersect", file: file, line: line)
        XCTAssertFalse(photo.intersects(panel.insetBy(dx: 0, dy: 2)), "photo overlaps panel", file: file, line: line)
        XCTAssertGreaterThan(photo.height, device.size.height * 0.30, "photo keeps real room", file: file, line: line)
        XCTAssertLessThanOrEqual(panel.maxY, device.size.height - device.topInset - device.bottomInset + 0.5,
                                 "panel stays on screen", file: file, line: line)
        if hidden { XCTAssertLessThan(panel.height, 40, "hidden panel leaves only its handle", file: file, line: line) }
        else { XCTAssertLessThanOrEqual(panel.height, (device.size.height - device.topInset - device.bottomInset) * 0.55 + 36,
                                        "panel is capped", file: file, line: line) }
    }

    // MARK: Films strip

    func testFilmsStrip() async {
        for d in TestDevice.all {
            let m = await makeModel()
            m.filmsDetail = false
            let shown = await render(m, tab: .films, device: d, name: "films-strip-shown") { FilmsPanel(model: m) }
            assertLayout(shown, device: d, hidden: false)
            // Card titles are not clipped: the strip gets its natural height (title + caption rows below the thumbnail).
            XCTAssertGreaterThan(shown["panel"]!.height, 150, "strip has room for cards")
            m.panelHidden[.films] = true
            let hidden = await render(m, tab: .films, device: d, name: "films-strip-hidden") { FilmsPanel(model: m) }
            assertLayout(hidden, device: d, hidden: true)
            XCTAssertGreaterThan(hidden["photo"]!.height, shown["photo"]!.height + 100, "hiding the panel gives the photo the space")
        }
    }

    // MARK: Films options

    func testFilmsOptions() async {
        for d in TestDevice.all {
            let m = await makeModel()
            m.filmsDetail = true
            let shown = await render(m, tab: .films, device: d, name: "films-options-shown") { FilmsPanel(model: m) }
            assertLayout(shown, device: d, hidden: false)
            // Labels stay on one line, and the VARIATIONS label is not wider than its column.
            for key in ["label.ISO", "label.VARIATIONS", "label.PUSH", "label.SCAN"] {
                guard let l = shown[key] else { XCTFail("no frame for \(key)"); continue }
                XCTAssertLessThan(l.height, 15, "\(key) is one line")
                XCTAssertLessThanOrEqual(l.width, ChipRow<EmptyView>.labelWidth, "\(key) fits its column")
            }
            m.panelHidden[.films] = true
            let hidden = await render(m, tab: .films, device: d, name: "films-options-hidden") { FilmsPanel(model: m) }
            assertLayout(hidden, device: d, hidden: true)
        }
    }

    /// Chip rows scroll their selected chip into view: with the last push step and a toned monochrome film, every row still renders and the labels hold.
    func testFilmsOptionsChipRowsReachSelection() async {
        for d in TestDevice.all {
            let m = await makeModel()
            if let mono = PhotoEngine.filmList.first(where: { f in m.select(f.id); return m.offersToning }) { m.select(mono.id) }
            m.recipe.push = FilmBrowsing.pushSteps.last ?? 0
            m.filmsDetail = true
            let f = await render(m, tab: .films, device: d, name: "films-options-push-max") { FilmsPanel(model: m) }
            assertLayout(f, device: d, hidden: false)
            XCTAssertNotEqual(m.exposureTimeReadout, "No EXIF", "readout is caps like the rest of the UI")
        }
    }

    func testFilmsBackKeepsFilmApplied() async {
        let m = await makeModel()
        let id = m.filmID
        XCTAssertNotNil(id)
        m.filmsDetail = true
        m.filmsDetail = false
        XCTAssertEqual(m.filmID, id)
        XCTAssertEqual(m.selectedStockID, m.selectedStock?.id)
    }

    // MARK: Develop

    func testDevelopCurves() async {
        for d in TestDevice.all {
            let m = await makeModel()
            let shown = await render(m, tab: .develop, device: d, name: "develop-curves-shown") { DevelopPanel(model: m, focus: "curves") }
            assertLayout(shown, device: d, hidden: false)
            m.panelHidden[.develop] = true
            let hidden = await render(m, tab: .develop, device: d, name: "develop-curves-hidden") { DevelopPanel(model: m, focus: "curves") }
            assertLayout(hidden, device: d, hidden: true)
            XCTAssertGreaterThan(hidden["photo"]!.height, shown["photo"]!.height + 100)
        }
    }

    func testDevelopMixerAndHistogramAndDodgeBurn() async {
        for d in TestDevice.all {
            let m = await makeModel()
            let mixer = await render(m, tab: .develop, device: d, name: "develop-mixer-shown") { DevelopPanel(model: m, focus: "mixer") }
            assertLayout(mixer, device: d, hidden: false)
            let plain = await render(m, tab: .develop, device: d, name: "develop-shown") { DevelopPanel(model: m) }
            assertLayout(plain, device: d, hidden: false)
            let dodge = await render(m, tab: .dodgeBurn, device: d, name: "dodgeburn-shown") { CappedScroll { DodgeBurnTab(model: m) } }
            assertLayout(dodge, device: d, hidden: false)
            m.panelHidden[.dodgeBurn] = true
            let dodgeHidden = await render(m, tab: .dodgeBurn, device: d, name: "dodgeburn-hidden") { CappedScroll { DodgeBurnTab(model: m) } }
            assertLayout(dodgeHidden, device: d, hidden: true)
        }
    }

    // MARK: Per-step state and step bar

    func testPanelHiddenIsPerStep() async {
        let m = await makeModel()
        m.panelHidden[.develop] = true
        XCTAssertNil(m.panelHidden[.films])
        XCTAssertEqual(m.panelHidden[.develop], true)
        m.closePhoto()
        XCTAssertTrue(m.panelHidden.isEmpty, "state is per editing session")
    }

    func testStepBarIsFourIconsThatFit() async {
        XCTAssertEqual(EditorTab.allCases.count, 4)
        XCTAssertEqual(EditorTab.allCases.map(\.title), ["Crop", "Films", "Develop", "Dodge & Burn"])
        for tab in EditorTab.allCases { XCTAssertNotNil(UIImage(systemName: tab.symbol), "\(tab.symbol) exists") }
        for d in TestDevice.all {
            let m = await makeModel()
            let f = await render(m, tab: .films, device: d, name: "step-bar") { FilmsPanel(model: m) }
            let bar = f["stepBar"]!
            XCTAssertEqual(bar.width, d.size.width, accuracy: 0.5, "bar spans the width")
            XCTAssertGreaterThanOrEqual(bar.height, 44)
            XCTAssertLessThan(bar.minY, f["photo"]!.minY)
        }
    }

    // MARK: Camera doors (phase C2)

    /// A camera screen stand-in: the photo area above, the door docked at the bottom on the panel cap the camera would give it.
    @discardableResult
    func renderDoor(device: TestDevice, name: String, @ViewBuilder door: () -> some View) async -> [String: CGRect] {
        let box = FrameBox()
        let doorView = door()
        let view = GeometryReader { geo in
            VStack(spacing: 0) {
                self.photo().frame(maxWidth: .infinity, maxHeight: .infinity).reportFrame("photo").clipped()
                FFHairline()
                doorView.reportFrame("panel").layoutPriority(1)
            }
            .environment(\.panelMaxHeight, geo.size.height * 0.5 - 32)
        }
        .coordinateSpace(name: EditorScaffoldSpace.name)
        .onPreferenceChange(EditorFrameKey.self) { frames in MainActor.assumeIsolated { box.frames = frames } }
        await Snapshot.render(view, device: device, name: name)
        return box.frames
    }

    func makeCameraModel() async -> CameraFilmDoorModel {
        let m = CameraFilmDoorModel()
        for film in PhotoEngine.filmList {
            m.select(film.id)
            if !m.isoChoices.isEmpty && !m.variationChoices.isEmpty { break }
        }
        return m
    }

    func assertDoor(_ f: [String: CGRect], device: TestDevice, file: StaticString = #filePath, line: UInt = #line) {
        guard let photo = f["photo"], let panel = f["panel"] else { return XCTFail("missing frames: \(f.keys)", file: file, line: line) }
        XCTAssertLessThanOrEqual(photo.maxY, panel.minY + 1.5, "photo and door do not intersect", file: file, line: line)
        XCTAssertGreaterThan(photo.height, device.size.height * 0.30, "photo keeps real room", file: file, line: line)
        XCTAssertLessThanOrEqual(panel.maxY, device.size.height - device.topInset - device.bottomInset + 0.5, "door stays on screen", file: file, line: line)
    }

    func testCameraFilmDoorStrip() async {
        for d in TestDevice.all {
            let m = await makeCameraModel()
            m.filmsDetail = false
            let f = await renderDoor(device: d, name: "camera-film-door-strip") {
                CameraFilmDoor(model: m, grain: .constant(true))
            }
            assertDoor(f, device: d)
            XCTAssertGreaterThan(f["panel"]!.height, 150, "strip has room for cards")
        }
    }

    func testCameraFilmDoorOptionsHaveGrainRowsAndNoExposureTime() async {
        for d in TestDevice.all {
            let m = await makeCameraModel()
            m.filmsDetail = true
            let f = await renderDoor(device: d, name: "camera-film-door-options") {
                CameraFilmDoor(model: m, grain: .constant(true))
            }
            assertDoor(f, device: d)
            for key in ["label.ISO", "label.PUSH", "label.SCAN"] {
                XCTAssertNotNil(f[key], "\(key) present like the editor")
            }
            XCTAssertNil(f["label.RECIP."], "camera hides the reciprocity row")
            XCTAssertLessThanOrEqual(f["panel"]!.height, (d.size.height - d.topInset - d.bottomInset) * 0.5 + 40, "panel is capped")
            // The GRAIN rows sit at the end of a scrolling panel; scroll-free on a tall screen, else cut by the cap.
            if d.size.height > 800 { XCTAssertNotNil(f["label.FINDER"], "GRAIN rows are in the options panel") }
        }
    }

    /// The GRAIN rows on their own, so they are checked even where the options panel scrolls them out of view.
    func testGrainRowsLayout() async {
        for d in TestDevice.all {
            let m = await makeCameraModel()
            let f = await renderDoor(device: d, name: "camera-grain-rows") {
                GrainRows(model: m, grain: .constant(true)).ffPanel()
            }
            guard let l = f["label.FINDER"] else { XCTFail("no FINDER label"); continue }
            XCTAssertLessThan(l.height, 15, "FINDER is one line")
            XCTAssertLessThanOrEqual(l.width, ChipRow<EmptyView>.labelWidth)
        }
    }

    func testEditorFilmsPanelIsUnchangedByTheRefactor() async {
        let m = await makeModel()
        m.filmsDetail = true
        let f = await render(m, tab: .films, device: .iPhone16Pro, name: "films-options-unchanged") { FilmsPanel(model: m) }
        XCTAssertNil(f["label.FINDER"], "editor has no extra rows")
        XCTAssertNotNil(f["label.ISO"])
        XCTAssertTrue(m.showsExposureTimeControls)
    }

    func testCameraSelectAppliesNativeTexture() async {
        let m = CameraFilmDoorModel(recipe: Recipe())
        let editor = EditorViewModel()
        var pushed: [Recipe] = []
        m.onRecipeChange = { pushed.append($0) }
        guard let film = PhotoEngine.filmList.first else { return XCTFail("no films") }
        m.select(film.id)
        editor.select(film.id)
        XCTAssertEqual(m.filmID, film.id)
        XCTAssertEqual(m.recipe.pipeline, Recipe.currentPipeline)
        XCTAssertEqual(m.recipe, editor.recipe, "same select semantics as the editor")
        XCTAssertEqual(m.recipe.grainAmount, FilmCharacter.nativeSlider, accuracy: 1e-9)
        XCTAssertEqual(pushed.last, m.recipe, "recipe change reaches the finder")
        m.select(nil)
        XCTAssertNil(m.filmID)
        XCTAssertEqual(m.recipe.grainAmount, 0)
        XCTAssertFalse(m.showsExposureTimeControls)
        XCTAssertTrue(m.hasPhoto)
    }

    func testCameraFilmListIsStatic() async {
        let m = CameraFilmDoorModel()
        let epoch = m.thumbEpoch
        await m.requestThumbnail(nil)
        await m.requestThumbnail("x")
        XCTAssertFalse(m.showsThumbnails)
        XCTAssertTrue(m.thumbnails.isEmpty, "requesting a thumbnail does nothing in the camera")
        XCTAssertEqual(m.thumbEpoch, epoch)
        let editor = EditorViewModel()
        XCTAssertTrue(editor.showsThumbnails, "the editor keeps its real thumbnails")
    }
}
