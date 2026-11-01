import MiraCore
import MiraUI
import SwiftUI

struct DevelopPanel: View {
    @Bindable var model: EditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: FieldFramesTheme.rows(0.5)) {
                    HistogramView(data: model.histogram)

                    FFSectionLabel("Light")
                    slider("Exposure", \.exposure, -2...2)
                    slider("Contrast", \.contrast, -1...1)
                    slider("Highlights", \.highlights, -1...1)
                    slider("Shadows", \.shadows, -1...1)
                    slider("Whites", \.whites, -1...1)
                    slider("Blacks", \.blacks, -1...1)

                    FFSectionLabel("Presence")
                    slider("Texture", \.texture, -1...1)
                    slider("Clarity", \.clarity, -1...1)
                    slider("Vibrance", \.vibrance, -1...1)
                    slider("Saturation", \.saturation, -1...1)

                    FFSectionLabel("Color")
                    slider("Temperature", \.warmth, -1...1)
                    slider("Tint", \.tint, -1...1)

                    CurvesEditor(model: model)
                    ColorMixerEditor(model: model)

                    FFSectionLabel("Effects")
                    slider("Grain", \.grainAmount, 0...1)
                    slider("Grain size", \.grainSize, 0...1, 0.5)
                    slider("Halation", \.halationAmount, 0...1)
                    slider("Halation radius", \.halationRadius, 0...1, 0.5)
                    slider("Bloom", \.bloomAmount, 0...1)

                    FFSectionLabel("Frame")
                    slider("Vignette", \.vignetteAmount, 0...1)
                    FFToggle("Border", isOn: model.bind(\.borderEnabled))
                    if model.recipe.borderEnabled {
                        slider("Border width", \.borderWidth, 0...0.3, 0.04)
                    }
                }
                .padding(FieldFramesTheme.cells(2))
            }
            FFHairline()
            HStack {
                Spacer()
                Button("Reset") { model.resetDevelop() }
                    .buttonStyle(FFButtonStyle())
                    .disabled(!model.canResetDevelop)
            }
            .padding(.horizontal, FieldFramesTheme.cells(2))
            .padding(.vertical, FieldFramesTheme.rows(0.5))
        }
        .ffPanel()
    }

    private func slider(_ label: String, _ keyPath: WritableKeyPath<Recipe, Double>,
                        _ range: ClosedRange<Double>, _ def: Double = 0) -> some View {
        FFSlider(label, value: model.bind(keyPath), in: range, default: def)
    }
}

struct HistogramView: View {
    let data: HistogramData

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
        .frame(height: FieldFramesTheme.rows(4))
        .frame(maxWidth: .infinity)
        .overlay(Rectangle().strokeBorder(FieldFramesTheme.paperDim.opacity(0.4), lineWidth: 1))
    }
}
