import AppKit
import MiraCore
import Testing
@testable import MiraUI

@Suite("Key map")
struct EditorKeyMapTests {
    func key(_ c: String, down: Bool = true, rep: Bool = false, cmd: Bool = false, shift: Bool = false, code: UInt16 = 0) -> EditorKeyEvent {
        EditorKeyEvent(characters: c, keyCode: code, isDown: down, isRepeat: rep, hasCommandOptionControl: cmd, hasShift: shift)
    }
    let normal = EditorKeyContext()

    func act(_ e: EditorKeyEvent, _ ctx: EditorKeyContext? = nil) -> EditorKeyAction? {
        EditorKeyMap.action(for: e, context: ctx ?? normal)
    }

    @Test func tabsOnOneTwoThree() {
        #expect(act(key("1")) == .selectTab(.films))
        #expect(act(key("2")) == .selectTab(.develop))
        #expect(act(key("3")) == .selectTab(.crop))
        #expect(act(key("2", rep: true)) == .swallow)
        // Tabs are not available with the panels hidden.
        #expect(act(key("2"), EditorKeyContext(isImmersive: true)) == .swallow)
    }

    @Test func textFieldsKeepTheirKeys() {
        let typing = EditorKeyContext(isTextInputFocused: true)
        for c in ["1", "2", "3", "f", "c", "[", "]", " "] { #expect(act(key(c), typing) == nil, "\(c)") }
    }

    @Test func modifiersBelongToMenus() {
        for c in ["1", "f", "c", "[", "]", "0"] { #expect(act(key(c, cmd: true)) == nil, "\(c)") }
        #expect(act(key("f", shift: true)) == nil)
    }

    @Test func fullScreenToggleAndEscape() {
        #expect(act(key("f")) == .toggleImmersive)
        #expect(act(key("F")) == .toggleImmersive)
        #expect(act(key("f", rep: true)) == .swallow)
        #expect(act(key("f"), EditorKeyContext(isImmersive: true)) == .toggleImmersive)
        // Not while the crop tool is open (its controls would be hidden).
        #expect(act(key("f"), EditorKeyContext(isCropping: true)) == .swallow)
        #expect(act(key("", code: EditorKeyEvent.escapeKeyCode), EditorKeyContext(isImmersive: true)) == .exitImmersive)
        #expect(act(key("", code: EditorKeyEvent.escapeKeyCode)) == nil) // Esc elsewhere is Cancel's
    }

    @Test func compareIsPressAndHold() {
        #expect(act(key("c")) == .compare(true))
        #expect(act(key("c", rep: true)) == .swallow)
        #expect(act(key("c", down: false), EditorKeyContext(isComparing: true)) == .compare(false))
        // A release with nothing held is not ours.
        #expect(act(key("c", down: false)) == nil)
        // Release still works if focus moved to a text field meanwhile.
        #expect(act(key("c", down: false), EditorKeyContext(isTextInputFocused: true, isComparing: true)) == .compare(false))
        #expect(act(key("c"), EditorKeyContext(isCropping: true)) == .swallow)
    }

    @Test func zoomAndSpace() {
        #expect(act(key("]")) == .zoomIn)
        #expect(act(key("[")) == .zoomOut)
        #expect(act(key("]"), EditorKeyContext(isCropping: true)) == .swallow)
        #expect(act(key(" ")) == .space(true))
        #expect(act(key(" ", rep: true)) == .swallow)
        #expect(act(key(" ", down: false), EditorKeyContext(isSpaceHeld: true)) == .space(false))
        #expect(act(key(" ", down: false)) == nil)
    }

    @Test func nothingWithoutAPhoto() {
        for c in ["1", "f", "c", "[", "]", " "] { #expect(act(key(c), EditorKeyContext(hasPhoto: false)) == nil) }
    }

    @Test func otherKeysPassThrough() {
        #expect(act(key("x")) == nil)
        #expect(act(key("4")) == nil)
    }
}

@MainActor
@Suite("Viewing", .serialized)
struct ViewingModelTests {
    static func makeModel() async throws -> EditorModel {
        let model = try await CropModelTests.makeModel()
        let size = try #require(model.source).extent.size
        #expect(size.width > 2000) // the fixture is bigger than the pane, so there is room to zoom
        model.setViewport(pane: CGSize(width: 1500, height: 1000), fitArea: CGSize(width: 1404, height: 904))
        return model
    }

    @Test func clickZoomsTo100AndBack() async throws {
        let model = try await Self.makeModel()
        #expect(model.zoom.isFit && model.canZoom)
        model.zoomClick(atPane: CGPoint(x: 900, y: 560))
        #expect(model.zoom.scale == 1)
        #expect(model.zoomReadout == "100%")

        // A frame of the visible region arrives, 1:1, sized like the pane at most.
        try await HoverTests.waitFor { model.previewFrame?.placement != nil && model.isPreviewIdle }
        let frame = try #require(model.previewFrame)
        #expect(frame.placement?.scale == 1)
        #expect(frame.pixelSize.width <= 1501 && frame.pixelSize.height <= 1001, "\(frame.pixelSize) \(String(describing: model.source?.extent))")
        let rect = try #require(model.paneRect(of: frame))
        #expect(abs(rect.width - frame.pixelSize.width) < 1e-6) // 1 picture pixel on 1 device pixel

        model.zoomClick(atPane: CGPoint(x: 10, y: 10))
        #expect(model.zoom.isFit)
        #expect(model.zoomReadout == "Fit")
        try await HoverTests.waitFor { model.previewFrame?.placement == nil && model.isPreviewIdle }
        #expect(model.previewFrame?.placement == nil)
        model.cancelWork()
    }

    @Test func panMovesTheRegionAndIsClamped() async throws {
        let model = try await Self.makeModel()
        model.zoomPan(byPane: CGSize(width: 50, height: 50))
        #expect(model.zoom.isFit) // nothing to pan while fitted
        model.zoomClick(atPane: CGPoint(x: 750, y: 500))
        let start = model.zoom.center
        model.zoomPan(byPane: CGSize(width: -100, height: -40))
        #expect(model.zoom.center.x == start.x + 100 && model.zoom.center.y == start.y + 40)
        model.zoomPan(byPane: CGSize(width: -1e7, height: -1e7))
        let vp = try #require(model.zoomViewport)
        #expect(model.zoom.center == CGPoint(x: vp.content.width - 750, y: vp.content.height - 500))
        model.cancelWork()
    }

    @Test func bracketsStepAndClamp() async throws {
        let model = try await Self.makeModel()
        var seen: [Double?] = []
        for _ in 0..<5 { model.perform(.zoomIn); seen.append(model.zoom.scale) }
        #expect(seen == [1, 2, 4, 4, 4]) // the fixture's fit scale is above 50%
        for _ in 0..<5 { model.perform(.zoomOut); seen.append(model.zoom.scale) }
        #expect(Array(seen.suffix(5)) == [2, 1, nil, nil, nil])
        model.zoomToFit()
        #expect(model.zoom.isFit)
        model.cancelWork()
    }

    @Test func steppingAnchorsAtThePointerWhenOverThePhoto() async throws {
        let model = try await Self.makeModel()
        let anchor = CGPoint(x: 1000, y: 620)
        let before = try #require(model.zoomViewport)
        let under = ZoomGeometry.contentPoint(atPane: anchor, state: model.zoom, in: before)
        model.pointerInPane = anchor
        model.perform(.zoomIn)
        let after = ZoomGeometry.contentPoint(atPane: anchor, state: model.zoom, in: before)
        #expect(abs(after.x - under.x) < 0.5 && abs(after.y - under.y) < 0.5)
        model.cancelWork()
    }

    @Test func readoutFadesAfterAMoment() async throws {
        let model = try await Self.makeModel()
        model.perform(.zoomIn)
        #expect(model.zoomReadout != nil)
        try await HoverTests.waitFor(5) { model.zoomReadout == nil }
        #expect(model.zoomReadout == nil)
        model.cancelWork()
    }

    @Test func cropTabDisablesZoomAndResetsIt() async throws {
        let model = try await Self.makeModel()
        model.zoomClick(atPane: CGPoint(x: 750, y: 500))
        #expect(!model.zoom.isFit)
        model.selectTab(.crop)
        #expect(model.zoom.isFit)
        #expect(!model.canZoom)
        model.zoomClick(atPane: CGPoint(x: 750, y: 500))
        model.perform(.zoomIn)
        #expect(model.zoom.isFit)
        model.selectTab(.films)
        #expect(model.canZoom)
        model.cancelWork()
    }

    @Test func aNewCropResetsTheZoom() async throws {
        let model = try await Self.makeModel()
        model.zoomClick(atPane: CGPoint(x: 750, y: 500))
        model.recipe.crop.rect = CropRect(x: 0.1, y: 0.1, w: 0.5, h: 0.5)
        #expect(model.zoom.isFit)
        model.cancelWork()
    }

    @Test func compareKeyHoldsTheOriginalAndReleases() async throws {
        let model = try await Self.makeModel()
        model.recipe.filmID = "fuji-velvia-50"
        try await HoverTests.waitFor { model.isPreviewIdle }
        model.perform(.compare(true))
        #expect(model.showOriginal)
        model.perform(.compare(false))
        #expect(!model.showOriginal)

        // Zoomed: the original is rendered for the same region while held.
        model.zoomClick(atPane: CGPoint(x: 750, y: 500))
        try await HoverTests.waitFor { model.previewFrame?.placement != nil && model.isPreviewIdle }
        let graded = try #require(model.previewFrame)
        model.perform(.compare(true))
        try await HoverTests.waitFor { model.displayedFrame?.id != graded.id && model.isPreviewIdle }
        let original = try #require(model.displayedFrame)
        #expect(original.id != graded.id)
        #expect(original.placement == graded.placement)
        model.perform(.compare(false))
        #expect(model.displayedFrame?.id == model.previewFrame?.id) // back to the edit
        #expect(model.displayedFrame?.id != original.id)
        model.cancelWork()
    }

    @Test func compareDoesNothingInTheCropTab() async throws {
        let model = try await Self.makeModel()
        model.selectTab(.crop)
        model.perform(.compare(true))
        #expect(!model.showOriginal)
        model.cancelWork()
    }

    @Test func spaceAndFullScreenState() async throws {
        let model = try await Self.makeModel()
        model.perform(.space(true))
        #expect(model.isSpaceHeld)
        model.releaseHolds()
        #expect(!model.isSpaceHeld)

        model.perform(.toggleImmersive)
        #expect(model.isImmersive)
        model.perform(.exitImmersive)
        #expect(!model.isImmersive)
        model.perform(.toggleImmersive)
        model.selectTab(.crop) // starting the crop tool shows the panels again
        #expect(!model.isImmersive)
        model.cancelWork()
    }
}
