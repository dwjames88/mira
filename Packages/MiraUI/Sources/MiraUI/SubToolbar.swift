import SwiftUI

private typealias T = FieldFramesTheme

/// The strip under the title bar while a photo is open: `← LIBRARY` (app only), the FILMS /
/// DEVELOP / CROP tabs, then the status and SAVE (app only). Ink-soft with grain and a hairline
/// underneath; the active tab has a 1 px lichen underline that sits on that hairline.
struct EditorSubToolbar: View {
    @Bindable var model: EditorModel
    let host: EditorHostBar?

    static let height: CGFloat = T.rows(2.5)

    /// Which optional items the bar shows. The Photos extension (no host) shows the tabs only.
    struct Items: Equatable {
        var library: Bool
        var status: Bool
        var save: Bool

        init(host: EditorHostBar?) {
            library = host?.onLibrary != nil
            status = host?.status != nil
            save = host?.save != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                if let onLibrary = host?.onLibrary {
                    Button(action: onLibrary) {
                        Text("\u{2190} Library")
                            .ffLabel(color: T.paperMid)
                            .padding(.horizontal, T.cells(1))
                            .frame(height: Self.height)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Back to the library \u{2318}\u{2190}")
                    .accessibilityLabel("Back to the library")
                    Rectangle().fill(T.hair).frame(width: 1, height: T.rows(1)).padding(.horizontal, T.cells(2))
                }
                HStack(spacing: T.cells(3)) {
                    ForEach(EditorTab.allCases) { tab in
                        TabButton(tab: tab, selected: model.tab == tab,
                                  enabled: tab != .crop || model.source != nil) { model.selectTab(tab) }
                    }
                }
                Spacer(minLength: T.cells(2))
                if let host {
                    if let status = host.status {
                        Text(status)
                            .ffLabel(size: 10, color: status == "UNSAVED" ? T.paperMid : T.lichen)
                            .lineLimit(1)
                            .padding(.trailing, T.cells(2))
                            .help(host.statusHelp ?? "")
                    }
                    if let save = host.save {
                        Button(save.isSaved ? "Saved" : "Save", action: save.action)
                            .buttonStyle(FFButtonStyle(prominent: true))
                            .disabled(!save.isEnabled || save.isSaved)
                            .help("Save \u{2318}S")
                    }
                }
            }
            .padding(.horizontal, T.cells(2))
            .frame(height: Self.height)
            .background(alignment: .bottom) { FFHairline() }
        }
        .ffPanel()
    }

    private struct TabButton: View {
        let tab: EditorTab
        let selected: Bool
        let enabled: Bool
        let action: () -> Void

        var body: some View {
            Button(action: action) {
                Text(tab.title)
                    .ffLabel(color: selected ? T.paper : T.paperMid, weight: selected ? .medium : .regular)
                    .lineLimit(1)
                    .padding(.horizontal, T.cells(0.5))
                    .frame(height: EditorSubToolbar.height)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(selected ? T.lichen : Color.clear).frame(height: 1)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .help("\(tab.title) (\(tab.key))")
            .accessibilityLabel(tab.title)
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        }
    }
}
