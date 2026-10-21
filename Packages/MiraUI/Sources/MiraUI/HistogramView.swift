import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

/// Live histogram of the picture on the canvas: red, green and blue as translucent fills,
/// luminance as a line, and clipping markers at both ends. About 64 pt tall.
public struct HistogramView: View {
    @Bindable private var model: EditorModel

    public init(model: EditorModel) {
        self.model = model
    }

    public var body: some View {
        HistogramPlot(data: model.histogram, height: 64)
            .onChange(of: model.displayedFrame?.id, initial: true) {
                model.histogramFrameChanged(model.displayedFrame)
            }
            .padding(.top, T.rows(1))
            .padding(.bottom, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Histogram")
            .accessibilityValue(summary)
    }

    private var summary: String {
        guard let h = model.histogram else { return "Not ready" }
        var parts: [String] = []
        if h.isClippingLow { parts.append("shadows clipped") }
        if h.isClippingHigh { parts.append("highlights clipped") }
        return parts.isEmpty ? "No clipping" : parts.joined(separator: ", ")
    }
}

/// The drawn histogram, without the model: ink ground, hairline frame, channel fills, luminance line.
struct HistogramPlot: View {
    let data: HistogramData?
    let height: CGFloat
    @Environment(\.colorScheme) private var scheme

    private static let channels: [(Color, KeyPath<HistogramData, [Float]>)] = [
        (Color(red: 0.93, green: 0.27, blue: 0.25), \.red),
        (Color(red: 0.30, green: 0.78, blue: 0.36), \.green),
        (Color(red: 0.28, green: 0.47, blue: 0.95), \.blue),
    ]

    var body: some View {
        let clipLow = data?.isClippingLow ?? false, clipHigh = data?.isClippingHigh ?? false
        Canvas { context, size in
            guard let data else { return }
            let scale = Self.peak(data)
            let blend: GraphicsContext.BlendMode = scheme == .dark ? .plusLighter : .multiply
            for (color, path) in Self.channels {
                let fill = Self.path(data[keyPath: path], size: size, peak: scale, closed: true)
                context.drawLayer { layer in
                    layer.blendMode = blend
                    layer.fill(fill, with: .color(color.opacity(scheme == .dark ? 0.55 : 0.45)))
                }
            }
            let line = Self.path(data.luminance, size: size, peak: scale, closed: false)
            context.stroke(line, with: .color(T.paper), lineWidth: 1)
        }
        .frame(height: height)
        .background(T.ink)
        .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
        .overlay(alignment: .topLeading) { marker(lit: clipLow, pointsRight: false) }
        .overlay(alignment: .topTrailing) { marker(lit: clipHigh, pointsRight: true) }
    }

    private func marker(lit: Bool, pointsRight: Bool) -> some View {
        Triangle(pointsRight: pointsRight)
            .fill(lit ? T.lichen : T.paperDim.opacity(0.45))
            .frame(width: 7, height: 7)
            .padding(3)
    }

    /// The tallest bin of the interior (the two end bins often hold a spike), at least a little.
    static func peak(_ data: HistogramData) -> Float {
        var peak: Float = 0.0001
        for i in 1..<255 { peak = max(peak, data.red[i], data.green[i], data.blue[i], data.luminance[i]) }
        return peak
    }

    static func path(_ bins: [Float], size: CGSize, peak: Float, closed: Bool) -> Path {
        var p = Path()
        guard bins.count == 256 else { return p }
        let w = size.width, h = size.height - 2
        if closed { p.move(to: CGPoint(x: 0, y: size.height)) }
        for i in 0..<256 {
            let v = CGFloat(min(1, bins[i] / peak))
            let pt = CGPoint(x: w * CGFloat(i) / 255, y: size.height - 1 - h * v.squareRoot() * 0.96)
            if i == 0 && !closed { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        if closed {
            p.addLine(to: CGPoint(x: w, y: size.height))
            p.closeSubpath()
        }
        return p
    }
}

private struct Triangle: Shape {
    let pointsRight: Bool
    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointsRight {
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        } else {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}
