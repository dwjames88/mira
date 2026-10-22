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

struct PresetCardView: View {
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
        .background { if model.transfer.sharingEnabled { ShareAnchor(transfer: model.transfer, id: preset.id) } }
        .contextMenu {
            if model.transfer.sharingEnabled {
                Button("Share\u{2026}") { model.transfer.share(preset) }
                Button("Export\u{2026}") { model.transfer.export(preset) }
                Divider()
            }
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

/// A labelled group in the FILMS strip: a mono label with the count, a hairline under it, then the cards.
struct StripGroup<Content: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: T.cells(1)) {
                Text(title).ffLabel(color: T.paperMid)
                Text(String(format: "%02d", count)).ffLabel(size: 9, color: T.paperDim)
            }
            .padding(.leading, 4)
            .frame(height: T.rows(1.5), alignment: .leading)
            FFHairline()
            HStack(alignment: .top, spacing: T.cells(1)) { content }
                .padding(.top, T.rows(1) / 2)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

/// The user's presets, first in the strip: one card each, or a single "SAVE A PRESET" slot when there are none.
struct PresetGroup: View {
    @Bindable var model: EditorModel

    var body: some View {
        StripGroup(title: "Presets", count: model.presets.count) {
            if model.presets.isEmpty {
                PresetEmptySlot(model: model)
            } else {
                ForEach(model.presets) { preset in
                    PresetCardView(model: model, preset: preset)
                }
            }
        }
    }
}

/// Where the preset cards go before there are any: the size of a film card, in the theme's hairline style.
private struct PresetEmptySlot: View {
    @Bindable var model: EditorModel
    @State private var hovering = false

    var body: some View {
        Button { model.beginSavePreset() } label: {
            VStack(alignment: .leading, spacing: 0) {
                VStack(spacing: T.rows(0.5)) {
                    Text("+").font(T.display(26, weight: .medium)).foregroundStyle(T.paperMid)
                    Text("Save a preset").ffLabel(size: 10, color: hovering ? T.paper : T.paperMid)
                }
                .frame(width: FilmCard.width, height: FilmCard.thumbnailHeight)
                .overlay(Rectangle().strokeBorder(T.hair, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                Text("Film and develop")
                    .font(T.display(16, weight: .medium))
                    .foregroundStyle(T.paperDim)
                    .padding(.top, 6)
                    .frame(width: FilmCard.width, alignment: .leading)
                Text("Keep a look")
                    .ffLabel(size: 9, color: T.paperDim)
                    .frame(width: FilmCard.width, height: T.rows(1), alignment: .leading)
            }
            .padding(4)
            .overlay(Rectangle().strokeBorder(hovering ? T.hair : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.source == nil)
        .onHover { hovering = $0 }
        .help("Save the film and develop settings as a preset \u{21E7}\u{2318}S")
        .accessibilityLabel("Save a preset")
    }
}
