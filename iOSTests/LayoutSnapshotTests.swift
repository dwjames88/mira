import SwiftUI
import XCTest
@testable import Mira

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
        return m
    }

    func photo() -> some View {
        Image(uiImage: UIImage(named: "sample") ?? Self.sample)
            .resizable().scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 2)
    }

    static var sample: UIImage {
        let url = Bundle.main.url(forResource: "sample", withExtension: "jpg")!
        return UIImage(contentsOfFile: url.path)!
    }

    func legacy(_ model: EditorViewModel, tab: EditorTab, @ViewBuilder panel: () -> some View) -> some View {
        EditorScaffold(model: model, tab: .constant(tab), onClose: {}) { photo() } panel: { panel() }
    }

    func testFilmsStrip() async {
        let m = await makeModel()
        for d in TestDevice.all {
            await Snapshot.render(legacy(m, tab: .films) { FilmsPanel(model: m) }, device: d, name: "films-strip")
        }
    }

    func testFilmsOptions() async {
        let m = await makeModel()
        for d in TestDevice.all {
            await Snapshot.render(legacy(m, tab: .films) { FilmsPanel(model: m, optionsOpen: true) }, device: d, name: "films-options")
        }
    }

    func testDevelopCurves() async {
        let m = await makeModel()
        for d in TestDevice.all {
            // The sheet cannot be hosted offscreen: this lays out what it did, a 380 pt panel over the lower part of the screen.
            let view = ZStack(alignment: .bottom) {
                legacy(m, tab: .develop) { DevelopPanel(model: m) }
                ScrollView { CurvesEditor(model: m).padding(16) }
                    .frame(height: 380)
                    .background(Color(red: 0.082, green: 0.078, blue: 0.059))
                    .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
            }
            await Snapshot.render(view, device: d, name: "develop-curves")
        }
    }

    func testDevelop() async {
        let m = await makeModel()
        for d in TestDevice.all {
            await Snapshot.render(legacy(m, tab: .develop) { DevelopPanel(model: m) }, device: d, name: "develop")
        }
    }
}
