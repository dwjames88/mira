import Foundation

// Pure helpers for pointer-driven library UIs (the Mac grid): what a click does to the selection,
// which assets a context menu or drag acts on, and the drag payload. No PhotoKit, no AppKit.

/// The modifier keys held at click time.
public struct LibraryClickModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = LibraryClickModifiers(rawValue: 1)
    public static let shift = LibraryClickModifiers(rawValue: 2)
}

public enum LibraryInteraction {
    /// What a click on `id` does: plain selects only it, command toggles it, shift extends from the
    /// anchor. `range` is asked for only when needed and must return the ids from the anchor's grid
    /// position to the clicked one (or the whole grid) in display order; with no usable anchor shift
    /// behaves like a plain click. Returns true when `id` is selected afterwards (so the caller can
    /// make it the focused cell).
    @discardableResult
    public static func click(
        _ selection: inout LibrarySelection, id: String, modifiers: LibraryClickModifiers,
        range: () -> [String] = { [] }
    ) -> Bool {
        if modifiers.contains(.shift) {
            let ordered = range()
            if selection.anchor != nil, ordered.contains(id) {
                selection.selectRange(to: id, in: ordered)
            } else {
                selection.select(id)
            }
            return true
        }
        if modifiers.contains(.command) {
            selection.toggle(id)
            return selection.contains(id)
        }
        selection.select(id)
        return true
    }

    /// The assets a context-menu command acts on: the whole selection when the clicked cell is in it,
    /// otherwise just the clicked cell.
    public static func actionIDs(clicked id: String, selection: LibrarySelection) -> [String] {
        selection.contains(id) ? selection.ids : [id]
    }

    /// The assets a drag carries; same rule as `actionIDs`.
    public static func dragIDs(dragged id: String, selection: LibrarySelection) -> [String] {
        actionIDs(clicked: id, selection: selection)
    }
}

/// The text a dragged cell carries. Plain text with a prefix, so it needs no registered type and a
/// stray drop into another app shows readable ids rather than nothing.
public enum LibraryDragPayload {
    public static let prefix = "mira-assets:"

    public static func encode(_ ids: [String]) -> String {
        prefix + ids.joined(separator: "\n")
    }

    /// nil when the text is not a library payload or carries no ids. Order is kept, duplicates dropped.
    public static func decode(_ text: String) -> [String]? {
        guard text.hasPrefix(prefix) else { return nil }
        var seen = Set<String>()
        let ids = text.dropFirst(prefix.count)
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        return ids.isEmpty ? nil : ids
    }
}
