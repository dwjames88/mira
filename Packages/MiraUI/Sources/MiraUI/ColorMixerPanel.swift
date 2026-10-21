import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

private extension ColorRange {
    var color: Color {
        let s = swatch
        return Color(.sRGB, red: s.r, green: s.g, blue: s.b)
    }
}

/// The COLOR MIXER group: a row of range swatches, hue / saturation / luminance sliders for the
/// selected range, a summary of what has moved, reset buttons and an eyedropper that picks a range
/// from the canvas.
public struct ColorMixerPanel: View {
    @Bindable private var model: EditorModel

    public init(model: EditorModel) {
        self.model = model
    }

    private func binding(_ key: WritableKeyPath<ColorAdjust, Double>) -> Binding<Double> {
        Binding(
            get: { model.recipe.colorMixer[model.mixerRange][keyPath: key] * 100 },
            set: { model.recipe.colorMixer[model.mixerRange][keyPath: key] = $0 / 100 })
    }

    public var body: some View {
        InspectorGroup("colorMixer", title: "Color mixer") {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    ForEach(ColorRange.allCases, id: \.self) { range in swatch(range) }
                    Spacer(minLength: 0)
                    eyedropper
                }
                .padding(.vertical, 4)
                Text(model.mixerRange.displayName)
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
                    .accessibilityLabel("Changed ranges")
                HStack(spacing: T.cells(2)) {
                    resetButton("Reset range", disabled: model.recipe.colorMixer[model.mixerRange].isZero) {
                        model.recipe.colorMixer[model.mixerRange] = .zero
                    }
                    resetButton("Reset all", disabled: model.recipe.colorMixer.isIdentity) {
                        model.recipe.colorMixer = .identity
                    }
                    Spacer()
                }
                .frame(height: T.rows(2))
            }
        }
    }

    private func swatch(_ range: ColorRange) -> some View {
        let isSelected = range == model.mixerRange
        let changed = !model.recipe.colorMixer[range].isZero
        return Button { model.mixerRange = range } label: {
            Rectangle().fill(range.color)
                .frame(width: 18, height: 18)
                .overlay(Rectangle().strokeBorder(isSelected ? T.lichen : T.hair, lineWidth: isSelected ? 2 : 1))
                .overlay(alignment: .bottom) {
                    if changed { Rectangle().fill(T.paper).frame(width: 6, height: 2).padding(.bottom, 2) }
                }
                .padding(2)
        }
        .buttonStyle(.plain)
        .help(range.displayName)
        .accessibilityLabel(range.displayName)
        .accessibilityValue(changed ? "Changed" : "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var eyedropper: some View {
        Button { model.eyedropperActive.toggle() } label: {
            Image(systemName: "eyedropper")
                .font(.system(size: 11))
                .foregroundStyle(model.eyedropperActive ? T.lichen : T.paperMid)
                .frame(width: 24, height: 22)
                .overlay(Rectangle().strokeBorder(model.eyedropperActive ? T.lichen : T.hair, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Pick a range from the photo")
        .accessibilityLabel("Eyedropper")
        .accessibilityValue(model.eyedropperActive ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
    }

    private func resetButton(_ title: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).ffLabel(color: disabled ? T.paperDim.opacity(0.5) : T.lichen)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    /// `RED H+20 S-10 · ORANGE L+5`, or a note when nothing has moved.
    private var summary: String {
        let parts = model.recipe.colorMixer.changedRanges.map { range -> String in
            let a = model.recipe.colorMixer[range]
            var s = range.displayName
            for (letter, v) in [("H", a.hue), ("S", a.saturation), ("L", a.luminance)] where v != 0 {
                let n = Int((v * 100).rounded())
                s += " \(letter)\(n > 0 ? "+" : "")\(n)"
            }
            return s
        }
        return parts.isEmpty ? "All ranges at zero" : parts.joined(separator: " \u{00B7} ")
    }
}
