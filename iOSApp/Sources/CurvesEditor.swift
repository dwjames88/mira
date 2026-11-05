import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

private extension CurveChannel {
    var tabTitle: String {
        switch self {
        case .rgb: "RGB"
        case .red: "R"
        case .green: "G"
        case .blue: "B"
        case .luminance: "L"
        }
    }

    var tint: Color? {
        switch self {
        case .red: Color(red: 0.93, green: 0.27, blue: 0.25)
        case .green: Color(red: 0.30, green: 0.78, blue: 0.36)
        case .blue: Color(red: 0.28, green: 0.47, blue: 0.95)
        default: nil
        }
    }

    var fullName: String {
        switch self {
        case .rgb: "RGB"
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .luminance: "Luminance"
        }
    }
}

/// Pure point-editing rules (ported from the macOS CurveEditing).
private enum PointEditing {
    static let minGap = 0.004

    static func clamp01(_ v: Double) -> Double { min(max(v, 0), 1) }

    static func addPoint(_ points: inout [CurvePoint], atX x: Double) -> Int {
        let curve = MonotoneCurve(points)
        let x = clamp01(x)
        if let i = points.firstIndex(where: { abs($0.x - x) < minGap }) { return i }
        let index = points.firstIndex { $0.x > x } ?? points.count
        points.insert(CurvePoint(x: x, y: curve.value(at: x)), at: index)
        return index
    }

    static func move(_ points: inout [CurvePoint], index: Int, to target: CGPoint) {
        guard points.indices.contains(index) else { return }
        let isEnd = index == 0 || index == points.count - 1
        var x = points[index].x
        if !isEnd {
            let lo = points[index - 1].x + minGap, hi = points[index + 1].x - minGap
            x = min(max(Double(target.x), lo), max(lo, hi))
        }
        points[index] = CurvePoint(x: clamp01(x), y: clamp01(Double(target.y)))
    }

    @discardableResult
    static func delete(_ points: inout [CurvePoint], index: Int) -> Bool {
        guard points.count > 2, points.indices.contains(index), index != 0, index != points.count - 1 else { return false }
        points.remove(at: index)
        return true
    }

    static func hit(_ points: [CurvePoint], at p: CGPoint, size: CGSize, radius: CGFloat) -> Int? {
        var best: (Int, CGFloat)?
        for (i, pt) in points.enumerated() {
            let d = hypot(CGFloat(pt.x) * size.width - p.x, (1 - CGFloat(pt.y)) * size.height - p.y)
            if d <= radius, best == nil || d < best!.1 { best = (i, d) }
        }
        return best?.0
    }

    static func curvePoint(for p: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: p.x / max(size.width, 1), y: 1 - p.y / max(size.height, 1))
    }

    static func isOutside(_ p: CGPoint, size: CGSize, margin: CGFloat = 24) -> Bool {
        p.x < -margin || p.y < -margin || p.x > size.width + margin || p.y > size.height + margin
    }
}

struct CurvesEditor: View {
    @Bindable var model: EditorViewModel
    /// When set, the editor is the compact in-panel form: tabs and Reset share a row and the plot is this tall and full width.
    var plotHeight: CGFloat?
    @State private var channel: CurveChannel = .rgb
    @State private var selected: Int?
    @State private var dragging: Int?
    @State private var moved = false

