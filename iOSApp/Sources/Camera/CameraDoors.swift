import MiraCamera
import MiraCameraKit
import MiraCore
import MiraUI
import SwiftUI

private typealias T = FieldFramesTheme

// MARK: Film door

/// The camera's film door: the editor's FILMS panel (card strip, then a stock's options behind "‹ FILMS")
/// on an ink-soft panel, with GRAIN rows at the end of the options panel.
struct CameraFilmDoor: View {
    let model: CameraFilmDoorModel
    /// FINDER grain: LIVE animates grain in the viewfinder, OFF holds it still. The captured frame is unaffected.
    @Binding var grain: Bool
    var onClose: () -> Void = {}
    /// Overrides the panel cap the options panel scrolls under; nil keeps the environment's.
    var maxHeight: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            DoorHandle(label: "Close films", onClose: onClose)
            FilmsPanel(model: model) { GrainRows(model: model, grain: $grain) }
        }
        .ffPanel()
        .transformEnvironment(\.panelMaxHeight) { cap in if let maxHeight { cap = maxHeight } }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Films")
    }
}

/// GRAIN: FINDER OFF / LIVE, AMOUNT, SIZE. The slider labels and ranges are the editor's DEVELOP EFFECTS grain sliders.
struct GrainRows: View {
    @Bindable var model: CameraFilmDoorModel
    @Binding var grain: Bool

    var body: some View {
        VStack(spacing: 0) {
            FFHairline().padding(.vertical, T.rows(0.5))
            HStack {
                Text("GRAIN").ffLabel(size: 10, color: T.paperMid)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, T.cells(2))
            .frame(height: T.rows(1.5))
            ChipRow(label: "FINDER", selected: grain ? "LIVE" : "OFF") {
                OptionChip(title: "OFF", selected: !grain, accessibilityLabel: "Finder grain off") { grain = false }
                OptionChip(title: "LIVE", selected: grain, accessibilityLabel: "Finder grain live") { grain = true }
            }
            grainSlider("AMOUNT", value: model.bind(\.grainAmount), accessibility: "Grain amount")
            grainSlider("SIZE", value: model.bind(\.grainSize), accessibility: "Grain size")
        }
    }

    private func grainSlider(_ label: String, value: Binding<Double>, accessibility: String) -> some View {
        let def = FilmCharacter.nativeSlider
        return FFSlider(label, value: value, in: 0...1, default: def)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 2).onEnded { value.wrappedValue = def })
            .padding(.horizontal, T.cells(2))
            .accessibilityLabel(accessibility)
    }
}

// MARK: White balance door

/// One chip row: AUTO, the four presets, then LOCK (holds the current value; lichen when on).
struct CameraWBDoor: View {
    @Binding var state: WhiteBalanceState
    var onClose: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            DoorHandle(label: "Close white balance", onClose: onClose)
            ChipRow(label: "WB", selected: state.preset == .auto ? "AUTO" : title(state.preset)) {
                ForEach(WhiteBalancePreset.allCases, id: \.self) { preset in
                    OptionChip(title: title(preset), selected: state.preset == preset,
                               accessibilityLabel: "White balance " + preset.accessibilityLabel.lowercasedFirst) {
                        state.preset = preset
                    }
                }
                OptionChip(title: "LOCK", selected: state.locked, selectedColor: T.lichen,
                           accessibilityLabel: "White balance lock") {
                    state.locked.toggle()
                }
            }
            .padding(.bottom, T.rows(0.5))
        }
        .ffPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("White balance")
    }

    private func title(_ preset: WhiteBalancePreset) -> String { preset.kelvin.map(String.init) ?? "AUTO" }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

// MARK: Shared

/// The door's top edge: a chevron to close, and a drag down closes too.
private struct DoorHandle: View {
    let label: String
    let onClose: () -> Void

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) { onClose() }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(T.paperMid)
                .frame(maxWidth: .infinity, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .gesture(DragGesture(minimumDistance: 12).onEnded { value in
            if value.translation.height > 24 { withAnimation(.snappy(duration: 0.22)) { onClose() } }
        })
    }
}
