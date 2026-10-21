import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

private extension CurveChannel {
    var title: String {
        switch self {
        case .rgb: "RGB"
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        case .luminance: "L"
        }
    }

    /// Colour of the tab underline and (for R, G, B) of the curve.
    var tint: Color? {
        switch self {
        case .red: Color(red: 0.93, green: 0.27, blue: 0.25)
        case .green: Color(red: 0.30, green: 0.78, blue: 0.36)
        case .blue: Color(red: 0.28, green: 0.47, blue: 0.95)
        default: nil
        }
    }

    var accessibilityName: String {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .luminance: "Luminance"
        }
    }
}

/// The CURVES group: channel tabs and a square curve editor.
public struct CurvesPanel: View {
    @Bindable private var model: EditorModel
    @State private var channel: CurveChannel
    @State private var selected: Int?

    public init(model: EditorModel) {
        self.model = model
        _channel = State(initialValue: .rgb)
    }

    init(model: EditorModel, channel: CurveChannel, selected: Int? = nil) {
        self.model = model
        _channel = State(initialValue: channel)
        _selected = State(initialValue: selected)
    }

    private var points: Binding<[CurvePoint]> {
        Binding(get: { model.recipe.curves[channel] }, set: { model.recipe.curves[channel] = $0 })
    }

