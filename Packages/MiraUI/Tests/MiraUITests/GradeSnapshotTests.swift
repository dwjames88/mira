import AppKit
import MiraCore
import SwiftUI
import Testing
@testable import MiraUI

/// Headless looks at the histogram, curves and colour mixer: `build/snapshots/editor-curves-dark.png`
/// and `editor-mixer-light.png`.
@MainActor
@Suite("Grade snapshots", .serialized)
struct GradeSnapshotTests {
    private static func panels(_ model: EditorModel, channel: CurveChannel, selected: Int?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HistogramView(model: model)
            CurvesPanel(model: model, channel: channel, selected: selected)
            ColorMixerPanel(model: model)
        }
        .padding(.horizontal, FieldFramesTheme.cells(2))
        .frame(width: FieldFramesTheme.cells(36), alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .ffPanel()
        .foregroundStyle(FieldFramesTheme.paper)
    }

    @Test func curvesDark() async throws {
        FieldFramesTheme.registerFonts()
        let model = try await SnapshotTests.makeModel()
        model.recipe.curves.rgb = [CurvePoint(x: 0, y: 0.04), CurvePoint(x: 0.28, y: 0.2), CurvePoint(x: 0.62, y: 0.74), CurvePoint(x: 1, y: 1)]
        model.recipe.curves.red = [CurvePoint(x: 0, y: 0), CurvePoint(x: 0.5, y: 0.58), CurvePoint(x: 1, y: 1)]
        try await settle(model)
        try SnapshotTests.writePNG(Self.panels(model, channel: .rgb, selected: 2), size: CGSize(width: 288, height: 760),
                                   scheme: .dark, name: "editor-curves-panel-dark")
        try SnapshotTests.writePNG(EditorView(model: model), size: CGSize(width: 1280, height: 1100),
                                   scheme: .dark, name: "editor-curves-dark")
        model.cancelWork()
    }

    @Test func mixerLight() async throws {
        FieldFramesTheme.registerFonts()
        let model = try await SnapshotTests.makeModel()
        model.mixerRange = .orange
        model.recipe.colorMixer.orange = ColorAdjust(hue: 0.35, saturation: 0.4, luminance: -0.15)
        model.recipe.colorMixer.blue = ColorAdjust(hue: -0.2, saturation: 0, luminance: 0.1)
        try await settle(model)
        try SnapshotTests.writePNG(Self.panels(model, channel: .rgb, selected: nil), size: CGSize(width: 288, height: 760),
                                   scheme: .light, name: "editor-mixer-panel-light")
        try SnapshotTests.writePNG(EditorView(model: model), size: CGSize(width: 1280, height: 1100),
                                   scheme: .light, name: "editor-mixer-light")
        model.cancelWork()
    }

    private func settle(_ model: EditorModel) async throws {
        let before = model.previewFrame?.id
        let deadline = Date().addingTimeInterval(30)
        while model.previewFrame?.id == before || !model.isPreviewIdle, Date() < deadline { try await Task.sleep(for: .milliseconds(30)) }
        await model.refreshHistogramNow()
        try await Task.sleep(for: .milliseconds(200))
    }
}
