import MiraCore
import SwiftUI

private typealias T = FieldFramesTheme

extension View {
    /// Secondary-window chrome shared with the main window: no system title text, an ink toolbar
    /// without glass, and content that starts below a hairline under the toolbar.
    public func fieldFramesSecondaryChrome() -> some View {
        self
            .fieldFramesWindow()
            .safeAreaInset(edge: .top, spacing: 0) { FFHairline() }
            .toolbar(removing: .title)
            .toolbarBackground(T.ink, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
    }
}

/// The About window: wordmark, version, byline, the film list and the credits.
public struct AboutView: View {
    private let library: FilmLibrary?
    private let version: String

    public init(library: FilmLibrary?, version: String = AboutView.bundleVersion()) {
        self.library = library
        self.version = version
    }

    /// `VERSION 0.1.0 (1)` from the main bundle.
    public static func bundleVersion(_ bundle: Bundle = .main) -> String {
        let info = bundle.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "VERSION \(short) (\(build))"
    }

    public var body: some View {
        FFScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Mira")
                    .font(T.display(72, weight: .regular))
                    .foregroundStyle(T.paper)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.top, T.rows(2))
                Text(version)
                    .ffLabel(size: 11, color: T.paperDim)
                    .padding(.top, 2)
                FFByline()
                    .padding(.top, T.rows(1) / 2)
                FFHairline()
                    .padding(.top, T.rows(2))
                if let library {
                    FilmsList(library: library)
                        .padding(.top, T.rows(1))
                } else {
                    Text("The film library could not be loaded.")
                        .ffLabel(color: T.paperDim)
                        .padding(.top, T.rows(2))
                }
                FFSectionLabel("Credits")
                    .padding(.top, T.rows(3))
                AttributionFooter()
                    .padding(.top, T.rows(1))
                    .padding(.bottom, T.rows(3))
            }
            .padding(.horizontal, T.cells(4))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, minHeight: 360)
        .fieldFramesSecondaryChrome()
    }
}
