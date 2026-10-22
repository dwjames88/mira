import AppKit
import SwiftUI

/// The stages of the development workflow. The sub-toolbar shows them as tabs; the right
/// panel and the strip under the canvas follow the selected one.
public enum EditorTab: String, CaseIterable, Identifiable, Sendable {
    case films, presets, develop, crop

    public var id: String { rawValue }

    /// The mono label in the sub-toolbar (shown uppercase by the label style).
    public var title: String {
        switch self {
        case .films: "Films"
        case .presets: "Presets"
        case .develop: "Develop"
        case .crop: "Crop"
        }
    }

    /// The key that selects the tab, with no modifier.
    public var key: String {
        switch self {
        case .films: "1"
        case .presets: "4"
        case .develop: "2"
        case .crop: "3"
        }
    }

    public static func forKey(_ key: String) -> EditorTab? {
        allCases.first { $0.key == key }
    }
}

/// What the host app adds to the sub-toolbar. The Photos extension passes nothing: it shows the
/// tabs only, because Photos supplies its own Save and there is no library to go back to.
public struct EditorHostBar {
    public struct Save {
        public var isEnabled: Bool
        /// True right after a successful save: the button reads SAVED and is inert.
        public var isSaved: Bool
        public var action: @MainActor () -> Void

        public init(isEnabled: Bool, isSaved: Bool, action: @escaping @MainActor () -> Void) {
            self.isEnabled = isEnabled
            self.isSaved = isSaved
            self.action = action
        }
    }

    /// `← LIBRARY`: nil hides it.
    public var onLibrary: (@MainActor () -> Void)?
    /// Small mono status (UNSAVED, SAVED, REVERTED, READ ONLY, ...), nil for none.
    public var status: String?
    public var statusHelp: String?
    /// nil hides the SAVE button.
    public var save: Save?

    public init(onLibrary: (@MainActor () -> Void)? = nil, status: String? = nil, statusHelp: String? = nil,
                save: Save? = nil) {
        self.onLibrary = onLibrary
        self.status = status
        self.statusHelp = statusHelp
        self.save = save
    }
}
