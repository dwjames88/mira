import Foundation

// Pure, PhotoKit-free value types for the Photos-library management UI (iOS and Mac).

// MARK: Albums

/// What a user album allows (from `PHCollection.canPerform`). Shared and some synced albums are restricted.
public struct AlbumCapabilities: Hashable, Sendable {
    public var canAdd: Bool
    public var canRemove: Bool
    public var canRename: Bool
    public var canDelete: Bool

    public init(canAdd: Bool = true, canRemove: Bool = true, canRename: Bool = true, canDelete: Bool = true) {
        self.canAdd = canAdd
        self.canRemove = canRemove
        self.canRename = canRename
        self.canDelete = canDelete
    }

    public static let full = AlbumCapabilities()
    public static let none = AlbumCapabilities(canAdd: false, canRemove: false, canRename: false, canDelete: false)
}

/// One user album, flattened out of the folder tree.
public struct AlbumEntry: Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    /// Titles of the folders that contain the album, outermost first.
    public var path: [String]
    /// Pictures in the album.
    public var count: Int
    public var capabilities: AlbumCapabilities

    public init(id: String, title: String, path: [String] = [], count: Int = 0, capabilities: AlbumCapabilities = .full) {
        self.id = id
        self.title = title
        self.path = path
        self.count = count
        self.capabilities = capabilities
    }

    /// "Folder › Sub › Album"; just the title for a top-level album.
    public var displayPath: String { (path + [title]).joined(separator: " › ") }
}

/// What changed between two snapshots of the album list (by id), for live updates.
public struct AlbumListDiff: Equatable, Sendable {
    public var inserted: [AlbumEntry] = []
    public var removed: [AlbumEntry] = []
    /// Same id, different title or folder path (new values).
    public var renamed: [AlbumEntry] = []
    /// Same id, different count (new values).
    public var countChanged: [AlbumEntry] = []
    public var isEmpty: Bool { inserted.isEmpty && removed.isEmpty && renamed.isEmpty && countChanged.isEmpty }
}

public enum AlbumList {
    /// Albums that can take content, minus the one being viewed, in the given order.
    public static func targets(for albums: [AlbumEntry], excluding currentAlbumID: String? = nil) -> [AlbumEntry] {
        albums.filter { $0.capabilities.canAdd && $0.id != currentAlbumID }
    }

    /// Case- and diacritic-insensitive title search (the folder path counts too). Empty query keeps everything.
    public static func filter(_ albums: [AlbumEntry], query: String) -> [AlbumEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return albums }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return albums.filter { $0.displayPath.range(of: q, options: options) != nil }
    }

    public static func diff(old: [AlbumEntry], new: [AlbumEntry]) -> AlbumListDiff {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.map(\.id))
        var result = AlbumListDiff()
        for entry in new {
            guard let before = oldByID[entry.id] else { result.inserted.append(entry); continue }
            if before.title != entry.title || before.path != entry.path { result.renamed.append(entry) }
            if before.count != entry.count { result.countChanged.append(entry) }
        }
        result.removed = old.filter { !newIDs.contains($0.id) }
        return result
    }

    /// `base`, or `base 2`, `base 3`, ... the first not taken (case-insensitive).
    public static func uniqueTitle(_ base: String = "Untitled Album", existing: [String]) -> String {
        let taken = Set(existing.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }
}

// MARK: Selection

/// An ordered set of asset ids with a range anchor. Value type; the UI owns one per grid.
public struct LibrarySelection: Equatable, Sendable {
    public private(set) var ids: [String] = []
    private var set: Set<String> = []
    /// The last id picked on its own; `selectRange` extends from here.
    public private(set) var anchor: String?
    /// iOS "Select" mode; the Mac ignores it. Cleared by `finishSelecting()`.
    public var isSelecting = false

