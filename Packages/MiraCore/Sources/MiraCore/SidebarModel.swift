import Foundation

/// What a sidebar row stands for.
public enum SidebarNodeKind: Hashable, Sendable {
    case folder
    case album
    /// A Photos smart album, by its `PHAssetCollectionSubtype` raw value.
    case smart(Int)
    case library
    case favourites
    case recents
}

/// One row of the library sidebar. Folders carry children; everything else is a leaf.
public struct SidebarNode: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let kind: SidebarNodeKind
    public let count: Int?
    public let children: [SidebarNode]

    public init(id: String, title: String, kind: SidebarNodeKind, count: Int? = nil, children: [SidebarNode] = []) {
        self.id = id
        self.title = title
        self.kind = kind
        self.count = count
        self.children = children
    }

    public var isFolder: Bool { kind == .folder }
}

/// A titled group of rows (LIBRARY, ALBUMS, ...).
public struct SidebarSection: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let nodes: [SidebarNode]

    public init(id: String, title: String, nodes: [SidebarNode]) {
        self.id = id
        self.title = title
        self.nodes = nodes
    }
}

/// A user collection as the builder sees it: a folder (with children) or an album (with a count).
/// The app adapts `PHCollection` to this; tests feed a fake tree.
public protocol CollectionNodeSource: Sendable {
    var title: String { get }
    var identifier: String { get }
    var isFolder: Bool { get }
    /// Folder contents; empty for albums.
    var children: [any CollectionNodeSource] { get }
    /// Number of pictures in an album; ignored for folders.
    var assetCount: Int { get }
}

/// Pure sidebar construction and lookup, kept free of PhotoKit so it can be unit tested.
public enum SidebarModel {
    /// Folders and albums together, Finder-style: case-insensitive, numbers by value ("Album 2" < "Album 10").
    public static func sortedByTitle(_ nodes: [SidebarNode]) -> [SidebarNode] {
        nodes.sorted { a, b in
            switch a.title.localizedStandardCompare(b.title) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.id < b.id
            }
        }
    }

    /// The user's albums as a sorted tree. Folders without any album inside (at any depth) are dropped.
    public static func albumNodes(from sources: [any CollectionNodeSource]) -> [SidebarNode] {
        var nodes: [SidebarNode] = []
        for source in sources {
            if source.isFolder {
                let children = albumNodes(from: source.children)
                guard !children.isEmpty else { continue }
                nodes.append(SidebarNode(id: source.identifier, title: source.title, kind: .folder, children: children))
            } else {
                nodes.append(SidebarNode(id: source.identifier, title: source.title, kind: .album, count: source.assetCount))
            }
        }
        return sortedByTitle(nodes)
    }

    /// Entries whose count is known to be zero are not shown (Media Types, Utilities).
    public static func visible(_ nodes: [SidebarNode]) -> [SidebarNode] {
        nodes.filter { ($0.count ?? 1) > 0 }
    }

    /// Sort key for a rating album: 1-5 for star counts, 0 for Flagged/Picks, -1 for Rejected; nil when
    /// the title is not a rating album.
    public static func ratingRank(forTitle title: String) -> Int? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let stripped = trimmed.replacingOccurrences(of: "\u{FE0F}", with: "")
        if (1...5).contains(stripped.count), stripped.allSatisfy({ "\u{2605}\u{2606}\u{2B50}".contains($0) }) {
            return stripped.count
        }
        switch trimmed.lowercased() {
        case "flagged", "picks", "pick": return 0
        case "rejected", "rejects": return -1
        default: return nil
        }
    }

    /// Pulls rating albums (stars, Flagged, Rejected) out of the albums tree at any depth. Returns them
    /// ordered five stars first, then Flagged, then Rejected, and the tree without them (folders left
    /// empty by the removal are pruned).
    public static func extractRatings(from nodes: [SidebarNode]) -> (ratings: [SidebarNode], remaining: [SidebarNode]) {
        var found: [(rank: Int, node: SidebarNode)] = []
        func strip(_ nodes: [SidebarNode]) -> [SidebarNode] {
            var kept: [SidebarNode] = []
            for node in nodes {
                if node.isFolder {
                    let children = strip(node.children)
                    if !children.isEmpty {
                        kept.append(SidebarNode(id: node.id, title: node.title, kind: .folder, count: node.count, children: children))
                    }
                } else if let rank = ratingRank(forTitle: node.title) {
                    found.append((rank, node))
                } else {
                    kept.append(node)
                }
            }
            return kept
        }
        let remaining = strip(nodes)
        let ordered = found.sorted { a, b in
            a.rank != b.rank ? a.rank > b.rank : a.node.title.localizedStandardCompare(b.node.title) == .orderedAscending
        }.map(\.node)
        return (ordered, remaining)
    }

    /// The sidebar sections in Photos' order, with STARS after LIBRARY. Empty sections are left out; Media Types and
    /// Utilities lose their zero-count entries first.
    public static func sections(
        library: [SidebarNode], stars: [SidebarNode] = [], albums: [SidebarNode], shared: [SidebarNode],
        mediaTypes: [SidebarNode], utilities: [SidebarNode]
    ) -> [SidebarSection] {
        let all = [
            SidebarSection(id: "library", title: "Library", nodes: library),
            SidebarSection(id: "stars", title: "Stars", nodes: visible(stars)),
            SidebarSection(id: "albums", title: "Albums", nodes: albums),
            SidebarSection(id: "shared", title: "Shared Albums", nodes: sortedByTitle(shared)),
            SidebarSection(id: "media", title: "Media Types", nodes: visible(mediaTypes)),
            SidebarSection(id: "utilities", title: "Utilities", nodes: visible(utilities)),
        ]
        return all.filter { !$0.nodes.isEmpty }
    }

    // MARK: Lookup

    /// The titles from the root to the node with `id` ("Folder", "Sub", "Album"), or nil when absent.
    public static func breadcrumb(to id: String, in sections: [SidebarSection]) -> [String]? {
        path(to: id, in: sections)?.map(\.title)
    }

    /// Ids of the folders that contain the node, outermost first (empty for a top-level node, nil when absent).
    public static func ancestorIDs(of id: String, in sections: [SidebarSection]) -> [String]? {
        path(to: id, in: sections).map { $0.dropLast().map(\.id) }
    }

    public static func node(withID id: String, in sections: [SidebarSection]) -> SidebarNode? {
        path(to: id, in: sections)?.last
    }

    /// Rows in display order, honouring which folders are expanded.
    public static func visibleRows(in section: SidebarSection, expanded: Set<String>) -> [(node: SidebarNode, depth: Int)] {
        var rows: [(SidebarNode, Int)] = []
        func walk(_ nodes: [SidebarNode], _ depth: Int) {
            for node in nodes {
                rows.append((node, depth))
                if node.isFolder, expanded.contains(node.id) { walk(node.children, depth + 1) }
            }
        }
        walk(section.nodes, 0)
        return rows
    }

    private static func path(to id: String, in sections: [SidebarSection]) -> [SidebarNode]? {
        func search(_ nodes: [SidebarNode], _ trail: [SidebarNode]) -> [SidebarNode]? {
            for node in nodes {
                let here = trail + [node]
                if node.id == id { return here }
                if let found = search(node.children, here) { return found }
            }
            return nil
        }
        for section in sections {
            if let found = search(section.nodes, []) { return found }
        }
        return nil
    }
}
