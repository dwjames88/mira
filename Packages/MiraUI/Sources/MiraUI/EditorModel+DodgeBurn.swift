import CoreGraphics
import Foundation
import MiraCore

/// The dodge and burn tool: opening and closing it, turning pointer positions into stroke points,
/// painting (the live stroke, then one recipe change per finished stroke), and the stroke list.
extension EditorModel {
    // MARK: Tool

    /// Opens or closes the brush tool. It lives on the DEVELOP tab: opening it selects that tab.
    public func setDodgeBurnTool(_ on: Bool) {
        let tool = dodgeBurnTool
        guard on != tool.isActive else { return }
        if on {
            guard source != nil, !isCropping else { return }
            endHover()
            showOriginal = false
            if tab != .develop { selectTab(.develop) }
            tool.isActive = true
        } else {
            endLiveStroke()
            tool.isActive = false
            tool.isFlipping = false
        }
        if tool.maskOverlay { schedulePreview() }
    }

    public func toggleDodgeBurnTool() { setDodgeBurnTool(!dodgeBurnTool.isActive) }

    public func setMaskOverlay(_ on: Bool) {
        guard on != dodgeBurnTool.maskOverlay else { return }
        dodgeBurnTool.maskOverlay = on
        if dodgeBurnTool.isActive { schedulePreview() }
    }

    /// True when the preview should wash the masks red.
    var showsMaskOverlay: Bool { dodgeBurnTool.isActive && dodgeBurnTool.maskOverlay }

    /// Forgets everything tied to the previous photo (called when the source changes).
    func resetDodgeBurnTool() {
        let tool = dodgeBurnTool
        tool.liveStroke = nil
        tool.selectedStrokeID = nil
        tool.isActive = false
        tool.isFlipping = false
    }

    // MARK: Settings (the brush, or the selected stroke)

    /// The stroke being edited: the selected one, else the brush.
    public var paintSettings: DodgeBurnStroke {
        get {
            if let id = dodgeBurnTool.selectedStrokeID, let s = recipe.dodgeBurn.strokes.first(where: { $0.id == id }) {
                return s
            }
            return dodgeBurnTool.brush
        }
        set { setPaintSettings(newValue) }
    }

    private func setPaintSettings(_ new: DodgeBurnStroke) {
        if let id = dodgeBurnTool.selectedStrokeID, let i = recipe.dodgeBurn.strokes.firstIndex(where: { $0.id == id }) {
            var s = new
            s.id = id
            s.points = recipe.dodgeBurn.strokes[i].points
            s.hidden = recipe.dodgeBurn.strokes[i].hidden
            if recipe.dodgeBurn.strokes[i] != s { recipe.dodgeBurn.strokes[i] = s }
        } else {
            var b = new
            b.points = []
            b.hidden = false
            if dodgeBurnTool.brush != b { dodgeBurnTool.brush = b }
        }
    }

    /// Sets one setting of the brush or the selected stroke.
    public func setPaint<V: Equatable>(_ keyPath: WritableKeyPath<DodgeBurnStroke, V>, _ value: V) {
        var s = paintSettings
        guard s[keyPath: keyPath] != value else { return }
        s[keyPath: keyPath] = value
        paintSettings = s
    }

    /// Brush size by key: one step is about 12%.
    public func stepBrushSize(_ direction: Int) {
        let limits = DodgeBurnToolState.sizeLimits
        var size = paintSettings.size * (direction > 0 ? 1.12 : 1 / 1.12)
        size = min(max(size, limits.lowerBound), limits.upperBound)
        setPaint(\.size, (size * 10_000).rounded() / 10_000)
    }

    // MARK: Selection and the list

    public func selectStroke(_ id: UUID?) {
        dodgeBurnTool.selectedStrokeID = id.flatMap { id in recipe.dodgeBurn.strokes.contains { $0.id == id } ? id : nil }
    }

    public func deleteStroke(_ id: UUID) {
        guard recipe.dodgeBurn.strokes.contains(where: { $0.id == id }) else { return }
        if dodgeBurnTool.selectedStrokeID == id { dodgeBurnTool.selectedStrokeID = nil }
        recipe.dodgeBurn.strokes.removeAll { $0.id == id }
    }

    public func toggleStrokeHidden(_ id: UUID) {
        guard let i = recipe.dodgeBurn.strokes.firstIndex(where: { $0.id == id }) else { return }
        recipe.dodgeBurn.strokes[i].hidden.toggle()
    }

    public func clearAllStrokes() {
        guard !recipe.dodgeBurn.isIdentity else { return }
        dodgeBurnTool.selectedStrokeID = nil
        dodgeBurnTool.liveStroke = nil
        recipe.dodgeBurn = .identity
    }

    // MARK: Painting

    /// The part of the picture's pixels the pane shows, as the geometry the zoom maths works in.
    private var paintViewport: ZoomViewport? {
        guard let source, paneSize.width >= 1 else { return nil }
        let vp = ZoomViewport(content: PreviewEngine.zoomContentSize(for: recipe, imageSize: source.extent.size),
                              pane: paneSize, fitArea: fitAreaSize)
        return vp.isValid ? vp : nil
    }