    public init() {}

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }
    public func contains(_ id: String) -> Bool { set.contains(id) }

    /// Adds the id, or removes it when already selected. Becomes the anchor when added.
    public mutating func toggle(_ id: String) {
        if set.remove(id) != nil {
            ids.removeAll { $0 == id }
            if anchor == id { anchor = ids.last }
        } else {
            set.insert(id)
            ids.append(id)
            anchor = id
        }
    }

    /// Makes `id` the only selected asset (a plain click).
    public mutating func select(_ id: String) {
        ids = [id]
        set = [id]
        anchor = id
    }

    /// Shift-click: adds everything between the anchor and `id` (either direction, inclusive), in
    /// display order starting next to the anchor. Without a usable anchor it behaves like `select`.
    public mutating func selectRange(to id: String, in orderedIDs: [String]) {
        guard let anchor, let from = orderedIDs.firstIndex(of: anchor), let to = orderedIDs.firstIndex(of: id) else {
            select(id)
            return
        }
        let range = from <= to ? Array(orderedIDs[from...to]) : Array(orderedIDs[to...from].reversed())
        for item in range where set.insert(item).inserted { ids.append(item) }
    }

    public mutating func selectAll(_ orderedIDs: [String]) {
        ids = []
        set = []
        for id in orderedIDs where set.insert(id).inserted { ids.append(id) }
        anchor = ids.first
    }

    public mutating func clear() {
        ids = []
        set = []
        anchor = nil
    }

    /// Leaves selection mode and clears the selection.
    public mutating func finishSelecting() {
        clear()
        isSelecting = false
    }

    /// Drops ids that no longer exist (removed from the library or album by a live change).
    public mutating func prune(keeping existing: Set<String>) {
        guard ids.contains(where: { !existing.contains($0) }) else { return }
        ids = ids.filter { existing.contains($0) }
        set = Set(ids)
        if let a = anchor, !set.contains(a) { anchor = nil }
    }
}

// MARK: Actions

public enum LibraryAction: String, CaseIterable, Sendable {
    case favorite, unfavorite, addToAlbum, moveToAlbum, removeFromAlbum
    case hide, unhide, duplicate, info, share, delete

    public var title: String {
        switch self {
        case .favorite: "FAVORITE"
        case .unfavorite: "UNFAVORITE"
        case .addToAlbum: "ADD TO ALBUM"
        case .moveToAlbum: "MOVE TO ALBUM"
        case .removeFromAlbum: "REMOVE FROM ALBUM"
        case .hide: "HIDE"
        case .unhide: "UNHIDE"
        case .duplicate: "DUPLICATE"
        case .info: "INFO"
        case .share: "SHARE"
        case .delete: "DELETE"
        }
    }

    /// SF Symbol name.
    public var systemImage: String {
        switch self {
        case .favorite: "heart"
        case .unfavorite: "heart.slash"
        case .addToAlbum: "rectangle.stack.badge.plus"
        case .moveToAlbum: "folder"
        case .removeFromAlbum: "rectangle.stack.badge.minus"
        case .hide: "eye.slash"
        case .unhide: "eye"
        case .duplicate: "plus.square.on.square"
        case .info: "info.circle"
        case .share: "square.and.arrow.up"
        case .delete: "trash"
        }
    }

    public var isDestructive: Bool { self == .delete || self == .removeFromAlbum }
}

/// Where the user is and what is selected.
public struct LibraryActionContext: Sendable, Equatable {
    public var nodeKind: SidebarNodeKind?
    public var nodeID: String
    /// Recently Deleted and other read-only collections.
    public var isReadOnly: Bool
    public var isHiddenAlbum: Bool
    /// Capabilities of the viewed user album (nil when not in a user album).
    public var albumCapabilities: AlbumCapabilities?
    /// The app only sees part of the library; it cannot see user albums.
    public var limitedAccess: Bool
    public var selectionCount: Int
    public var allFavorite: Bool
    public var allHidden: Bool

    public init(
        nodeKind: SidebarNodeKind? = nil, nodeID: String = "all", isReadOnly: Bool = false, isHiddenAlbum: Bool = false,
        albumCapabilities: AlbumCapabilities? = nil, limitedAccess: Bool = false,
        selectionCount: Int = 0, allFavorite: Bool = false, allHidden: Bool = false
    ) {
        self.nodeKind = nodeKind
        self.nodeID = nodeID
        self.isReadOnly = isReadOnly
        self.isHiddenAlbum = isHiddenAlbum
        self.albumCapabilities = albumCapabilities
        self.limitedAccess = limitedAccess
        self.selectionCount = selectionCount
        self.allFavorite = allFavorite
        self.allHidden = allHidden
    }
}

