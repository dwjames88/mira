import AppKit
import CoreImage
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

@MainActor
@Suite("Dodge and burn tool", .serialized)
struct DodgeBurnUITests {
    /// A 400 x 300 mid-grey photo with a 1200 x 800 pane (fit area 1152 x 752): the picture is shown at
    /// 2.507 device pixels per picture pixel, centred on pane point (600, 400).
    static func model(gray: CGFloat = 0.4) async throws -> EditorModel {
        let library = try FilmLibrary(directory: SnapshotTests.root.appendingPathComponent("Films"))
        let model = EditorModel(library: library, presetStore: PresetModelTests.tempStore())
        let c = CIColor(red: gray, green: gray, blue: gray, alpha: 1, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        model.setSource(CIImage(color: c).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 300)))
        try await HoverTests.waitFor { model.displayedFrame != nil }
        model.setCanvas(pixels: CGSize(width: 1152, height: 752))
        model.setViewport(pane: CGSize(width: 1200, height: 800), fitArea: CGSize(width: 1152, height: 752))
        try await settle(model)
        return model
    }

    static func settle(_ model: EditorModel) async throws {
        try await Task.sleep(for: .milliseconds(20))
        try await HoverTests.waitFor { model.isPreviewIdle }
    }

    static let center = CGPoint(x: 600, y: 400)

    /// Paints a stroke from `from` to `to` in `steps` moves.
    static func drag(_ model: EditorModel, from: CGPoint, to: CGPoint, steps: Int = 6, flipped: Bool = false) {
        #expect(model.beginPaintStroke(atPane: from, flipped: flipped))
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            model.continuePaintStroke(atPane: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t))
        }
        model.endPaintStroke()
    }

    static func luma(_ model: EditorModel, _ x: Double, _ y: Double) throws -> Double {
        let frame = try #require(model.previewFrame)
        let c = try #require(frame.color(atNormalized: CGPoint(x: x, y: y)))
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    @Test func paintingAStrokeChangesThePreviewUnderIt() async throws {
        let model = try await Self.model()
        let before = try Self.luma(model, 0.5, 0.5)
        let farBefore = try Self.luma(model, 0.05, 0.05)
        model.setPaint(\.size, 0.2)
        model.setPaint(\.flow, 1)
        model.setPaint(\.strength, 1)
        model.setDodgeBurnTool(true)
        #expect(model.dodgeBurnTool.isActive && model.tab == .develop)
        Self.drag(model, from: CGPoint(x: 560, y: 400), to: CGPoint(x: 640, y: 400))
        try await Self.settle(model)
        #expect(model.recipe.dodgeBurn.strokes.count == 1)
        #expect(try Self.luma(model, 0.5, 0.5) > before + 0.05)
        #expect(abs(try Self.luma(model, 0.05, 0.05) - farBefore) < 0.002)
        model.cancelWork()
    }

    @Test func aStrokeIsOneRecipeChange() async throws {
        let model = try await Self.model()
        model.setDodgeBurnTool(true)
        #expect(!model.hasEdits)
        #expect(model.beginPaintStroke(atPane: Self.center))
        for i in 1...10 { model.continuePaintStroke(atPane: CGPoint(x: 600 + Double(i) * 8, y: 400)) }
        // Still being painted: shown in the preview, not yet an edit.
        #expect(model.dodgeBurnTool.liveStroke?.points.count ?? 0 > 3)
        #expect(!model.hasEdits && model.recipe.dodgeBurn.isIdentity)
        model.endPaintStroke()
        #expect(model.dodgeBurnTool.liveStroke == nil)
        #expect(model.hasEdits && model.recipe.dodgeBurn.strokes.count == 1)
        #expect(model.recipe.dodgeBurn.strokes[0].points.count > 3)
        // The brush's size is relative to the short side, so it is a small fraction.
        #expect(model.recipe.dodgeBurn.strokes[0].size == model.dodgeBurnTool.brush.size)
        model.cancelWork()
    }

    @Test func optionFlipsDodgeAndBurn() async throws {
        let model = try await Self.model(gray: 0.5)
        model.setPaint(\.size, 0.25)
        model.setPaint(\.flow, 1)
        model.setPaint(\.strength, 1)
        model.setDodgeBurnTool(true)
        let before = try Self.luma(model, 0.5, 0.5)
        Self.drag(model, from: CGPoint(x: 580, y: 400), to: CGPoint(x: 620, y: 400), flipped: true)
        try await Self.settle(model)
        #expect(model.recipe.dodgeBurn.strokes.last?.mode == .burn)
        #expect(model.dodgeBurnTool.brush.mode == .dodge)   // only that stroke flipped
        #expect(try Self.luma(model, 0.5, 0.5) < before - 0.05)
        // The cursor follows the Option key.
        model.setPaintFlipping(true)
        #expect(model.effectiveBrushMode == .burn)
        model.setPaintFlipping(false)
        #expect(model.effectiveBrushMode == .dodge)
        // Erase does not flip.
        model.setPaint(\.mode, .erase)
        model.setPaintFlipping(true)
        #expect(model.effectiveBrushMode == .erase)
        model.cancelWork()
    }

    @Test func keysChangeBrushSizeToggleOverlayAndLeaveTheTool() async throws {
        let model = try await Self.model()
        let context = EditorKeyContext(isDodgeBurn: true)
        func action(_ chars: String, code: UInt16 = 0, repeatKey: Bool = false, command: Bool = false) -> EditorKeyAction? {
            EditorKeyMap.action(for: EditorKeyEvent(characters: chars, keyCode: code, isRepeat: repeatKey,
                                                    hasCommandOptionControl: command, hasCommandOnly: command), context: context)
        }
        #expect(action("]") == .brushSize(1) && action("[") == .brushSize(-1))
        #expect(action("]", repeatKey: true) == .brushSize(1))     // holding the key keeps growing the brush
        #expect(action("o") == .toggleMaskOverlay && action("o", repeatKey: true) == .swallow)
        #expect(action("", code: EditorKeyEvent.escapeKeyCode) == .exitDodgeBurn)
        #expect(action("=", command: true) == .zoomIn && action("-", command: true) == .zoomOut)
        // Outside the tool nothing changes: brackets zoom, O is not ours, Esc leaves full screen only.
        let outside = EditorKeyContext(isImmersive: true)
        #expect(EditorKeyMap.action(for: EditorKeyEvent(characters: "]"), context: outside) == .zoomIn)
        #expect(EditorKeyMap.action(for: EditorKeyEvent(characters: "o"), context: outside) == nil)
        #expect(EditorKeyMap.action(for: EditorKeyEvent(characters: "=", hasCommandOptionControl: true, hasCommandOnly: true),
                                    context: outside) == nil)
        #expect(EditorKeyMap.action(for: EditorKeyEvent(characters: "", keyCode: EditorKeyEvent.escapeKeyCode), context: outside)
                == .exitImmersive)

        model.setDodgeBurnTool(true)
        let size = model.dodgeBurnTool.brush.size
        model.perform(.brushSize(1))
        #expect(model.dodgeBurnTool.brush.size > size)
        model.perform(.brushSize(-1)); model.perform(.brushSize(-1))
        #expect(model.dodgeBurnTool.brush.size < size)
        for _ in 0..<80 { model.perform(.brushSize(1)) }
        #expect(model.dodgeBurnTool.brush.size == DodgeBurnStroke.sizeRange.upperBound)
        for _ in 0..<200 { model.perform(.brushSize(-1)) }
        #expect(model.dodgeBurnTool.brush.size == DodgeBurnStroke.sizeRange.lowerBound)
        model.perform(.toggleMaskOverlay)
        #expect(model.dodgeBurnTool.maskOverlay)
        model.perform(.toggleMaskOverlay)
        #expect(!model.dodgeBurnTool.maskOverlay)
        model.perform(.exitDodgeBurn)
        #expect(!model.dodgeBurnTool.isActive)
        model.cancelWork()
    }

    @Test func leavingTheTabOrStartingACropClosesTheTool() async throws {
        let model = try await Self.model()
        model.setDodgeBurnTool(true)
        model.selectTab(.films)
        #expect(!model.dodgeBurnTool.isActive)
        model.setDodgeBurnTool(true)
        #expect(model.tab == .develop && model.dodgeBurnTool.isActive)
        model.selectTab(.crop)
        #expect(!model.dodgeBurnTool.isActive && model.isCropping)
        model.cancelCrop()
        #expect(!model.dodgeBurnTool.isActive)
        model.setDodgeBurnTool(true)
        #expect(!model.dodgeBurnTool.isActive || !model.isCropping)
        model.cancelWork()
    }

    @Test func maskOverlayWashesThePaintedAreaRed() async throws {
        let model = try await Self.model(gray: 0.4)
        model.setPaint(\.size, 0.3)
        model.setPaint(\.flow, 1)
        model.setDodgeBurnTool(true)
        Self.drag(model, from: CGPoint(x: 580, y: 400), to: CGPoint(x: 620, y: 400))
        try await Self.settle(model)
        func rgb(_ x: Double, _ y: Double) throws -> (r: Double, g: Double, b: Double) {
            let frame = try #require(model.previewFrame)
            return try #require(frame.color(atNormalized: CGPoint(x: x, y: y)))
        }
        let plain = try rgb(0.5, 0.5), plainFar = try rgb(0.05, 0.05)
        model.setMaskOverlay(true)
        try await Self.settle(model)
        let wash = try rgb(0.5, 0.5), washFar = try rgb(0.05, 0.05)
        #expect(wash.r > wash.b + 0.2 && wash.r > plain.r)
        #expect(abs(washFar.r - plainFar.r) < 0.002 && abs(washFar.b - plainFar.b) < 0.002)
        // The overlay only shows while the tool is open.
        model.setDodgeBurnTool(false)
        try await Self.settle(model)
        let closed = try rgb(0.5, 0.5)
        #expect(abs(closed.r - closed.b) < 0.05)
        model.setDodgeBurnTool(true)
        try await Self.settle(model)
        let again = try rgb(0.5, 0.5)
        #expect(again.r > again.b + 0.15, "closed \(closed) again \(again) wash \(wash)")
        model.cancelWork()
    }

    @Test func strokeListEditsSelectedStrokes() async throws {
        let model = try await Self.model()
        model.setDodgeBurnTool(true)
        Self.drag(model, from: CGPoint(x: 500, y: 400), to: CGPoint(x: 560, y: 400))
        model.setPaint(\.mode, .burn)
        Self.drag(model, from: CGPoint(x: 640, y: 400), to: CGPoint(x: 700, y: 400))
        let first = model.recipe.dodgeBurn.strokes[0], second = model.recipe.dodgeBurn.strokes[1]
        #expect(first.mode == .dodge && second.mode == .burn)

        model.selectStroke(first.id)
        #expect(model.paintSettings.id == first.id && model.paintSettings.mode == .dodge)
        model.setPaint(\.strength, 0.9)
        model.setPaint(\.range, .highlights)
        #expect(model.recipe.dodgeBurn.strokes[0].strength == 0.9 && model.recipe.dodgeBurn.strokes[0].range == .highlights)
        #expect(model.recipe.dodgeBurn.strokes[0].points == first.points)
        #expect(model.dodgeBurnTool.brush.strength != 0.9)                 // the brush is untouched
        // Painting goes back to the brush.
        Self.drag(model, from: CGPoint(x: 600, y: 500), to: CGPoint(x: 640, y: 500))
        #expect(model.dodgeBurnTool.selectedStrokeID == nil && model.recipe.dodgeBurn.strokes.count == 3)

        model.toggleStrokeHidden(second.id)
        #expect(model.recipe.dodgeBurn.strokes[1].hidden)
        model.toggleStrokeHidden(second.id)
        #expect(!model.recipe.dodgeBurn.strokes[1].hidden)
        model.selectStroke(second.id)
        model.deleteStroke(second.id)
        #expect(model.recipe.dodgeBurn.strokes.count == 2 && model.dodgeBurnTool.selectedStrokeID == nil)
        // RESET keeps the strokes; CLEAR ALL removes them.
        model.reset()
        #expect(model.recipe.dodgeBurn.strokes.count == 2)
        model.clearAllStrokes()
        #expect(model.recipe.dodgeBurn.isIdentity && !model.hasEdits)
        model.cancelWork()
    }

    @Test func paintingIsRefusedOffThePictureOrWithTheToolClosed() async throws {
        let model = try await Self.model()
        #expect(!model.beginPaintStroke(atPane: Self.center))          // tool closed
        model.setDodgeBurnTool(true)
        #expect(!model.beginPaintStroke(atPane: CGPoint(x: 5, y: 5)))   // letterbox, off the picture
        #expect(model.beginPaintStroke(atPane: Self.center))
        model.endPaintStroke()
        model.cancelWork()
    }

    @Test func paneToSourceFollowsTheCrop() async throws {
        let model = try await Self.model()
        let mid = try #require(model.strokePoint(atPane: Self.center))
        #expect(abs(mid.x - 0.5) < 0.01 && abs(mid.y - 0.5) < 0.01)
        let corner = try #require(model.strokePoint(atPane: CGPoint(x: 600 - 501, y: 400 - 376 + 1)))
        #expect(corner.x < 0.01 && corner.y < 0.01)
        // The right half of the picture fills the frame: the centre of the pane is now x = 0.75.
        model.recipe.crop.rect = CropRect(x: 0.5, y: 0, w: 0.5, h: 1)
        model.setViewport(pane: CGSize(width: 1200, height: 800), fitArea: CGSize(width: 1152, height: 752))
        let cropped = try #require(model.strokePoint(atPane: Self.center))
        #expect(abs(cropped.x - 0.75) < 0.01 && abs(cropped.y - 0.5) < 0.01)
        // The brush grows on screen with the zoom: the picture is the same height, so the radius is the same.
        let r = try #require(model.brushRadiusInPane(size: 0.1))
        #expect(abs(r - 0.1 * 300 / 2 * 2.507) < 1)
        model.cancelWork()
    }

    @Test func presetsKeepThePhotosStrokes() async throws {
        let model = try await Self.model()
        model.setDodgeBurnTool(true)
        Self.drag(model, from: CGPoint(x: 560, y: 400), to: CGPoint(x: 640, y: 400))
        model.recipe.contrast = 0.3
        let strokes = model.recipe.dodgeBurn
        let preset = try model.saveCurrentAsPreset(nickname: "Painted")
        #expect(preset.recipe.dodgeBurn.isIdentity)
        model.recipe = Recipe(contrast: -0.2, dodgeBurn: strokes)
        model.applyPreset(preset.id)
        #expect(model.recipe.contrast == 0.3)
        #expect(model.recipe.dodgeBurn == strokes)
        #expect(model.isApplied(preset))
        model.cancelWork()
    }

    @Test func savePresetSheetSaysStrokesStayWithThePhoto() {
        #expect(SavePresetSheet.keepsNote == "Presets keep the film and develop settings; dodge & burn strokes stay with the photo.")
    }

    /// `build/snapshots/dodgeburn-panel-dark.png` / `-light.png` (the DEVELOP panel with the tool open and a
    /// stroke selected), `dodgeburn-editor-dark.png` (the editor with the tool open) and
    /// `dodgeburn-mask-overlay-dark.png` (the canvas with the mask overlay on).
    @Test func snapshots() async throws {
        FieldFramesTheme.registerFonts()
        let model = try await SnapshotTests.makeModel()
        model.setCanvas(pixels: CGSize(width: 1152, height: 752))
        model.setViewport(pane: CGSize(width: 1000, height: 700), fitArea: CGSize(width: 952, height: 652))
        model.recipe.filmID = "kodak-portra-400"
        model.selectTab(.develop)
        model.setDodgeBurnTool(true)
        model.setPaint(\.size, 0.12)
        model.setPaint(\.flow, 0.6)
        // A dodge across the middle, a burn at the left, a hidden erase at the right.
        Self.drag(model, from: CGPoint(x: 400, y: 330), to: CGPoint(x: 600, y: 300), steps: 24)
        model.setPaint(\.mode, .burn)
        model.setPaint(\.range, .shadows)
        model.setPaint(\.strength, 0.8)
        Self.drag(model, from: CGPoint(x: 250, y: 450), to: CGPoint(x: 330, y: 520), steps: 16)
        model.setPaint(\.mode, .dodge)
        model.setPaint(\.range, .highlights)
        model.setPaint(\.lumaRange, LumaRange(low: 0.3, high: 0.9, softness: 0.1))
        Self.drag(model, from: CGPoint(x: 640, y: 420), to: CGPoint(x: 720, y: 380), steps: 12)
        model.setPaint(\.lumaRange, nil)
        model.toggleStrokeHidden(model.recipe.dodgeBurn.strokes[2].id)
        model.selectStroke(model.recipe.dodgeBurn.strokes[1].id)
        try await Self.settle(model)
        await model.refreshHistogramNow()
        for scheme in [ColorScheme.dark, .light] {
            let tag = scheme == .dark ? "dark" : "light"
            try SnapshotTests.writePNG(
                DevelopPanel(model: model).frame(width: 320, height: 2100).foregroundStyle(FieldFramesTheme.paper),
                size: CGSize(width: 320, height: 2100), scheme: scheme, name: "dodgeburn-panel-\(tag)")
        }
        let size = CGSize(width: 1280, height: 800)
        try SnapshotTests.writePNG(EditorView(model: model), size: size, scheme: .dark, name: "dodgeburn-editor-dark")
        model.setMaskOverlay(true)
        try await Self.settle(model)
        try SnapshotTests.writePNG(EditorView(model: model), size: size, scheme: .dark, name: "dodgeburn-mask-overlay-dark")
        model.cancelWork()
    }
}
