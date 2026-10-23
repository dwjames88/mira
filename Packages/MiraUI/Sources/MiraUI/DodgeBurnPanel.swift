import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

extension DodgeBurnMode {
    var title: String {
        switch self {
        case .dodge: "Dodge"
        case .burn: "Burn"
        case .erase: "Erase"
        }
    }
}

extension DodgeBurnRange {
    var title: String {
        switch self {
        case .shadows: "Shadows"
        case .midtones: "Midtones"
        case .highlights: "Highlights"
        }
    }

    var abbreviation: String {
        switch self {
        case .shadows: "SHD"
        case .midtones: "MID"
        case .highlights: "HIL"
        }
    }
}

/// The DODGE & BURN group of the DEVELOP tab: the PAINT switch that opens the brush tool, the brush
/// (or the selected stroke) with its sliders, tone range, protect tones and luminosity range, the
/// stroke list, and the mask overlay switch.
public struct DodgeBurnPanel: View {
    @Bindable private var model: EditorModel

    public init(model: EditorModel) {
        self.model = model
    }

    private var tool: DodgeBurnToolState { model.dodgeBurnTool }
    private var strokes: [DodgeBurnStroke] { model.recipe.dodgeBurn.strokes }
    private var settings: DodgeBurnStroke { model.paintSettings }
    private var selected: DodgeBurnStroke? {
        tool.selectedStrokeID.flatMap { id in strokes.first { $0.id == id } }
    }
    private var showsSettings: Bool { tool.isActive || selected != nil }

    /// A 0...1 stroke value shown as 0...100.
    private func percent(_ key: WritableKeyPath<DodgeBurnStroke, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: key] * 100 }, set: { model.setPaint(key, $0 / 100) })
    }

    public var body: some View {
        InspectorGroup("dodgeBurn", title: "Dodge & burn", trailing: strokes.isEmpty ? nil : String(format: "%02d", strokes.count)) {
            VStack(alignment: .leading, spacing: 0) {
                paintRow
                if showsSettings { brushSettings }
                strokeList
                FFToggle("Mask overlay", isOn: Binding(get: { tool.maskOverlay }, set: { model.setMaskOverlay($0) }))
                    .padding(.top, 4)
                    .padding(.bottom, 4)
                    .help("Show where the strokes apply as a red wash (O while painting)")
                Text(hint)
                    .ffLabel(size: 9, color: T.paperDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
    }

    private var hint: String {
        tool.isActive
            ? "Drag on the photo. [ ] size \u{00B7} \u{2325} flips dodge and burn \u{00B7} O mask \u{00B7} \u{2318}= \u{2318}- zoom \u{00B7} Esc leaves"
            : "Paint light onto the photo. Strokes stay with the photo, not with presets."
    }

    // MARK: Paint

    private var paintRow: some View {
        FFToggle("Paint", isOn: Binding(get: { tool.isActive }, set: { model.setDodgeBurnTool($0) }))
            .padding(.vertical, 4)
            .disabled(model.source == nil || model.isCropping)
            .help("Paint dodge and burn on the photo \u{2014} Esc leaves")
    }

    // MARK: Brush settings

    private var brushSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if let s = selected, let index = strokes.firstIndex(where: { $0.id == s.id }) {
                    Text("Stroke \(String(format: "%02d", index + 1)) \u{00B7} \(s.mode.title)").ffLabel(color: T.lichen)
                    Spacer()
                    Button { model.selectStroke(nil) } label: { Text("Brush").ffLabel(color: T.lichen) }
                        .buttonStyle(.plain)
                        .help("Back to the brush settings")
                } else {
                    Text("Brush").ffLabel(color: T.lichen)
                    Spacer()
                }
            }
            .frame(height: T.rows(1))
            FFTabBar(DodgeBurnMode.allCases.map { (value: $0, title: $0.title) },
                     selection: Binding(get: { settings.mode }, set: { model.setPaint(\.mode, $0) }))
            FFSlider("Size", value: percent(\.size), in: 0.4...50, default: 8, decimals: 1)
            FFSlider("Feather", value: percent(\.feather), in: 0...100, default: 60, decimals: 0)
            FFSlider("Flow", value: percent(\.flow), in: 1...100, default: 25, decimals: 0)
            if settings.mode != .erase {
                FFSlider("Strength", value: percent(\.strength), in: 0...100, default: 50, decimals: 0)
                Text("Range").ffLabel(color: T.paperDim).frame(height: T.rows(1), alignment: .leading)
                FFTabBar(DodgeBurnRange.allCases.map { (value: $0, title: $0.title) },
                         selection: Binding(get: { settings.range }, set: { model.setPaint(\.range, $0) }))
                FFToggle("Protect tones", isOn: Binding(get: { settings.protectTones }, set: { model.setPaint(\.protectTones, $0) }))
                    .padding(.top, 4)
                    .help("Soft-limit the change: dodge never clips highlights, burn never crushes to black")
                FFToggle("Luminosity range", isOn: Binding(get: { settings.lumaRange != nil }, set: setLumaRange))
                    .padding(.bottom, 4)
                    .help("Only act on pixels in a band of tones")
                if let luma = settings.lumaRange {
                    lumaSliders(luma)
                }
            }
        }
        .padding(.bottom, 4)
    }

    private func setLumaRange(_ on: Bool) {
        model.setPaint(\.lumaRange, on ? LumaRange(low: 0.2, high: 0.8, softness: 0.1) : nil)
    }

    private func lumaBinding(_ key: WritableKeyPath<LumaRange, Double>, fallback: LumaRange) -> Binding<Double> {
        Binding(get: { (settings.lumaRange ?? fallback)[keyPath: key] * 100 }, set: { v in
            var l = settings.lumaRange ?? fallback
            l[keyPath: key] = v / 100
            // Keep low at or under high.
            if key == \LumaRange.low, l.low > l.high { l.high = l.low }
            if key == \LumaRange.high, l.high < l.low { l.low = l.high }
            model.setPaint(\.lumaRange, l.clamped)
        })
    }

    @ViewBuilder
    private func lumaSliders(_ luma: LumaRange) -> some View {
        FFSlider("Low", value: lumaBinding(\.low, fallback: luma), in: 0...100, default: 0, decimals: 0)
        FFSlider("High", value: lumaBinding(\.high, fallback: luma), in: 0...100, default: 100, decimals: 0)
        FFSlider("Softness", value: lumaBinding(\.softness, fallback: luma), in: 0...50, default: 10, decimals: 0)
    }

    // MARK: Strokes

    @ViewBuilder
    private var strokeList: some View {
        if !strokes.isEmpty {
            HStack {
                Text("Strokes").ffLabel(color: T.paperDim)
                FFHairline()
                Button { model.clearAllStrokes() } label: { Text("Clear all").ffLabel(color: T.lichen) }
                    .buttonStyle(.plain)
                    .help("Remove every dodge and burn stroke from this photo")
            }
            .frame(height: T.rows(1))
            .padding(.top, 4)
            VStack(spacing: 0) {
                ForEach(Array(strokes.enumerated()), id: \.element.id) { index, stroke in
                    StrokeRow(model: model, index: index, stroke: stroke, isSelected: stroke.id == tool.selectedStrokeID)
                }
            }
            .padding(.bottom, 4)
        }
    }
}

