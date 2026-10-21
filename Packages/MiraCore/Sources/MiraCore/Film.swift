import Foundation

/// Broad stock category used to group films in the UI.
public enum FilmFamily: String, Codable, CaseIterable, Sendable {
    case colorNegative, slide, blackAndWhite, instant

    public var displayName: String {
        switch self {
        case .colorNegative: "Colour Negative"
        case .slide: "Slide"
        case .blackAndWhite: "Black & White"
        case .instant: "Instant"
        }
    }
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

    private enum CodingKeys: String, CodingKey {
        case id, displayName, brand, family, iso, description, file, source
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
    }

    public init(
        id: String, displayName: String, brand: String, family: FilmFamily,
        iso: Int, description: String, file: String, source: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.brand = brand
        self.family = family
        self.iso = iso
        self.description = description
        self.file = file
        self.source = source
    }
}
