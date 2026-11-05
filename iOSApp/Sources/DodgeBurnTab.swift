import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

/// The DODGE & BURN step. Painting is not on iPhone yet, so this lists the strokes the photo already
/// carries (made on the Mac or in Photos) read-only; they render and save with the photo as before.
struct DodgeBurnTab: View {
    @Bindable var model: EditorViewModel

    private var strokes: [DodgeBurnStroke] { model.recipe.dodgeBurn.strokes }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Strokes").ffLabel(color: T.paperDim)
                FFHairline()
                if !strokes.isEmpty {
                    Text(String(format: "%02d", strokes.count)).ffLabel(color: T.lichen)
                }
            }
            .frame(height: T.rows(1.5))
            .padding(.horizontal, T.cells(2))
            if strokes.isEmpty {
                Text("No dodge and burn strokes on this photo.")
                    .ffLabel(size: 10, color: T.paperDim)
                    .padding(.horizontal, T.cells(2))
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(strokes.enumerated()), id: \.element.id) { index, stroke in
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", index + 1)).font(T.mono(10)).foregroundStyle(T.paperDim)
                                Text(label(stroke.mode)).ffLabel(size: 11, color: stroke.hidden ? T.paperDim : T.paper)
                                if stroke.mode != .erase {
                                    Text(stroke.range.rawValue.uppercased()).ffLabel(size: 10, color: T.paperDim)
                                }
                                Spacer(minLength: 0)
                                if stroke.mode != .erase {
                                    Text("\(Int((stroke.strength * 100).rounded()))%")
                                        .font(T.mono(11)).monospacedDigit()
                                        .foregroundStyle(stroke.hidden ? T.paperDim : T.paperMid)
                                }
                            }
                            .frame(minHeight: 32)
                            .padding(.horizontal, T.cells(2))
                        }
                    }
                }
            }
            Text("Painting dodge and burn is on the Mac. Strokes stay with the photo, not with presets.")
                .ffLabel(size: 9, color: T.paperDim)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, T.cells(2))
                .padding(.vertical, T.rows(1))
        }
    }

    private func label(_ mode: DodgeBurnMode) -> String {
        switch mode {
        case .dodge: "DODGE"
        case .burn: "BURN"
        case .erase: "ERASE"
        }
    }
}