private struct StrokeRow: View {
    let model: EditorModel
    let index: Int
    let stroke: DodgeBurnStroke
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Button { model.selectStroke(isSelected ? nil : stroke.id) } label: {
                HStack(spacing: 6) {
                    Text(String(format: "%02d", index + 1)).font(T.mono(9)).foregroundStyle(T.paperDim)
                    Text(stroke.mode.title).ffLabel(size: 10, color: stroke.hidden ? T.paperDim : T.paper)
                    if stroke.mode != .erase {
                        Text(stroke.range.abbreviation).ffLabel(size: 9, color: T.paperDim)
                    }
                    Spacer(minLength: 0)
                    if stroke.mode != .erase {
                        Text("\(Int((stroke.strength * 100).rounded()))%")
                            .font(T.mono(10)).monospacedDigit()
                            .foregroundStyle(stroke.hidden ? T.paperDim : T.paperMid)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isSelected ? "Back to the brush" : "Edit this stroke")
            .accessibilityLabel("Stroke \(index + 1), \(stroke.mode.title)")
            .accessibilityValue(stroke.hidden ? "Hidden" : "Shown")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            iconButton(stroke.hidden ? "eye.slash" : "eye", help: stroke.hidden ? "Show stroke" : "Hide stroke") {
                model.toggleStrokeHidden(stroke.id)
            }
            iconButton("xmark", help: "Delete stroke") { model.deleteStroke(stroke.id) }
        }
        .padding(.horizontal, 4)
        .frame(height: T.rows(1.5))
        .overlay(Rectangle().strokeBorder(isSelected ? T.lichen : Color.clear, lineWidth: 1))
    }

    private func iconButton(_ name: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name)
                .font(.system(size: 10))
                .foregroundStyle(T.paperMid)
                .frame(width: 20, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
