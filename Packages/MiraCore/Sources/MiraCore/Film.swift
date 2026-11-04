import Foundation

/// Film chemistry, used to group films in the UI and to pick each stock's default behavior
/// (`FilmCharacter.defaults`). Raw values are stored in `films.json`; add cases only at the end.
public enum FilmFamily: String, Codable, CaseIterable, Sendable {
    /// C-41 colour negative.
    case colorNegative
    /// E-6 colour reversal (slide).
    case slide
    case blackAndWhite
    case instant
    /// K-14 Kodachrome reversal.
    case kodachrome
    /// ECN-2 motion-picture negative (rem-jet backing).
    case motionPicture
    /// Print films and papers (the positive a negative is printed onto).
    case print

    public var displayName: String {
        switch self {
        case .colorNegative: "Color Negative"
        case .slide: "Slide"
        case .blackAndWhite: "Black & White"
        case .instant: "Instant"
        case .kodachrome: "Kodachrome"
        case .motionPicture: "Motion Picture"
        case .print: "Print"
        }
    }

    /// Order of the family tabs and groups in the UI.
    public static let displayOrder: [FilmFamily] = [
        .colorNegative, .slide, .kodachrome, .motionPicture, .blackAndWhite, .instant, .print,
    ]
}

/// One entry of `films.json`.
public struct Film: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var displayName: String
    public var brand: String
    public var family: FilmFamily
    public var iso: Int
    public var description: String
    /// Path relative to the films directory, e.g. `HaldCLUT/kodak-portra-400.png`.
    public var file: String
    public var source: String?
    /// The id of the stock this entry is a variant of (a push/pull or alternate rendering of the same
    /// film); nil for a stock. Variants are not shown as cards of their own; the FILMS panel offers them.
    public var parent: String?
    /// Short label of a variant, e.g. "+1", "\u{2212}1", "Cold", "Cold +1", "Alt"; nil for a stock.
    public var variant: String?
    /// Overrides the family's monochrome default (black-and-white instant films set this to true).
    public var monochrome: Bool?
    /// Per-film overrides of the character derived from family and ISO (see `FilmCharacter.defaults`).
    public var character: FilmCharacter.Override?

    /// True for black-and-white emulsions: monochrome grain, untinted halation.
    /// Prefix of `file` for looks Mira generates in code instead of loading a LUT file, e.g.
    /// `procedural:vision3-500t` (see `ProceduralLooks`). Such films have no file on disk.
    public static let proceduralPrefix = "procedural:"

    /// The procedural look id when this film is generated in code, else nil.
    public var proceduralID: String? {
        file.hasPrefix(Self.proceduralPrefix) ? String(file.dropFirst(Self.proceduralPrefix.count)) : nil
    }

    public var isMonochrome: Bool { monochrome ?? (family == .blackAndWhite) }

    /// True when this entry is a variant of another stock.
    public var isVariant: Bool { parent != nil }

    /// The id of the stock card this film belongs to: its parent, or itself.
    public var stockID: String { parent ?? id }

    /// Grain, halation and latitude for this film: family and ISO defaults with the film's overrides.
    public var resolvedCharacter: FilmCharacter {
        FilmCharacter.defaults(family: family, iso: iso, monochrome: isMonochrome).applying(character)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, brand, family, iso, description, file, source, parent, variant, monochrome, character
    }

    /// `iso` may be a number or a numeric string in `films.json`.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        brand = try c.decode(String.self, forKey: .brand)
        family = try c.decode(FilmFamily.self, forKey: .family)
        if let n = try? c.decode(Int.self, forKey: .iso) {
            iso = n
        } else if let s = try? c.decode(String.self, forKey: .iso), let n = Int(s.trimmingCharacters(in: .whitespaces)) {
            iso = n
        } else {
            iso = 0
        }
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        file = try c.decode(String.self, forKey: .file)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
        monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome)
        character = try c.decodeIfPresent(FilmCharacter.Override.self, forKey: .character)
    }

    public init(
        id: String, displayName: String, brand: String, family: FilmFamily,
        iso: Int, description: String, file: String, source: String? = nil,
        parent: String? = nil, variant: String? = nil, monochrome: Bool? = nil,
        character: FilmCharacter.Override? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.brand = brand
        self.family = family
        self.iso = iso
        self.description = description
        self.file = file
        self.source = source
        self.parent = parent
        self.variant = variant
        self.monochrome = monochrome
        self.character = character
    }
}