public struct LibraryActionItem: Identifiable, Equatable, Sendable {
    public var action: LibraryAction
    public var isEnabled: Bool
    public var id: String { action.rawValue }
    public var title: String { action.title }
    public var systemImage: String { action.systemImage }
    public var isDestructive: Bool { action.isDestructive }
}

public enum LibraryActionAvailability {
    /// The actions to show, in menu order. Each is enabled only with a selection (INFO: exactly one).
    public static func items(for context: LibraryActionContext) -> [LibraryActionItem] {
        let n = context.selectionCount
        func item(_ action: LibraryAction) -> LibraryActionItem {
            LibraryActionItem(action: action, isEnabled: action == .info ? n == 1 : n > 0)
        }
        // Recently Deleted: nothing destructive or mutating, only a look at one photo.
        if context.isReadOnly { return [item(.info)] }

        var actions: [LibraryAction] = [context.allFavorite ? .unfavorite : .favorite]
        if !context.limitedAccess {
            actions.append(.addToAlbum)
            if context.nodeKind == .album, context.albumCapabilities?.canRemove == true {
                actions.append(.moveToAlbum)
                actions.append(.removeFromAlbum)
            }
        }
        actions.append(context.isHiddenAlbum || context.allHidden ? .unhide : .hide)
        actions += [.duplicate, .info, .share, .delete]
        return actions.map(item)
    }

    /// Whether album management (new album, rename, delete album) is available at all.
    public static func canManageAlbums(limitedAccess: Bool) -> Bool { !limitedAccess }
}

// MARK: Info

public struct AssetInfo: Equatable, Sendable {
    public var filename: String
    public var creationDate: Date?
    public var cameraName: String?
    public var lens: String?
    public var focalLength: Double?
    public var fNumber: Double?
    public var exposureTime: Double?
    public var iso: Int?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var fileSize: Int64?
    /// "RAW", "JPEG", "HEIC", ... RAW first.
    public var formats: [String]
    public var isRAW: Bool
    public var isFavorite: Bool
    public var isHidden: Bool
    /// The asset has any edit (adjustment data).
    public var hasAdjustments: Bool
    /// The edit was made by Mira.
    public var hasMiraEdit: Bool
    public var latitude: Double?
    public var longitude: Double?
    /// Not filled by `AssetInfoReader` (MiraCore does not geocode); the apps may set it after geocoding.
    public var locationName: String?

    public init(
        filename: String = "", creationDate: Date? = nil, cameraName: String? = nil, lens: String? = nil,
        focalLength: Double? = nil, fNumber: Double? = nil, exposureTime: Double? = nil, iso: Int? = nil,
        pixelWidth: Int = 0, pixelHeight: Int = 0, fileSize: Int64? = nil, formats: [String] = [],
        isRAW: Bool = false, isFavorite: Bool = false, isHidden: Bool = false,
        hasAdjustments: Bool = false, hasMiraEdit: Bool = false,
        latitude: Double? = nil, longitude: Double? = nil, locationName: String? = nil
    ) {
        self.filename = filename
        self.creationDate = creationDate
        self.cameraName = cameraName
        self.lens = lens
        self.focalLength = focalLength
        self.fNumber = fNumber
        self.exposureTime = exposureTime
        self.iso = iso
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.fileSize = fileSize
        self.formats = formats
        self.isRAW = isRAW
        self.isFavorite = isFavorite
        self.isHidden = isHidden
        self.hasAdjustments = hasAdjustments
        self.hasMiraEdit = hasMiraEdit
        self.latitude = latitude
        self.longitude = longitude
        self.locationName = locationName
    }
}

public struct AssetInfoRow: Equatable, Sendable {
    public var label: String
    public var value: String
}