    private var points: [CurvePoint] { model.recipe.curves[channel] }
    private var isIdentity: Bool { model.recipe.curves.isIdentity(channel) }
    private var curveColor: Color { channel.tint ?? T.paper }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if plotHeight == nil { FFSectionLabel("Curves") }
            if plotHeight == nil { tabs } else {
                HStack(spacing: 0) { tabs; resetButton }
            }
            GeometryReader { geo in
                Canvas { context, size in draw(&context, size) }
                    .background(T.backdrop)
                    .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
                    .contentShape(Rectangle())
                    .gesture(drag(geo.size))
            }
            .modifier(PlotSize(height: plotHeight))
            .padding(.top, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(channel.fullName) curve editor")
            .accessibilityValue("\(points.count) points")
            if plotHeight == nil {
                HStack {
                    Text(channel.fullName).ffLabel(color: T.paperDim)
                    Spacer()
                    resetButton
                }
            } else {
                Spacer().frame(height: 8)
            }
        }
    }

    private var resetButton: some View {
        Button {
            model.recipe.curves[channel] = CurvesSettings.identityPoints
            selected = nil
        } label: {
            Text("Reset").ffLabel(color: isIdentity ? T.paperDim.opacity(0.5) : T.lichen)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(isIdentity)
    }

    private struct PlotSize: ViewModifier {
        let height: CGFloat?
        func body(content: Content) -> some View {
            if let height { content.frame(height: height) } else { content.aspectRatio(1, contentMode: .fit) }
        }
    }

    private var tabs: some View {
        HStack(spacing: T.cells(3)) {
            ForEach(CurveChannel.allCases, id: \.self) { c in
                let isSel = c == channel
                Button {
                    channel = c
                    selected = nil
                } label: {
                    Text(c.tabTitle)
                        .ffLabel(color: isSel ? T.paper : T.paperDim, weight: isSel ? .medium : .regular)
                        .frame(minWidth: 32, minHeight: 44)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(c.tint ?? (isSel ? T.lichen : Color.clear))
                                .frame(height: 2)
                                .opacity(c.tint != nil || isSel ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(c.fullName) curve")
                .accessibilityAddTraits(isSel ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Gesture

    private func drag(_ size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { g in
                var pts = model.recipe.curves[channel]
                if dragging == nil {
                    moved = false
                    if let hit = PointEditing.hit(pts, at: g.startLocation, size: size, radius: 22) {
                        dragging = hit
                    } else {
                        let c = PointEditing.curvePoint(for: g.startLocation, size: size)
                        dragging = PointEditing.addPoint(&pts, atX: Double(c.x))
                        model.recipe.curves[channel] = pts
                    }
                    selected = dragging
                }
                guard let index = dragging else { return }
                if hypot(g.translation.width, g.translation.height) > 2 { moved = true }
                guard moved else { return }
                PointEditing.move(&pts, index: index, to: PointEditing.curvePoint(for: g.location, size: size))
                model.recipe.curves[channel] = pts
            }
            .onEnded { g in
                defer { dragging = nil }
                guard let index = dragging else { return }
                var pts = model.recipe.curves[channel]
                if moved, PointEditing.isOutside(g.location, size: size),
                   PointEditing.delete(&pts, index: index) {
                    model.recipe.curves[channel] = pts
                    selected = nil
                }
            }
    }

    // MARK: Drawing

    private func draw(_ context: inout GraphicsContext, _ size: CGSize) {
        // Histogram ghost.
        let bins = model.histogram.bins(channel == .rgb ? .luminance : channel)
        if let peak = bins.max(), peak > 0, bins.count > 1 {
            var p = Path()
            p.move(to: CGPoint(x: 0, y: size.height))
            for (i, b) in bins.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                p.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(b / peak) * 0.9)))
            }
            p.addLine(to: CGPoint(x: size.width, y: size.height))
            p.closeSubpath()
            context.fill(p, with: .color(curveColor.opacity(0.16)))
        }
        // Grid.
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
        // Curve.
        let pts = points
        context.stroke(curvePath(pts, size: size), with: .color(curveColor), lineWidth: 1.5)
        // Control points.
        for (i, p) in pts.enumerated() {
            let c = CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(p.y)) * size.height)
            let r = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
            let isSel = i == selected
            context.fill(Path(r), with: .color(isSel ? T.lichen : T.backdrop))
            context.stroke(Path(r), with: .color(isSel ? T.lichen : curveColor), lineWidth: 1)
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
