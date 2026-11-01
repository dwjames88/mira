import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// One focusable adjustment in the DEVELOP chip strip.
private struct Adjustment: Identifiable {
    enum Kind {
        case scalar(WritableKeyPath<Recipe, Double>, ClosedRange<Double>, Double)
        case curves, mixer, border
    }
    let id: String
    let title: String
    let group: String
    let kind: Kind

    /// Built on demand so key paths are never held in shared mutable/global state.
    static var all: [Adjustment] {
        func s(_ id: String, _ title: String, _ group: String, _ kp: WritableKeyPath<Recipe, Double>,
               _ r: ClosedRange<Double>, _ d: Double = 0) -> Adjustment {
            Adjustment(id: id, title: title, group: group, kind: .scalar(kp, r, d))
        }
        return [
            s("exposure", "Exposure", "Light", \.exposure, -2...2),
            s("contrast", "Contrast", "Light", \.contrast, -1...1),
            s("highlights", "Highlights", "Light", \.highlights, -1...1),
            s("shadows", "Shadows", "Light", \.shadows, -1...1),
            s("whites", "Whites", "Light", \.whites, -1...1),
            s("blacks", "Blacks", "Light", \.blacks, -1...1),
            s("texture", "Texture", "Presence", \.texture, -1...1),
            s("clarity", "Clarity", "Presence", \.clarity, -1...1),
            s("vibrance", "Vibrance", "Presence", \.vibrance, -1...1),
            s("saturation", "Saturation", "Presence", \.saturation, -1...1),
            s("temperature", "Temperature", "Color", \.warmth, -1...1),
            s("tint", "Tint", "Color", \.tint, -1...1),
            Adjustment(id: "curves", title: "Curves", group: "Color", kind: .curves),
            Adjustment(id: "mixer", title: "Color mix", group: "Color", kind: .mixer),
            s("grain", "Grain", "Effects", \.grainAmount, 0...1),
            s("grainSize", "Grain size", "Effects", \.grainSize, 0...1, 0.5),
            s("halation", "Halation", "Effects", \.halationAmount, 0...1),
            s("halationRadius", "Halation radius", "Effects", \.halationRadius, 0...1, 0.5),
            s("bloom", "Bloom", "Effects", \.bloomAmount, 0...1),
            s("vignette", "Vignette", "Frame", \.vignetteAmount, 0...1),
            Adjustment(id: "border", title: "Border", group: "Frame", kind: .border),
        ]
    }
}

/// Photomator-style develop chrome: one adjustment in focus, picked from a chip strip.
struct DevelopPanel: View {
    @Bindable var model: EditorViewModel
    @State private var focus = "exposure"
    @State private var showHistogram = false
    @State private var showingTool = false

    private var items: [Adjustment] { Adjustment.all }
    private var current: Adjustment { items.first { $0.id == focus } ?? items[0] }

    var body: some View {
        VStack(spacing: 0) {
            if showHistogram {
                HistogramView(data: model.histogram, height: T.rows(2.5))
                    .padding(.horizontal, T.cells(2))
                    .padding(.top, T.rows(0.5))
            }
            focusArea
                .padding(.horizontal, T.cells(2))
                .padding(.top, T.rows(0.25))
            FFHairline()
            chipStrip
        }
        .ffPanel()
        .sheet(isPresented: $showingTool) { toolSheet }
    }

    // MARK: Focused control

