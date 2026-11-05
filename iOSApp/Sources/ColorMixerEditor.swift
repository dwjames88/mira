import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

private extension ColorRange {
    var color: Color {
        let s = swatch
        return Color(.sRGB, red: s.r, green: s.g, blue: s.b)
    }
}

struct ColorMixerEditor: View {
    @Bindable var model: EditorViewModel
    @State private var range: ColorRange = .red

    private func binding(_ key: WritableKeyPath<ColorAdjust, Double>) -> Binding<Double> {
        Binding(
            get: { model.recipe.colorMixer[range][keyPath: key] * 100 },
            set: { model.recipe.colorMixer[range][keyPath: key] = $0 / 100 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FFSectionLabel("Color mixer")
            HStack(spacing: 6) {
                ForEach(ColorRange.allCases, id: \.self) { swatch($0) }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            Text(range.displayName)
                .ffLabel(color: T.lichen)
                .frame(height: T.rows(1), alignment: .leading)
                .padding(.bottom, 2)
            FFSlider("Hue", value: binding(\.hue), in: -100...100, default: 0, decimals: 0)
            FFSlider("Saturation", value: binding(\.saturation), in: -100...100, default: 0, decimals: 0)
            FFSlider("Luminance", value: binding(\.luminance), in: -100...100, default: 0, decimals: 0)
            Text(summary)
                .ffLabel(size: 9, color: T.paperDim)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: T.rows(1), alignment: .leading)
            HStack(spacing: T.cells(4)) {
                resetButton("Reset range", disabled: model.recipe.colorMixer[range].isZero) {
                    model.recipe.colorMixer[range] = .zero
                }
                resetButton("Reset all", disabled: model.recipe.colorMixer.isIdentity) {
                    model.recipe.colorMixer = .identity
                }
                Spacer()
            }
        }
    }

    private func swatch(_ r: ColorRange) -> some View {
        let isSel = r == range
        let changed = !model.recipe.colorMixer[r].isZero
        return Button { range = r } label: {
            Rectangle().fill(r.color)
                .frame(width: 28, height: 28)
                .overlay(Rectangle().strokeBorder(isSel ? T.lichen : T.hair, lineWidth: isSel ? 2 : 1))
                .overlay(alignment: .bottom) {
                    if changed { Rectangle().fill(T.paper).frame(width: 8, height: 2).padding(.bottom, 3) }
                }
                .padding(2)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(r.displayName)
        .accessibilityValue(changed ? "Changed" : "")
        .accessibilityAddTraits(isSel ? .isSelected : [])
    }

    private func resetButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).ffLabel(color: disabled ? T.paperDim.opacity(0.5) : T.lichen)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var summary: String {
        let parts = model.recipe.colorMixer.changedRanges.map { r -> String in
            let a = model.recipe.colorMixer[r]
            var s = r.displayName
            for (letter, v) in [("H", a.hue), ("S", a.saturation), ("L", a.luminance)] where v != 0 {
                let n = Int((v * 100).rounded())
                s += " \(letter)\(n > 0 ? "+" : "")\(n)"
            }
            return s
        }
        return parts.isEmpty ? "All ranges at zero" : parts.joined(separator: " \u{00B7} ")
    }
}
