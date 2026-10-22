import AppKit
import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

/// How a preset's name is set wherever it appears: the film name in the title style the cards
/// already use (colour inherited), a dim hyphen, the nickname in Cormorant italic lichen.
enum PresetText {
    static func name(film: String, nickname: String, size: CGFloat = 16) -> Text {
        Text("\(Text(film))\(nicknamePart(nickname, size: size, leading: " - "))")
    }

    /// "- Last Summer": the second line of a preset card.
    static func nicknamePart(_ nickname: String, size: CGFloat = 16, leading: String = "- ") -> Text {
        let dash = Text(leading).foregroundStyle(T.paperDim)
        let name = Text(nickname).font(T.displayItalic(size, weight: .medium)).foregroundStyle(T.lichen)
        return Text("\(dash)\(name)")
    }
}

/// The strip under the canvas on the PRESETS tab: the same card row as the film strip, with a header
/// row (count, notice, SAVE PRESET) where the film strip has its family tabs.
struct PresetStrip: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, T.cells(2))
            FFHairline()
            if model.presets.isEmpty {
                PresetEmptyNote()
                    .frame(maxWidth: .infinity)
                    .frame(height: T.rows(11))
            } else {
                FFScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: T.cells(1)) {
                        ForEach(model.presets) { preset in
                            PresetCardView(model: model, preset: preset)
                        }
                    }
                    .padding(.horizontal, T.cells(2) - 4)
                    .padding(.vertical, T.rows(1) / 2)
                }
                .frame(height: T.rows(11))
            }
        }
        .ffPanel()
        .onAppear { model.refreshPresets() }
        // The other process (app or Photos extension) may have saved presets meanwhile.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPresets()
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refreshPresets()
        }
    }

    private var header: some View {
        HStack(spacing: T.cells(2)) {
            Text(model.presets.isEmpty ? "No presets" : "\(model.presets.count) \(model.presets.count == 1 ? "preset" : "presets")")
                .ffLabel(color: T.paperDim)
            if let notice = model.presetNotice {
                Text(notice)
                    .ffLabel(size: 10, color: T.lichen)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityLabel(notice)
            }
            Spacer(minLength: T.cells(2))
            Button("Save Preset\u{2026}") { model.beginSavePreset() }
                .buttonStyle(.ff)
                .disabled(model.source == nil)
                .help("Save the film and develop settings as a preset \u{21E7}\u{2318}S")
        }
        .frame(height: T.rows(2.5))
    }
}

private struct PresetEmptyNote: View {
    var body: some View {
        VStack(spacing: T.rows(0.5)) {
            Text("No presets yet")
                .font(T.display(21, weight: .medium))
                .foregroundStyle(T.paper)
            Text("Choose a film and set the develop sliders, then SAVE PRESET and give the look a nickname, for example Portra 400 - Last Summer.")
                .font(.system(size: 12))
                .foregroundStyle(T.paperMid)
                .multilineTextAlignment(.center)
                .frame(maxWidth: T.cells(52))
        }
        .padding(T.cells(2))
    }
}

private struct PresetCardView: View {
    @Bindable var model: EditorModel
    let preset: Preset

    var body: some View {
        let missing = model.isFilmMissing(preset)
        FilmCard(
            title: Text(preset.filmName),
            secondLine: PresetText.nicknamePart(preset.nickname),
            accessibilityTitle: preset.displayName,
            caption: missing ? "Film missing" : (model.library.film(id: preset.filmID ?? "")?.brandCaption ?? "No film"),
            captionTint: missing ? T.paper : nil,
            image: model.presetThumbnails[preset.id],
            isSelected: model.appliedPresetID == preset.id,
            onHoverChange: { inside in
                if inside {
                    model.hoverPreset(preset.id)
                } else if model.hoveredTarget == .preset(preset.id) {
                    model.endHover()
                }
            }
        ) { model.applyPreset(preset.id) }
        .help(preset.displayName)
        .contextMenu {
            Button("Rename\u{2026}") { model.presetSheet = .rename(preset.id) }
            Button("Duplicate") { model.duplicatePreset(preset.id) }
            Divider()
            Button("Delete\u{2026}", role: .destructive) { model.presetPendingDelete = preset }
        }
    }
}

extension Film {
    /// "Kodak, 400" style caption the film cards use.
    var brandCaption: String { iso > 0 ? "\(brand) \u{00B7} \(iso)" : brand }
}

/// PRESETS in the right panel: what a preset is, the current look, and the SAVE PRESET button.
struct PresetsPanel: View {
    @Bindable var model: EditorModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Presets")
                    .font(T.display(26, weight: .medium))
                    .foregroundStyle(T.paper)
                    .frame(height: T.rows(2), alignment: .leading)
                Text(model.presets.isEmpty ? "None saved" : "\(model.presets.count) saved")
                    .ffLabel(color: T.lichen)
                    .frame(height: T.rows(1), alignment: .leading)
                Text("A preset keeps the film and every develop setting under a nickname. Click a card to apply it to this photo; the crop stays as it is, and you can keep adjusting afterwards.")
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(T.paperMid)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            .padding(.horizontal, T.cells(2))
            .padding(.top, T.rows(2))
            .padding(.bottom, T.rows(1))
            FFHairline()
            VStack(alignment: .leading, spacing: T.rows(0.5)) {
                FFSectionLabel("Current look").padding(.top, T.rows(1))
                Text(model.currentFilmName)
                    .font(T.display(21, weight: .medium))
                    .foregroundStyle(T.paper)
                    .lineLimit(1)
                Text(model.appliedPresetID.flatMap { id in model.presets.first { $0.id == id } }?.displayName ?? "Not saved as a preset")
                    .ffLabel(color: T.paperDim)
                    .lineLimit(2)
                Button("Save Preset\u{2026}") { model.beginSavePreset() }
                    .buttonStyle(.ffProminent)
                    .disabled(model.source == nil)
                    .padding(.top, T.rows(1))
                    .help("Save the film and develop settings as a preset \u{21E7}\u{2318}S")
                if let notice = model.presetNotice {
                    Text(notice)
                        .font(.system(size: 12))
                        .foregroundStyle(T.lichen)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, T.rows(1))
                }
            }
            .padding(.horizontal, T.cells(2))
            Spacer(minLength: 0)
        }
        .ffPanel()
    }
}
