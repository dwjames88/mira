import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

struct CropTab: View {
    @Bindable var model: EditorViewModel

    private static let presets = ["original", "free", "square", "3:2", "4:3", "5:4", "16:9"]

    private var canvas: CGSize {
        CropGeometry.orientedSize(for: model.workingCrop, size: model.sourcePixelSize)
    }

    private var aspectTabs: [(value: String, title: String)] {
        Self.presets.map { (value: $0, title: CropAspect.label($0)) }
    }

    private var aspectSelection: Binding<String> {
        Binding(
            get: { CropAspect.landscape(model.workingCrop.aspect) },
            set: { id in
                setAspect(CropAspect.isPortrait(model.workingCrop.aspect) ? CropAspect.swapped(id) : id)
            })
    }

    private var canSwapOrientation: Bool {
        CropAspect.swapped(model.workingCrop.aspect) != model.workingCrop.aspect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FFSlider("Straighten", value: $model.workingCrop.straighten, in: -45...45, default: 0, decimals: 1)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { model.workingCrop.straighten = 0 })
            ScrollView(.horizontal, showsIndicators: false) {
                FFTabBar(aspectTabs, selection: aspectSelection)
                    .frame(minHeight: 44)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: T.cells(1)) {
                    Button(CropAspect.isPortrait(model.workingCrop.aspect) ? "Landscape" : "Portrait") {
                        setAspect(CropAspect.swapped(model.workingCrop.aspect))
                    }
                    .disabled(!canSwapOrientation)
                    Button("Rotate 90\u{00B0}") { model.workingCrop = CropGeometry.rotatedClockwise(model.workingCrop) }
                    Button("Flip H") { model.workingCrop = CropGeometry.flippedHorizontally(model.workingCrop) }
                    Button("Flip V") { model.workingCrop = CropGeometry.flippedVertically(model.workingCrop) }
                    Button("Reset") { model.workingCrop = .identity }
                        .disabled(model.workingCrop.isIdentity && model.workingCrop.aspect == CropAspect.original)
                    Button("Cancel") { model.cancelCrop() }
                }
                .buttonStyle(.ff)
                .frame(minHeight: 44)
            }
            Text(sizeText).ffLabel(color: T.paperDim)
                .frame(maxWidth: .infinity, minHeight: T.rows(1.5), alignment: .leading)
        }
        .padding(.horizontal, T.cells(2))
        .padding(.bottom, T.rows(0.5))
        .ffPanel()
    }

    /// Picks a preset and reshapes the box to it (keeping area and centre), in canvas pixel space.
    private func setAspect(_ id: String) {
        let c = canvas
        guard c.width > 0, c.height > 0 else { return }
        model.workingCrop.aspect = id
        guard let ratio = CropAspect.ratio(id: id, canvas: c) else { return }
        let r = model.workingCrop.rect.cgRect
        let px = CGRect(x: r.minX * c.width, y: r.minY * c.height, width: r.width * c.width, height: r.height * c.height)
        let f = CropGeometry.constrain(rect: px, toAspect: ratio, within: CGRect(origin: .zero, size: c))
        model.workingCrop.rect = CropRect(x: f.minX / c.width, y: f.minY / c.height,
                                          w: f.width / c.width, h: f.height / c.height)
    }

    private var sizeText: String {
        let c = canvas
        guard c.width > 0 else { return "\u{2014}" }
        let r = model.workingCrop.rect
        let w = (r.w * c.width).rounded(), h = (r.h * c.height).rounded()
        guard w.isFinite, h.isFinite else { return "\u{2014}" }   // Int(NaN) would trap
        return "\(Int(w)) \u{00D7} \(Int(h)) px"
    }
}


/// Touch crop box drawn over the (uncropped) preview. Maps the normalised `workingCrop.rect`
/// through the aspect-fit rect of the oriented canvas, so letterboxing is accounted for.
struct CropOverlayView: View {
    @Bindable var model: EditorViewModel

    private struct Drag {
        let hit: CropHit
        let start: CGRect
    }
    @State private var drag: Drag?

    private static let tolerance: CGFloat = 28
    private static let minSide: CGFloat = 44
    private static let cornerArm: CGFloat = 20
    private static let edgeBar: CGFloat = 28

    private var canvas: CGSize {
        CropGeometry.orientedSize(for: model.workingCrop, size: model.sourcePixelSize)
    }

    private var aspectRatio: Double? {
        CropAspect.ratio(id: model.workingCrop.aspect, canvas: canvas)
    }

