#if os(macOS)
import AppKit
import SwiftUI

/// The stages of the development workflow. The sub-toolbar shows them as tabs; the right
/// panel and the strip under the canvas follow the selected one.
public enum EditorTab: String, CaseIterable, Identifiable, Sendable {
    case crop, films, develop, dodgeBurn

    public var id: String { rawValue }

    /// The mono label in the sub-toolbar (shown uppercase by the label style).
    public var title: String {
        switch self {
        case .crop: "Crop"
        case .films: "Films"
        case .develop: "Develop"
        case .dodgeBurn: "Dodge & Burn"
        }
    }

    /// The key that selects the tab, with no modifier.
    public var key: String {
        switch self {
        case .crop: "1"
        case .films: "2"
        case .develop: "3"
        case .dodgeBurn: "4"
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

    /// The Share button: renders the look and opens the system share sheet. The action receives the
    /// button's frame in window coordinates (top-left origin) so the sheet hangs from it.
    public struct Share {
        public var isEnabled: Bool
        /// The picture is being rendered: the button shows progress and ignores clicks.
        public var isBusy: Bool
        public var action: @MainActor (CGRect?) -> Void

        public init(isEnabled: Bool, isBusy: Bool = false, action: @escaping @MainActor (CGRect?) -> Void) {
            self.isEnabled = isEnabled
            self.isBusy = isBusy
            self.action = action
        }

        /// Share needs a photo open, nothing loading or already rendering, and no open crop.
        public static func isAvailable(hasPhoto: Bool, isBusy: Bool, isCropping: Bool, isSharing: Bool) -> Bool {
            hasPhoto && !isBusy && !isCropping && !isSharing
        }
    }

    /// Photos-library actions for the open picture: a heart toggle and an ALBUM menu. Only the app passes
    /// one (the Photos extension has no library of its own to manage).
    public struct Library {
        public struct Album: Identifiable, Hashable, Sendable {
            public var id: String
            public var title: String
            public init(id: String, title: String) { self.id = id; self.title = title }
        }

        public var isFavorite: Bool
        public var toggleFavorite: @MainActor () -> Void
        /// Albums the picture can be added to, asked for when the menu opens.
        public var albums: @MainActor () -> [Album]
        public var addToAlbum: @MainActor (String) -> Void
        /// "New Album…": the host asks for a name and adds the picture to it.
        public var newAlbum: @MainActor () -> Void
        /// False hides the ALBUM menu (limited Photos access cannot see albums); the heart stays.
        public var showsAlbums: Bool

        public init(isFavorite: Bool, toggleFavorite: @escaping @MainActor () -> Void,
                    albums: @escaping @MainActor () -> [Album],
                    addToAlbum: @escaping @MainActor (String) -> Void,
                    newAlbum: @escaping @MainActor () -> Void, showsAlbums: Bool = true) {
            self.showsAlbums = showsAlbums
            self.isFavorite = isFavorite
            self.toggleFavorite = toggleFavorite
            self.albums = albums
            self.addToAlbum = addToAlbum
            self.newAlbum = newAlbum
        }
    }

    /// `← LIBRARY`: nil hides it.
    public var onLibrary: (@MainActor () -> Void)?
    /// Small mono status (UNSAVED, SAVED, REVERTED, READ ONLY, ...), nil for none.
    public var status: String?
    public var statusHelp: String?
    /// nil hides the SAVE button.
    public var save: Save?
    /// nil hides the Share button (the Photos extension has no file access).
    public var share: Share?
    /// nil hides the heart and ALBUM menu (the Photos extension).
    public var library: Library?

    public init(onLibrary: (@MainActor () -> Void)? = nil, status: String? = nil, statusHelp: String? = nil,
                save: Save? = nil, share: Share? = nil, library: Library? = nil) {
        self.library = library
        self.share = share
        self.onLibrary = onLibrary
        self.status = status
        self.statusHelp = statusHelp
        self.save = save
    }
}

#endif