public enum AssetInfoFormatter {
    /// Ordered rows: DATE, CAMERA, LENS, EXPOSURE, DIMENSIONS, FILE SIZE, FORMAT, LOCATION, FILENAME.
    /// Rows with nothing to show are left out, except DATE ("UNKNOWN"). The defaults make the output
    /// deterministic (POSIX locale); pass the photo's or the user's time zone for display.
    public static func rows(
        _ info: AssetInfo, locale: Locale = Locale(identifier: "en_US_POSIX"), timeZone: TimeZone = .current
    ) -> [AssetInfoRow] {
        var rows: [AssetInfoRow] = []
        rows.append(AssetInfoRow(label: "DATE", value: info.creationDate.map { date($0, locale: locale, timeZone: timeZone) } ?? "UNKNOWN"))
        if let camera = nonEmpty(info.cameraName) { rows.append(AssetInfoRow(label: "CAMERA", value: camera)) }
        if let lens = nonEmpty(info.lens) { rows.append(AssetInfoRow(label: "LENS", value: lens)) }
        if let exposure = exposureLine(info) { rows.append(AssetInfoRow(label: "EXPOSURE", value: exposure)) }
        if info.pixelWidth > 0, info.pixelHeight > 0 {
            let mp = Double(info.pixelWidth) * Double(info.pixelHeight) / 1_000_000
            rows.append(AssetInfoRow(label: "DIMENSIONS", value: "\(info.pixelWidth) × \(info.pixelHeight) · \(String(format: "%.1f", mp)) MP"))
        }
        if let size = info.fileSize, size > 0 { rows.append(AssetInfoRow(label: "FILE SIZE", value: fileSize(size))) }
        if !info.formats.isEmpty { rows.append(AssetInfoRow(label: "FORMAT", value: info.formats.joined(separator: " + "))) }
        if let location = locationLine(info) { rows.append(AssetInfoRow(label: "LOCATION", value: location)) }
        if let name = nonEmpty(info.filename) { rows.append(AssetInfoRow(label: "FILENAME", value: name)) }
        return rows
    }

    /// "5 Nov 2026, 14:32".
    public static func date(_ date: Date, locale: Locale = Locale(identifier: "en_US_POSIX"), timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.dateFormat = "d MMM yyyy, HH:mm"
        return f.string(from: date)
    }

    /// "1/250 s" below a second (denominator rounded), "2 s" / "1.5 s" from a second up.
    public static func shutter(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "" }
        if seconds < 1 {
            let denominator = Int((1 / seconds).rounded())
            if denominator >= 2 { return "1/\(denominator) s" }
        }
        return "\(trimmed(seconds, places: 1)) s"
    }

    /// Decimal (1000-based) units like Finder: "999 B", "12.3 MB". Locale-independent.
    public static func fileSize(_ bytes: Int64) -> String {
        if bytes < 1000 { return "\(bytes) B" }
        let units = ["KB", "MB", "GB", "TB"]
        var value = Double(bytes) / 1000
        var unit = 0
        while value >= 1000, unit < units.count - 1 { value /= 1000; unit += 1 }
        return String(format: "%.1f %@", value, units[unit])
    }

    /// "48.8584° N, 2.2945° E".
    public static func coordinates(latitude: Double, longitude: Double) -> String {
        let ns = latitude >= 0 ? "N" : "S"
        let ew = longitude >= 0 ? "E" : "W"
        return String(format: "%.4f° %@, %.4f° %@", abs(latitude), ns, abs(longitude), ew)
    }

    private static func exposureLine(_ info: AssetInfo) -> String? {
        var parts: [String] = []
        if let t = info.exposureTime, t > 0 { parts.append(shutter(t)) }
        if let f = info.fNumber, f > 0 { parts.append("f/\(trimmed(f, places: 1))") }
        if let iso = info.iso, iso > 0 { parts.append("ISO \(iso)") }
        if let fl = info.focalLength, fl > 0 { parts.append("\(trimmed(fl, places: 1)) mm") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func locationLine(_ info: AssetInfo) -> String? {
        if let name = nonEmpty(info.locationName) { return name }
        guard let lat = info.latitude, let lon = info.longitude else { return nil }
        return coordinates(latitude: lat, longitude: lon)
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// 2.0 -> "2", 2.8 -> "2.8", 35.0 -> "35".
    private static func trimmed(_ value: Double, places: Int) -> String {
        let scale = pow(10, Double(places))
        let rounded = (value * scale).rounded() / scale
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.\(places)f", rounded)
    }
}
