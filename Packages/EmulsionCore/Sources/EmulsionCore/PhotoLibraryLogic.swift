import Foundation
import UniformTypeIdentifiers

/// Pure helpers for the Photos library browser, kept here so they can be unit tested.
public enum RAWDetection {
    /// True when the type identifier (a resource's `uniformTypeIdentifier`) is a camera RAW format.
    public static func isRAW(typeIdentifier: String) -> Bool {
        guard let type = UTType(typeIdentifier) else { return false }
        return type.conforms(to: .rawImage)
    }

    /// True when any of the identifiers is a camera RAW format.
    public static func containsRAW(_ typeIdentifiers: [String]) -> Bool {
        typeIdentifiers.contains(where: isRAW(typeIdentifier:))
    }
}

/// Text for the editor's sidecar status line.
public enum SidecarStatus {
    public static func line(location: SidecarLocation?, imageURL: URL) -> String {
        switch location {
        case .adjacent(let url): "SIDECAR \u{00B7} \(url.lastPathComponent)"
        case .fallback: "SIDECAR \u{00B7} APP SUPPORT (folder not writable)"
        case nil: "SIDECAR \u{00B7} \(SidecarStore.sidecarURL(for: imageURL).lastPathComponent) (written on first edit)"
        }
    }
}

/// Whether leaving an editing session would discard unsaved work.
public enum EditDirtyCheck {
    public static func isDirty(current: Recipe, loaded: Recipe) -> Bool { current != loaded }
}