    @ViewBuilder private var focusArea: some View {
        HStack(alignment: .center, spacing: T.cells(1)) {
            Group {
                switch current.kind {
                case let .scalar(kp, range, def):
                    FocusedSlider(label: current.title, value: model.bind(kp), range: range, def: def)
                case .curves, .mixer:
                    Button { showingTool = true } label: {
                        Text("OPEN \(current.title.uppercased())").ffLabel(color: T.lichen)
                            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                case .border:
                    VStack(spacing: 0) {
                        FFToggle("Border", isOn: model.bind(\.borderEnabled))
                            .frame(minHeight: 44)
                        if model.recipe.borderEnabled {
                            FocusedSlider(label: "Border width", value: model.bind(\.borderWidth),
                                          range: 0...0.3, def: 0.04)
                        }
                    }
                }
            }
            toolButton(showHistogram ? "HIST \u{2212}" : "HIST +", enabled: true) { showHistogram.toggle() }
        }
    }

    private func toolButton(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).ffLabel(size: 9, color: enabled ? T.paperMid : T.paperDim.opacity(0.4)).multilineTextAlignment(.center)
                .frame(minWidth: 48, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: Chip strip

    private var chipStrip: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            if idx > 0, items[idx - 1].group != item.group {
                                Rectangle().fill(T.hair).frame(width: 1, height: 20).padding(.horizontal, 4)
                            }
                            chip(item).id(item.id)
                        }
                    }
                    .padding(.horizontal, T.cells(1))
                }
                .onChange(of: focus) { _, id in withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
            Rectangle().fill(T.hair).frame(width: 1, height: 24)
            toolButton("RESET ALL", enabled: model.canResetDevelop) { model.resetDevelop() }
                .frame(minWidth: 64)
        }
        .frame(height: 48)
    }

    private func chip(_ item: Adjustment) -> some View {
        let selected = item.id == focus
        return Button {
            focus = item.id
            if case .curves = item.kind { showingTool = true }
            if case .mixer = item.kind { showingTool = true }
        } label: {
            Text(item.title.uppercased())
                .ffLabel(size: 10, color: selected ? T.paper : T.paperMid)
                .padding(.horizontal, T.cells(1.5))
                .frame(minWidth: 44, minHeight: 48)
                .background(selected ? T.paper.opacity(0.08) : Color.clear)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(selected ? T.lichen : .clear).frame(height: 2).padding(.horizontal, T.cells(1))
                }
                .overlay(alignment: .topTrailing) {
                    if isModified(item) {
                        Rectangle().fill(T.lichen).frame(width: 5, height: 5).padding(.top, 10).padding(.trailing, 6)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.title)
        .accessibilityValue(isModified(item) ? "adjusted" : "default")
    }

    private func isModified(_ item: Adjustment) -> Bool {
        let base = Recipe()
        switch item.kind {
        case let .scalar(kp, _, def): return model.recipe[keyPath: kp] != def
        case .curves: return model.recipe.curves != base.curves
        case .mixer: return model.recipe.colorMixer != base.colorMixer
        case .border: return model.recipe.borderEnabled != base.borderEnabled
        }
    }

    // MARK: Curves / mixer sheet (photo stays live and interactive above it)

    private var toolSheet: some View {
        ScrollView {
            Group {
                if case .mixer = current.kind { ColorMixerEditor(model: model) }
                else { CurvesEditor(model: model) }
            }
            .padding(T.cells(2))
        }
        .background(T.ink.ignoresSafeArea())
        .foregroundStyle(T.paper)
        .presentationDetents([.height(380), .large])
        .presentationBackgroundInteraction(.enabled(upThrough: .height(380)))
        .presentationDragIndicator(.visible)
    }
}

/// The single slider in focus: label + numeric readout (from `FFSlider`), a 56pt-tall touch area,
/// double-tap anywhere on it to reset, and an explicit reset button.
private struct FocusedSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let def: Double

    var body: some View {
        HStack(spacing: T.cells(1)) {
            FFSlider(label, value: $value, in: range, default: def)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture(count: 2).onEnded { value = def })
            Button { value = def } label: {
                Text("\u{21BA}").font(T.mono(16))
                    .foregroundStyle(value == def ? T.paperDim.opacity(0.4) : T.lichen)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(value == def)
            .accessibilityLabel("Reset \(label)")
        }
    }
}

struct HistogramView: View {
    let data: HistogramData
    var height: CGFloat = FieldFramesTheme.rows(4)

    var body: some View {
        Canvas { ctx, size in
            let bins = data.luminance
            guard let peak = bins.max(), peak > 0 else { return }
            var path = Path()
            path.move(to: CGPoint(x: 0, y: size.height))
            for (i, v) in bins.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
                path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v / peak))))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
            ctx.fill(path, with: .color(FieldFramesTheme.paperDim.opacity(0.7)))
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().strokeBorder(FieldFramesTheme.paperDim.opacity(0.4), lineWidth: 1))
    }
}
