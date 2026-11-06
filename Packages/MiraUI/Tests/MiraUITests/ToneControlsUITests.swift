import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

@MainActor
@Suite("Tone controls UI", .serialized)
struct ToneControlsUITests {
    static var allSupported: RawSupportedControls {
        var s = RawSupportedControls()
        s.localToneMap = true; s.luminanceNoiseReduction = true; s.colorNoiseReduction = true
        s.sharpness = true; s.lensCorrection = true
        return s
    }

    private static var specs: [SliderSpec] { DevelopPanel.sections.flatMap(\.specs) }

    @Test func sectionsAndSlidersAreInOrder() {
        let sections = DevelopPanel.sections
        #expect(sections.map(\.section) == DevelopSection.allCases)
        #expect(sections.map(\.section.title) == ["Light", "White balance", "Color", "Detail", "Lens", "Film", "Frame"])
        func ids(_ s: DevelopSection) -> [String] { sections.first { $0.section == s }!.sliderIDs }
        #expect(ids(.light) == ["exposure", "contrast", "highlights", "shadows", "whites", "blacks",
                                "boost", "highlightRecovery", "localToneMap"])
        #expect(ids(.whiteBalance).isEmpty)
        #expect(ids(.color) == ["vibrance", "saturation"])
        #expect(ids(.detail) == ["texture", "clarity", "sharpness", "luminanceNoise", "colorNoise"])
        #expect(ids(.lens) == ["vignette"])
        #expect(ids(.film) == ["grain", "grainSize", "halation", "halationRadius", "bloom"])
        #expect(ids(.frame) == ["borderWidth"])
        // The pipeline warmth / tint pair is gone from the data: white balance is its own control.
        #expect(!Self.specs.contains { $0.id == "warmth" || $0.id == "tint" })
        #expect(Set(sections.flatMap(\.sliderIDs)).count == sections.flatMap(\.sliderIDs).count)
    }

    @Test func rawOnlySlidersAppearInTheirFunctionalSections() throws {
        let model = EditorModel(library: try FilmVariantTests.makeLibrary())
        func shown(_ s: DevelopSection) -> [String] {
            let v = model.rawControlVisibility
            return DevelopPanel.sections.first { $0.section == s }!.rawSpecs.filter { $0.isShown(v) }.map(\.id)
        }
        for s in DevelopSection.allCases { #expect(shown(s).isEmpty) }
        model.rawSession.isRaw = true
        model.rawSession.supported = Self.allSupported
        #expect(shown(.light) == ["boost", "highlightRecovery", "localToneMap"])
        #expect(shown(.detail) == ["sharpness", "luminanceNoise", "colorNoise"])
        #expect(shown(.lens).isEmpty && model.rawControlVisibility.lensCorrection)
        model.rawSession.supported = RawSupportedControls()
        #expect(shown(.light) == ["boost", "highlightRecovery"])
        #expect(shown(.detail).isEmpty && !model.rawControlVisibility.lensCorrection)
    }

    @Test func resetClearsRawSettingsAndWhiteBalance() async throws {
        let model = try await GradeModelTests.model(color: (0.5, 0.5, 0.5))
        model.recipe.raw.temperature = 4800
        model.recipe.raw.sharpnessAmount = 0.4
        model.recipe.warmth = 0.3
        #expect(model.canReset)
        model.reset()
        #expect(model.recipe.raw.isIdentity && model.recipe.warmth == 0)
        #expect(!model.canReset)
        model.cancelWork()
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

    /// `build/snapshots/editor-develop-panel-dark.png` / `-light.png` (a JPEG) and `editor-develop-panel-raw-*.png`
    /// (a fake camera-raw session with every control supported): the whole Develop panel.
    @Test func developPanelSnapshots() async throws {
        FieldFramesTheme.registerFonts()
        let model = try await SnapshotTests.makeModel()
        model.recipe.highlights = -0.4
        model.recipe.shadows = 0.5
        model.recipe.clarity = 0.3
        model.recipe.vibrance = 0.25
        model.recipe.warmth = 0.2
        model.recipe.borderEnabled = true
        func write(_ tag: String) throws {
            for scheme in [ColorScheme.dark, .light] {
                try SnapshotTests.writePNG(
                    DevelopPanel(model: model).frame(width: 320, height: 2300).foregroundStyle(FieldFramesTheme.paper),
                    size: CGSize(width: 320, height: 2300), scheme: scheme,
                    name: "editor-develop-panel-\(tag)\(scheme == .dark ? "dark" : "light")")
            }
        }
        try write("")
        model.rawSession.isRaw = true
        model.rawSession.asShot = (5200, 8)
        model.rawSession.supported = Self.allSupported
        model.recipe.warmth = 0
        model.recipe.raw.temperature = 6100
        try write("raw-")
        model.cancelWork()
    }
}
