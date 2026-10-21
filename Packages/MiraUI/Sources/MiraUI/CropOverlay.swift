import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

private struct FFCropForceGridKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Draws the rule-of-thirds grid even when idle. Used by the headless snapshot test.
    var ffCropForceGrid: Bool {
        get { self[FFCropForceGridKey.self] }
        set { self[FFCropForceGridKey.self] = newValue }
    }
}

/// The crop box over the canvas picture: dimming outside, a paper hairline border, L-shaped corner
/// handles and edge bars. Drag a handle to resize (aspect-locked when a preset is chosen), drag
/// inside to pan. View space is mapped to the normalised canvas through the aspect-fit rect, so
/// letterboxing is accounted for. Fill the same area the picture is fitted into.
struct CropOverlay: View {
    @Bindable var model: EditorModel
    @Environment(\.ffCropForceGrid) private var forceGrid

    private struct Drag {
        let hit: CropHit
        let start: CGRect
    }
    @State private var drag: Drag?

    private static let tolerance: CGFloat = 14
    private static let minSide: CGFloat = 28
    private static let cornerArm: CGFloat = 18
    private static let edgeBar: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let fit = CropGeometry.aspectFit(contentSize: model.cropCanvasSize ?? .zero,
                                             in: CGRect(origin: .zero, size: geo.size))
            let box = viewRect(for: model.crop.rect, in: fit)
            ZStack(alignment: .topLeading) {
                // Outside the box: ink at 55%.
                Path { p in
                    p.addRect(fit)
                    p.addRect(box)
                }
                .fill(T.ink.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)

                if drag != nil || forceGrid { grid(box) }

                Rectangle()
                    .strokeBorder(T.paper, lineWidth: 1)
                    .frame(width: box.width, height: box.height)
                    .offset(x: box.minX, y: box.minY)
                    .allowsHitTesting(false)

                handles(box)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in change(value, fit: fit) }
                    .onEnded { _ in drag = nil })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Crop box")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        let r = model.crop.rect
        return "\(Int((r.w * 100).rounded())) by \(Int((r.h * 100).rounded())) percent of the picture"
    }

    // MARK: Mapping

    private func viewRect(for rect: CropRect, in fit: CGRect) -> CGRect {
        CGRect(x: fit.minX + rect.x * fit.width, y: fit.minY + rect.y * fit.height,
               width: rect.w * fit.width, height: rect.h * fit.height)
    }

    private func normalised(_ r: CGRect, in fit: CGRect) -> CropRect {
        guard fit.width > 0, fit.height > 0 else { return .full }
        return CropRect(x: (r.minX - fit.minX) / fit.width, y: (r.minY - fit.minY) / fit.height,
                        w: r.width / fit.width, h: r.height / fit.height).clamped()
    }

    // MARK: Gesture

    private func change(_ value: DragGesture.Value, fit: CGRect) {
        if drag == nil {
            let start = viewRect(for: model.crop.rect, in: fit)
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
                rect: drag.start, handle: handle, by: value.translation, aspect: model.cropAspectRatio,
                within: fit, minSize: min(Self.minSide, min(fit.width, fit.height) / 2))
        case .none:
            return
        }
        model.crop.rect = normalised(next, in: fit)
    }

    // MARK: Drawing

    private func grid(_ box: CGRect) -> some View {
        Path { p in
            for i in 1...2 {
                let x = box.minX + box.width * CGFloat(i) / 3
                let y = box.minY + box.height * CGFloat(i) / 3
                p.move(to: CGPoint(x: x, y: box.minY)); p.addLine(to: CGPoint(x: x, y: box.maxY))
                p.move(to: CGPoint(x: box.minX, y: y)); p.addLine(to: CGPoint(x: box.maxX, y: y))
            }
        }
        .stroke(T.paper.opacity(0.45), lineWidth: 1)
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
            .stroke(T.paper, style: StrokeStyle(lineWidth: 2, lineCap: .butt, lineJoin: .miter))

            Path { p in
                p.move(to: CGPoint(x: box.midX - bar / 2, y: box.minY)); p.addLine(to: CGPoint(x: box.midX + bar / 2, y: box.minY))
                p.move(to: CGPoint(x: box.midX - bar / 2, y: box.maxY)); p.addLine(to: CGPoint(x: box.midX + bar / 2, y: box.maxY))
                p.move(to: CGPoint(x: box.minX, y: box.midY - bar / 2)); p.addLine(to: CGPoint(x: box.minX, y: box.midY + bar / 2))
                p.move(to: CGPoint(x: box.maxX, y: box.midY - bar / 2)); p.addLine(to: CGPoint(x: box.maxX, y: box.midY + bar / 2))
            }
            .stroke(T.paper, style: StrokeStyle(lineWidth: 2, lineCap: .butt))
        }
        .allowsHitTesting(false)
    }
}

/// The controls under the canvas while cropping.
struct CropControls: View {
    @Bindable var model: EditorModel

    private static let presets = ["original", "free", "square", "3:2", "4:3", "5:4", "16:9"]

    private var aspectTabs: [(value: String, title: String)] {
        Self.presets.map { (value: $0, title: CropAspect.label($0)) }
    }

    private var aspectSelection: Binding<String> {
        Binding(
            get: { CropAspect.landscape(model.crop.aspect) },
            set: { id in
                // Keep a portrait choice portrait when the new preset has a twin.
                model.setAspect(CropAspect.isPortrait(model.crop.aspect) ? CropAspect.swapped(id) : id)
            })
    }

    private var canSwapOrientation: Bool {
        CropAspect.swapped(model.crop.aspect) != model.crop.aspect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FFSlider("Straighten", value: $model.straighten, in: -45...45, default: 0, decimals: 1)
                .padding(.top, T.rows(0.5))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: T.cells(3)) { aspectRow }
                VStack(alignment: .leading, spacing: 0) { aspectRow }
            }
            .padding(.bottom, T.rows(0.5))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: T.cells(1)) { actionRow }
                VStack(alignment: .leading, spacing: T.rows(0.5)) {
                    HStack(spacing: T.cells(1)) { transformButtons }
                    HStack(spacing: T.cells(1)) { endButtons }
                }
            }
            .padding(.bottom, T.rows(1))
        }
        .padding(.horizontal, T.cells(2))
        .frame(maxWidth: .infinity, alignment: .leading)
        .ffPanel()
    }

    @ViewBuilder private var aspectRow: some View {
        FFTabBar(aspectTabs, selection: aspectSelection)
        Button(CropAspect.isPortrait(model.crop.aspect) ? "Landscape" : "Portrait") {
            model.toggleAspectOrientation()
        }
        .buttonStyle(.ff)
        .disabled(!canSwapOrientation)
        .help("Swap portrait and landscape")
    }

    @ViewBuilder private var transformButtons: some View {
        Button("Rotate 90\u{00B0}") { model.rotate90() }.buttonStyle(.ff)
        Button("Flip H") { model.flipH() }.buttonStyle(.ff)
        Button("Flip V") { model.flipV() }.buttonStyle(.ff)
        Button("Reset crop") { model.resetCrop() }
            .buttonStyle(.ff)
            .disabled(model.crop.isIdentity && model.crop.aspect == CropAspect.original)
    }

    @ViewBuilder private var endButtons: some View {
        Button("Cancel") { model.cancelCrop() }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.ff)
        Button("Done") { model.commitCrop() }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.ffProminent)
    }

    @ViewBuilder private var actionRow: some View {
        transformButtons
        Spacer(minLength: T.cells(1))
        endButtons
    }
}
