import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

@MainActor
@Suite("Tone controls UI", .serialized)
struct ToneControlsUITests {
    private static var specs: [SliderSpec] { DevelopPanel.toneColor.flatMap(\.specs) }

    @Test func sectionsAndSlidersAreInOrder() {
        let groups = DevelopPanel.toneColor
        #expect(groups.map(\.title) == ["Light", "Presence", "Color"])
        #expect(groups[0].specs.map(\.id) == ["exposure", "contrast", "highlights", "shadows", "whites", "blacks"])
        #expect(groups[1].specs.map(\.id) == ["texture", "clarity", "vibrance", "saturation"])
        #expect(groups[2].specs.map(\.id) == ["warmth", "tint"])
        #expect(groups[2].specs.first?.label == "Temperature")
    }

    @Test func everyNewSliderEditsAndResetsThroughTheModel() async throws {
        let model = try await GradeModelTests.model(color: (0.5, 0.5, 0.5))
        let ids = ["highlights", "shadows", "whites", "blacks", "texture", "clarity", "vibrance"]
        #expect(!model.canReset && !model.hasEdits)
        for id in ids {
            let spec = try #require(Self.specs.first { $0.id == id })
            #expect(spec.range == -1...1 && spec.defaultValue == 0)
            model.recipe[keyPath: spec.keyPath] = 0.5
            #expect(model.canReset && model.hasEdits, "\(id)")
            model.reset()
            #expect(model.recipe[keyPath: spec.keyPath] == 0 && !model.canReset, "\(id)")
        }
        model.recipe.blacks = -0.3
        model.recipe.filmID = "kodak-portra-400"
        model.reset()
        #expect(model.recipe.blacks == 0 && model.recipe.filmID == "kodak-portra-400")
        model.recipe.clarity = 0.2
        model.resetAll()
        #expect(model.recipe == .neutral)
        model.cancelWork()
    }

    /// `build/snapshots/editor-develop-panel-dark.png` / `-light.png`: the whole Develop panel.
    @Test func developPanelSnapshots() async throws {
        FieldFramesTheme.registerFonts()
        let model = try await SnapshotTests.makeModel()
        model.recipe.highlights = -0.4
        model.recipe.shadows = 0.5
        model.recipe.clarity = 0.3
        model.recipe.vibrance = 0.25
        for scheme in [ColorScheme.dark, .light] {
            try SnapshotTests.writePNG(
                DevelopPanel(model: model).frame(width: 320, height: 1500).foregroundStyle(FieldFramesTheme.paper),
                size: CGSize(width: 320, height: 1500), scheme: scheme,
                name: "editor-develop-panel-\(scheme == .dark ? "dark" : "light")")
        }
        model.cancelWork()
    }
}