    var body: some View {
        GeometryReader { geo in
            let fit = CropGeometry.aspectFit(contentSize: canvas, in: CGRect(origin: .zero, size: geo.size))
            let box = viewRect(for: model.workingCrop.rect, in: fit)
            ZStack(alignment: .topLeading) {
                Path { p in
                    p.addRect(fit)
                    p.addRect(box)
                }
                .fill(FieldFramesTheme.ink.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                grid(box)

                Rectangle()
                    .strokeBorder(FieldFramesTheme.onPhoto, lineWidth: 1)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .allowsHitTesting(false)

                handles(box)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { change($0, fit: fit) }
                    .onEnded { _ in drag = nil })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop box")
    }

    private func viewRect(for rect: CropRect, in fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + rect.x * fit.width, y: fit.minY + rect.y * fit.height,
               width: rect.w * fit.width, height: rect.h * fit.height)
    }

    private func normalised(_ r: CGRect, in fit: CGRect) -> CropRect {
        guard fit.width > 0, fit.height > 0 else { return .full }
        return CropRect(x: (r.minX - fit.minX) / fit.width, y: (r.minY - fit.minY) / fit.height,
                        w: r.width / fit.width, h: r.height / fit.height).clamped()
    }

    private func change(_ value: DragGesture.Value, fit: CGRect) {
        if drag == nil {
            let start = viewRect(for: model.workingCrop.rect, in: fit)
            let hit = CropGeometry.hitTest(point: value.startLocation, rect: start, tolerance: Self.tolerance)
            guard hit != .none else { return }
            drag = Drag(hit: hit, start: start)
        }
        guard let drag else { return }
        let next: CGRect
        switch drag.hit {
        case .move:
            next = CropGeometry.pan(rect: drag.start, by: value.translation, within: fit)
        case .handle(let handle):
            next = CropGeometry.resize(
                rect: drag.start, handle: handle, by: value.translation, aspect: aspectRatio,
                within: fit, minSize: min(Self.minSide, min(fit.width, fit.height) / 2))
        case .none:
            return
        }
        model.workingCrop.rect = normalised(next, in: fit)
    }

    private func grid(_ box: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = box.minX + box.width * CGFloat(i) / 3
                let y = box.minY + box.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
            }
        }
        .stroke(FieldFramesTheme.onPhoto.opacity(0.45), lineWidth: 1)
        .allowsHitTesting(false)
    }

    private func handles(_ box: CGRect) -> some View {
        let arm = min(Self.cornerArm, min(box.width, box.height) / 3)
        let bar = min(Self.edgeBar, min(box.width, box.height) / 3)
        return ZStack(alignment: .topLeading) {
            Path { p in
                p.move(to: CGPoint(x: box.minX, y: box.minY + arm)); p.addLine(to: CGPoint(x: box.minX, y: box.minY))
                p.addLine(to: CGPoint(x: box.minX + arm, y: box.minY))
                p.move(to: CGPoint(x: box.maxX - arm, y: box.minY)); p.addLine(to: CGPoint(x: box.maxX, y: box.minY))
                p.addLine(to: CGPoint(x: box.maxX, y: box.minY + arm))
                p.move(to: CGPoint(x: box.maxX, y: box.maxY - arm)); p.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
                p.addLine(to: CGPoint(x: box.maxX - arm, y: box.maxY))
                p.move(to: CGPoint(x: box.minX + arm, y: box.maxY)); p.addLine(to: CGPoint(x: box.minX, y: box.maxY))
                p.addLine(to: CGPoint(x: box.minX, y: box.maxY - arm))
            }
            .stroke(FieldFramesTheme.lichen, style: StrokeStyle(lineWidth: 3, lineCap: .butt, lineJoin: .miter))
            Path { p in
                p.move(to: CGPoint(x: box.midX - bar / 2, y: box.minY)); p.addLine(to: CGPoint(x: box.midX + bar / 2, y: box.minY))
                p.move(to: CGPoint(x: box.midX - bar / 2, y: box.maxY)); p.addLine(to: CGPoint(x: box.midX + bar / 2, y: box.maxY))
                p.move(to: CGPoint(x: box.minX, y: box.midY - bar / 2)); p.addLine(to: CGPoint(x: box.minX, y: box.midY + bar / 2))
                p.move(to: CGPoint(x: box.maxX, y: box.midY - bar / 2)); p.addLine(to: CGPoint(x: box.maxX, y: box.midY + bar / 2))
            }
            .stroke(FieldFramesTheme.lichen, style: StrokeStyle(lineWidth: 3, lineCap: .butt))
        }
        .allowsHitTesting(false)
    }
}
