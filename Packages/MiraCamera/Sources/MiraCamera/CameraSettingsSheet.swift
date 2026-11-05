#if os(iOS)
import MiraCameraKit
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// Minimal camera settings: silent shutter (only where the device allows it), location, and the developer-facing finder quality.
struct CameraSettingsSheet: View {
    @Bindable var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            FFGroundBackground(base: T.inkSoft, grain: 0.07).ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: T.rows(1)) {
                    HStack {
                        Text("Camera").font(T.display(24, weight: .regular))
                        Spacer()
                        Button("DONE") { dismiss() }.buttonStyle(.ff).accessibilityLabel("Done")
                    }
                    FFSectionLabel("SHUTTER")
                    if model.silentShutterSupported {
                        FFToggle("SILENT SHUTTER", isOn: $model.settings.silentShutter)
                        Text("Some regions require the shutter sound. Where it is required, it still plays.")
                            .font(.system(size: 12)).foregroundStyle(T.paperDim)
                    } else {
                        Text("This device always plays the shutter sound.").font(.system(size: 12)).foregroundStyle(T.paperDim)
                    }
                    FFSectionLabel("LOCATION")
                    FFToggle("ADD LOCATION TO FRAMES", isOn: $model.settings.addLocation)
                    Text("Off by default. The location goes into the picture's metadata only; Mira sends nothing anywhere.")
                        .font(.system(size: 12)).foregroundStyle(T.paperDim)
                    FFSectionLabel("ADVANCED")
                    FFToggle("FINDER GRAIN: LIVE", isOn: $model.settings.finderGrainLive)
                    qualityRow
                    if model.statsEnabled, let s = model.stats {
                        Text(String(format: "%.1f MS \u{00B7} %.0f FPS \u{00B7} %@", s.medianMS, s.fps, String(describing: s.level).uppercased()))
                            .ffLabel(size: 10, color: T.paperMid)
                            .accessibilityLabel("Finder statistics")
                    }
                }
                .padding(T.cells(2))
            }
        }
        .foregroundStyle(T.paper)
        .tint(T.lichen)
    }

    private var qualityRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FINDER QUALITY").ffLabel(size: 10, color: T.paperDim)
            HStack(spacing: 6) {
                ForEach(FinderQualityMode.allCases, id: \.self) { mode in
                    let on = model.settings.finderQuality == mode
                    Button { model.settings.finderQuality = mode } label: {
                        Text(Self.title(mode)).ffLabel(size: 9, color: on ? T.paper : T.paperDim)
                            .lineLimit(1).minimumScaleFactor(0.7)
                            .padding(.horizontal, 6).frame(minHeight: 32)
                            .overlay(Rectangle().stroke(on ? T.lichen : T.hair, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Finder quality \(Self.title(mode).lowercased())")
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    static func title(_ mode: FinderQualityMode) -> String {
        switch mode {
        case .auto: "AUTO"
        case .full: "FULL"
        case .halfTexture: "HALF TEXTURE"
        case .grainOff: "GRAIN OFF"
        case .reduced: "REDUCED"
        }
    }
}
#endif
