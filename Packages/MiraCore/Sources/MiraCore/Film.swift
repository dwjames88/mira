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
    /// Path relative to the films directory, e.g. `Packed/kodak-portra-400.mlut` (a `PackedLUT`; `.png` Hald and
    /// `.cube` files also load, for user or test libraries).
    public var file: String
    /// The Hald PNG this film was packed from, relative to the `FilmSources` folder of the source repository
    /// (e.g. `HaldCLUT/kodak-portra-400.png`). Not bundled; used by `mira-sheet --pack-films`.
    public var png: String?
    /// Path of the original file inside the RawTherapee archive (see `Films/ATTRIBUTION.md`).
    public var source: String?
    /// The id of the film this entry is a variant of (a push/pull or alternate rendering of the same
    /// film); nil otherwise. Kept for compatibility: the UI groups by `stock`, `iso` and `variation`.
    public var parent: String?
    /// Short label of a `parent` variant, e.g. "+1", "\u{2212}1", "Cold", "Cold +1", "Alt".
    public var variant: String?
    /// The id of the stock (product line) this film belongs to, e.g. `kodak-portra`; the film strip shows one
    /// card per stock. Absent in user libraries, where it falls back to `parent` or the film's own id.
    public var stock: String?
    /// True for the one flagship film of each stock; its card thumbnail and what a click on the card applies.
    public var stockBase: Bool?
    /// The stock's card title (e.g. "Portra"); carried by the stock's base film.
    public var stockName: String?
    /// The ISO chip label where the bare number would be ambiguous (e.g. "100F", "400H", "80s").
    public var isoLabel: String?
    /// The Variations chip label of this film (e.g. "+1", "Cold \u{2212}1", "NC +1", "Negative"); nil for the
    /// plain film at its ISO.
    public var variation: String?
    /// Overrides the family's monochrome default (black-and-white instant films set this to true).
    public var monochrome: Bool?
    /// Per-film overrides of the character derived from family and ISO (see `FilmCharacter.defaults`).
    public var character: FilmCharacter.Override?
    /// Datasheet reciprocity data (long and short exposure failure); nil falls back to the family default
    /// (`Reciprocity.familyDefault`). `FilmLibrary` fills a variant's from its parent.
    public var reciprocity: ReciprocityData?

    /// True for black-and-white emulsions: monochrome grain, untinted halation.
    /// Prefix of `file` for looks Mira generates in code instead of loading a LUT file, e.g.
    /// `procedural:vision3-500t` (see `ProceduralLooks`). Such films have no file on disk.
    public static let proceduralPrefix = "procedural:"

    /// The procedural look id when this film is generated in code, else nil.
    public var proceduralID: String? {
        file.hasPrefix(Self.proceduralPrefix) ? String(file.dropFirst(Self.proceduralPrefix.count)) : nil
    }

    public var isMonochrome: Bool { monochrome ?? (family == .blackAndWhite) }

    /// True when this entry is not the base film of its stock (so it has no card of its own).
    public var isVariant: Bool { !isStockBase }

    /// The id of the stock card this film belongs to.
    public var stockID: String { stock ?? parent ?? id }

    /// Whether this is its stock's base film.
    public var isStockBase: Bool { stockBase ?? (stock == nil && parent == nil) }

    /// The Variations chip label; nil for the plain film at its ISO.
    public var variationLabel: String? { stock == nil ? variant : variation }

    /// The ISO chip label: `isoLabel`, else the number.
    public var isoChipLabel: String { isoLabel ?? String(iso) }

    /// Grain, halation and latitude for this film: family and ISO defaults with the film's overrides.
    public var resolvedCharacter: FilmCharacter {
        FilmCharacter.defaults(family: family, iso: iso, monochrome: isMonochrome).applying(character)
    }

    private enum CodingKeys: String, CodingKey {
        case id, displayName, brand, family, iso, description, file, png, source, parent, variant, stock, stockBase, stockName, isoLabel, variation, monochrome, character, reciprocity
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
        png = try c.decodeIfPresent(String.self, forKey: .png)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        parent = try c.decodeIfPresent(String.self, forKey: .parent)
        variant = try c.decodeIfPresent(String.self, forKey: .variant)
        stock = try c.decodeIfPresent(String.self, forKey: .stock)
        stockBase = try c.decodeIfPresent(Bool.self, forKey: .stockBase)
        stockName = try c.decodeIfPresent(String.self, forKey: .stockName)
        isoLabel = try c.decodeIfPresent(String.self, forKey: .isoLabel)
        variation = try c.decodeIfPresent(String.self, forKey: .variation)
        monochrome = try c.decodeIfPresent(Bool.self, forKey: .monochrome)
        character = try c.decodeIfPresent(FilmCharacter.Override.self, forKey: .character)
        reciprocity = try c.decodeIfPresent(ReciprocityData.self, forKey: .reciprocity)
    }

    public init(
        id: String, displayName: String, brand: String, family: FilmFamily,
        iso: Int, description: String, file: String, png: String? = nil, source: String? = nil,
        parent: String? = nil, variant: String? = nil,
        stock: String? = nil, stockBase: Bool? = nil, stockName: String? = nil, isoLabel: String? = nil,
        variation: String? = nil, monochrome: Bool? = nil,
        character: FilmCharacter.Override? = nil, reciprocity: ReciprocityData? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.brand = brand
        self.family = family
        self.iso = iso
        self.description = description
        self.file = file
        self.png = png
        self.source = source
        self.parent = parent
        self.variant = variant
        self.stock = stock
        self.stockBase = stockBase
        self.stockName = stockName
        self.isoLabel = isoLabel
        self.variation = variation
        self.monochrome = monochrome
        self.character = character
        self.reciprocity = reciprocity
    }
}
