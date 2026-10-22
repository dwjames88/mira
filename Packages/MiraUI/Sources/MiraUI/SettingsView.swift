import SwiftUI

private typealias T = FieldFramesTheme

/// `UserDefaults` keys for the app's settings.
public enum MiraSettings {
    /// Shows the mono edit-source footer under the editor.
    public static let showEditSourceFooterKey = "mira.showEditSourceFooter"
    /// Checks GitHub for a newer release at launch (on unless turned off). Same key as `UpdatePreferences.autoCheckKey`.
    public static let checkForUpdatesKey = "mira.updates.autoCheck"
}

/// The Settings window (⌘,). Minimal for now; add new sections below GENERAL.
public struct SettingsView: View {
    @AppStorage(MiraSettings.showEditSourceFooterKey) private var showEditSourceFooter = false

    @AppStorage(MiraSettings.checkForUpdatesKey) private var checkForUpdates = true

    @AppStorage(AppearancePreference.key) private var appearance = AppearancePreference.system.rawValue

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
                    HStack(spacing: T.cells(3)) {
                        Text("APPEARANCE").ffLabel(color: T.paperMid)
                        FFTabBar(AppearancePreference.allCases.map { (value: $0.rawValue, title: $0.rawValue.uppercased()) },
                                 selection: $appearance)
                    }
                    FFHairline()
                    FFToggle("Show edit-source footer", isOn: $showEditSourceFooter)
                    Text("A status line under the editor that says where the edit is stored and whether the original is kept.")
                        .font(.system(size: 11))
                        .foregroundStyle(T.paperDim)
                        .fixedSize(horizontal: false, vertical: true)
                    FFHairline()
                    FFToggle("Check for updates automatically", isOn: $checkForUpdates)
                    Text("Once a day at launch, Mira asks GitHub for the latest release. You are only told when there is a newer one. Mira \u{25B8} Check for Updates\u{2026} always checks.")
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
        .frame(width: T.cells(60), height: T.rows(30), alignment: .topLeading)
        .fieldFramesSecondaryChrome()
    }
}