    public var body: some View {
        InspectorGroup("curves", title: "Curves") {
            VStack(alignment: .leading, spacing: 0) {
                tabs
                CurveEditorView(points: points, channel: channel, curves: model.recipe.curves,
                                histogram: model.histogram, selected: $selected)
                    .aspectRatio(1, contentMode: .fit)
                    .padding(.top, 4)
                HStack {
                    Text(channel.accessibilityName).ffLabel(color: T.paperDim)
                    Spacer()
                    Button("Reset") {
                        model.recipe.curves[channel] = CurvesSettings.identityPoints
                        selected = nil
                    }
                    .buttonStyle(.plain)
                    .ffLabel(color: model.recipe.curves.isIdentity(channel) ? T.paperDim.opacity(0.5) : T.lichen)
                    .disabled(model.recipe.curves.isIdentity(channel))
                    .help("Reset this curve")
                }
                .frame(height: T.rows(2))
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: T.cells(3)) {
            ForEach(CurveChannel.allCases, id: \.self) { c in
                let isSelected = c == channel
                Button {
                    channel = c
                    selected = nil
                } label: {
                    Text(c.title)
                        .ffLabel(color: isSelected ? T.paper : T.paperDim, weight: isSelected ? .medium : .regular)
                        .frame(height: T.rows(2))
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(c.tint ?? (isSelected ? T.lichen : Color.clear))
                                .frame(height: 2)
                                .opacity(c.tint != nil || isSelected ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(c.accessibilityName) curve")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
    }
}

/// The square editor for one curve. Click empty space to add a point on the curve, drag a point
/// to move it, double-click it or drag it out of the square to delete it, arrow keys nudge.
struct CurveEditorView: View {
    @Binding var points: [CurvePoint]
    let channel: CurveChannel
    /// All curves, drawn faintly behind the selected one.
    let curves: CurvesSettings
    let histogram: HistogramData?
    @Binding var selected: Int?

    @State private var dragging: Int?
    @State private var lastTap: (index: Int, time: Date)?
    @State private var moved = false
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    private var curveColor: Color { channel.tint ?? T.paper }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Canvas { context, size in draw(&context, size) }
                if let i = dragging ?? selected, points.indices.contains(i), dragging != nil {
                    Text(CurveEditing.readout(points[i]))
                        .ffLabel(size: 9, color: T.paper)
                        .padding(.horizontal, 4).padding(.vertical, 2)
                        .background(T.backdrop)
                        .padding(4)
                        .allowsHitTesting(false)
                }
            }
            .background(T.ink)
            .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
            .contentShape(Rectangle())
            .gesture(drag(size))
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .onKeyPress(phases: [.down, .repeat]) { press in key(press) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(channel.accessibilityName) curve editor")
        .accessibilityValue("\(points.count) points")
    }

    // MARK: Gestures

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                focused = true
                if dragging == nil {
                    moved = false
                    if let hit = CurveEditing.hit(points, at: g.startLocation, size: size, radius: 9) {
                        dragging = hit
                    } else {
                        let c = CurveEditing.curvePoint(for: g.startLocation, size: size)
                        dragging = CurveEditing.addPoint(&points, atX: Double(c.x))
                    }
                    selected = dragging
                }
                guard let index = dragging else { return }
                if hypot(g.translation.width, g.translation.height) > 2 { moved = true }
                guard moved else { return }
                CurveEditing.move(&points, index: index, to: CurveEditing.curvePoint(for: g.location, size: size))
            }
            .onEnded { g in
                defer { dragging = nil }
                guard let index = dragging, points.indices.contains(index) else { return }
                if moved, CurveEditing.isOutside(g.location, size: size), CurveEditing.delete(&points, index: index) {
                    selected = nil
                    return
                }
                if !moved {
                    // A second tap on the same point within 0.4 s deletes it.
                    if let last = lastTap, last.index == index, Date().timeIntervalSince(last.time) < 0.4,
                       CurveEditing.delete(&points, index: index) {
                        selected = nil
                        lastTap = nil
                        return
                    }
                    lastTap = (index, Date())
                }
            }
    }

    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard let i = selected, points.indices.contains(i) else { return .ignored }
        let step = (press.modifiers.contains(.shift) ? 10.0 : 1.0) / 255
        switch press.key {
        case .leftArrow: CurveEditing.nudge(&points, index: i, dx: -step, dy: 0)
        case .rightArrow: CurveEditing.nudge(&points, index: i, dx: step, dy: 0)
        case .upArrow: CurveEditing.nudge(&points, index: i, dx: 0, dy: step)
        case .downArrow: CurveEditing.nudge(&points, index: i, dx: 0, dy: -step)
        case .delete, .deleteForward:
            if CurveEditing.delete(&points, index: i) { selected = nil } else { return .ignored }
        default: return .ignored
        }
        return .handled
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        // Histogram ghost for the selected channel.
        if let histogram {
            let peak = HistogramPlot.peak(histogram)
            let colors: [(Color, [Float])]
            switch channel {
            case .rgb:
                colors = [(Color(red: 0.93, green: 0.27, blue: 0.25), histogram.red),
                          (Color(red: 0.30, green: 0.78, blue: 0.36), histogram.green),
                          (Color(red: 0.28, green: 0.47, blue: 0.95), histogram.blue)]
            case .luminance: colors = [(T.paper, histogram.luminance)]
            default: colors = [(channel.tint ?? T.paper, histogram.bins(channel))]
            }
            for (color, bins) in colors {
                context.fill(HistogramPlot.path(bins, size: size, peak: peak, closed: true), with: .color(color.opacity(0.16)))
            }
        }
        // Quarter grid.
        for q in 1..<4 {
            let f = CGFloat(q) / 4
            var v = Path(); v.move(to: CGPoint(x: size.width * f, y: 0)); v.addLine(to: CGPoint(x: size.width * f, y: size.height))
            var h = Path(); h.move(to: CGPoint(x: 0, y: size.height * f)); h.addLine(to: CGPoint(x: size.width, y: size.height * f))
            context.stroke(v, with: .color(T.hair), lineWidth: 1)
            context.stroke(h, with: .color(T.hair), lineWidth: 1)
        }
        // Identity diagonal.
        var diagonal = Path()
        diagonal.move(to: CGPoint(x: 0, y: size.height)); diagonal.addLine(to: CGPoint(x: size.width, y: 0))
        context.stroke(diagonal, with: .color(T.paperDim.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        // Other curves, faint.
        for other in CurveChannel.allCases where other != channel && !curves.isIdentity(other) {
            context.stroke(curvePath(curves[other], size: size), with: .color((other.tint ?? T.paperMid).opacity(0.35)), lineWidth: 1)
        }
        // The curve.
        context.stroke(curvePath(points, size: size), with: .color(curveColor), lineWidth: 1.5)
        // Control points.
        for (i, p) in points.enumerated() {
            let c = CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(p.y)) * size.height)
            let r = CGRect(x: c.x - 3.5, y: c.y - 3.5, width: 7, height: 7)
            let isSelected = i == selected
            context.fill(Path(r), with: .color(isSelected ? T.lichen : T.ink))
            context.stroke(Path(r), with: .color(isSelected ? T.lichen : curveColor), lineWidth: 1)
        }
    }

    private func curvePath(_ pts: [CurvePoint], size: CGSize) -> Path {
        let curve = MonotoneCurve(pts)
        var p = Path()
        let n = 128
        for i in 0...n {
            let x = Double(i) / Double(n)
            let pt = CGPoint(x: x * size.width, y: (1 - curve.value(at: x)) * size.height)
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}
