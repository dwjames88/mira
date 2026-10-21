import SwiftUI

private typealias T = FieldFramesTheme

/// `UserDefaults` keys for the app's settings.
public enum MiraSettings {
    /// Shows the mono edit-source footer under the editor.
    public static let showEditSourceFooterKey = "mira.showEditSourceFooter"
}

/// The Settings window (⌘,). Minimal for now; add new sections below GENERAL.
public struct SettingsView: View {
    @AppStorage(MiraSettings.showEditSourceFooterKey) private var showEditSourceFooter = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings")
                .font(T.display(40, weight: .regular))
                .foregroundStyle(T.paper)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, T.rows(2))
            FFSectionLabel("General")
                .padding(.top, T.rows(2))
            FFPanel {
                VStack(alignment: .leading, spacing: T.rows(1)) {
                    FFToggle("Show edit-source footer", isOn: $showEditSourceFooter)
                    Text("A status line under the editor that says where the edit is stored and whether the original is kept.")
                        .font(.system(size: 11))
                        .foregroundStyle(T.paperDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(T.cells(2))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .overlay(Rectangle().strokeBorder(T.hair, lineWidth: 1))
            .padding(.top, T.rows(1))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, T.cells(4))
        .padding(.bottom, T.rows(2))
        .frame(width: T.cells(60), height: T.rows(24), alignment: .topLeading)
        .fieldFramesSecondaryChrome()
    }
}