    /// The border around the picture in the displayed content, in picture pixels.
    private func borderPad(outputSize: CGSize) -> CGFloat {
        guard recipe.borderEnabled else { return 0 }
        return CGFloat(min(max(recipe.borderWidth, 0), 0.3)) * min(outputSize.width, outputSize.height)
    }

    /// The stroke coordinate (0...1 over the uncropped, upright source) under a pane point (device
    /// pixels). nil without a photo or viewport. Not clamped; see `isOnPicture(atPane:)`.
    public func strokePoint(atPane p: CGPoint) -> StrokePoint? {
        guard let source, let vp = paintViewport else { return nil }
        let size = source.extent.size
        let output = CropGeometry.outputExtent(for: recipe.crop, imageExtent: CGRect(origin: .zero, size: size)).size
        let content = ZoomGeometry.contentPoint(atPane: p, state: zoom, in: vp)
        let pad = borderPad(outputSize: output)
        guard let s = DodgeBurnPlacement.sourcePoint(forOutputPoint: CGPoint(x: content.x - pad, y: content.y - pad),
                                                     crop: recipe.crop, sourceSize: size) else { return nil }
        return StrokePoint(x: s.x, y: s.y, pressure: 1)
    }

    /// True when the pane point is on the picture itself (inside the crop, not on the border).
    public func isOnPicture(atPane p: CGPoint) -> Bool {
        guard let source, let vp = paintViewport else { return false }
        let output = CropGeometry.outputExtent(for: recipe.crop, imageExtent: CGRect(origin: .zero, size: source.extent.size)).size
        let c = ZoomGeometry.contentPoint(atPane: p, state: zoom, in: vp)
        let pad = borderPad(outputSize: output)
        return c.x >= pad && c.y >= pad && c.x <= pad + output.width && c.y <= pad + output.height
    }

    /// The brush radius for a stroke `size` as drawn in the pane, in device pixels. nil without a photo.
    public func brushRadiusInPane(size: Double) -> CGFloat? {
        guard let source, let vp = paintViewport else { return nil }
        let r = DodgeBurnPlacement.brushRadius(size: size, crop: recipe.crop, sourceSize: source.extent.size)
        return CGFloat(r) * CGFloat(ZoomGeometry.scale(of: zoom, in: vp))
    }

    /// Starts a stroke at a pane point (device pixels). `flipped` swaps dodge and burn for this
    /// stroke (Option). Returns false when the point is off the picture or the tool is closed.
    @discardableResult
    public func beginPaintStroke(atPane p: CGPoint, pressure: Double = 1, flipped: Bool = false) -> Bool {
        let tool = dodgeBurnTool
        guard tool.isActive, tool.liveStroke == nil, isOnPicture(atPane: p), var point = strokePoint(atPane: p) else {
            return false
        }
        point.pressure = min(max(pressure, 0.02), 1)
        var stroke = tool.brush
        stroke.id = UUID()
        stroke.hidden = false
        if flipped { stroke.mode = stroke.mode.flipped }
        stroke.points = [point]
        // Painting makes the brush the thing being edited again.
        tool.selectedStrokeID = nil
        tool.liveStroke = stroke
        schedulePreview()
        return true
    }

    /// Adds a point to the stroke being painted. Points closer than a fraction of a brush radius to the
    /// last one are dropped, which keeps strokes (and the saved data) small.
    public func continuePaintStroke(atPane p: CGPoint, pressure: Double = 1) {
        guard var stroke = dodgeBurnTool.liveStroke, var point = strokePoint(atPane: p) else { return }
        point.pressure = min(max(pressure, 0.02), 1)
        if let last = stroke.points.last {
            let minimum = max(0.0004, stroke.size * 0.02)
            if hypot(point.x - last.x, point.y - last.y) < minimum { return }
        }
        stroke.points.append(point)
        dodgeBurnTool.liveStroke = stroke
        schedulePreview()
    }

    /// Finishes the stroke: it becomes one recipe change.
    public func endPaintStroke() { endLiveStroke() }

    private func endLiveStroke() {
        guard let stroke = dodgeBurnTool.liveStroke else { return }
        dodgeBurnTool.liveStroke = nil
        guard !stroke.points.isEmpty else { schedulePreview(); return }
        recipe.dodgeBurn.strokes.append(stroke)
    }

    /// Option held or released: the cursor shows which way the next stroke goes.
    public func setPaintFlipping(_ on: Bool) {
        if dodgeBurnTool.isFlipping != on { dodgeBurnTool.isFlipping = on }
    }

    /// The mode the next stroke gets (the brush mode, flipped while Option is held).
    public var effectiveBrushMode: DodgeBurnMode {
        let mode = dodgeBurnTool.brush.mode
        return dodgeBurnTool.isFlipping ? mode.flipped : mode
    }
}
