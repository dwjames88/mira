import Foundation

/// A named, saved look: a film plus every develop setting, stored as one `Recipe`.
///
/// The crop belongs to a photo, not to a look, so a preset always stores `CropSettings.identity`
/// and applying one never touches the photo's crop. Decoding is tolerant: any missing key falls
/// back to a default, so files written by other versions stay readable.
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public static let currentVersion = 1
    /// Shown as the film name for a preset saved with no film.
    public static let originalName = "Original"

    public var id: UUID
    public var filmID: String?
    /// The film's display name when the preset was made, so a film that is no longer installed
    /// can still be named.
    public var filmName: String
    public var nickname: String
    public private(set) var recipe: Recipe
    public var created: Date
    public var modified: Date
    public var version: Int

    public init(
        id: UUID = UUID(), nickname: String, recipe: Recipe, filmName: String? = nil,
        created: Date = Date(), modified: Date? = nil, version: Int = Preset.currentVersion
    ) {
        self.id = id
        self.filmID = recipe.filmID
        self.filmName = Preset.resolvedFilmName(filmName, filmID: recipe.filmID)
        self.nickname = nickname
        self.recipe = Preset.normalized(recipe)
        self.created = Preset.millisecond(created)
        self.modified = Preset.millisecond(modified ?? created)
        self.version = version
    }

    /// Dates are kept to the millisecond, the precision the file stores.
    static func millisecond(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// Makes a preset from a recipe, naming the film from `library` ("Original" with no film).
    public init(nickname: String, recipe: Recipe, library: FilmLibrary, created: Date = Date()) {
        let name = recipe.filmID.flatMap { library.film(id: $0)?.displayName }
        self.init(nickname: nickname, recipe: recipe, filmName: name, created: created)
    }

    /// "Portra 400 - Last Summer".
    public var displayName: String { Preset.displayName(filmName: filmName, nickname: nickname) }

    public static func displayName(filmName: String, nickname: String) -> String { "\(filmName) - \(nickname)" }

    /// The recipe to apply to a photo: the preset's film and develop settings, the photo's crop.
    public func recipe(keeping crop: CropSettings) -> Recipe {
        var r = recipe
        r.crop = crop
        return r
    }

    /// Sets the stored recipe (crop is dropped) and keeps `filmID` in step with it.
    public mutating func setRecipe(_ newRecipe: Recipe) {
        recipe = Preset.normalized(newRecipe)
        filmID = recipe.filmID
    }

    private static func normalized(_ recipe: Recipe) -> Recipe {
        var r = recipe
        r.crop = .identity
        return r
    }

    private static func resolvedFilmName(_ name: String?, filmID: String?) -> String {
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
        return filmID ?? originalName
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, filmID, filmName, nickname, recipe, created, modified, version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedRecipe = try c.decodeIfPresent(Recipe.self, forKey: .recipe) ?? .neutral
        let film = try c.decodeIfPresent(String.self, forKey: .filmID) ?? decodedRecipe.filmID
        var r = Preset.normalized(decodedRecipe)
        r.filmID = film
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        filmID = film
        filmName = Preset.resolvedFilmName(try c.decodeIfPresent(String.self, forKey: .filmName), filmID: film)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname) ?? ""
        recipe = r
        let now = Date(timeIntervalSince1970: 0)
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? now
        modified = try c.decodeIfPresent(Date.self, forKey: .modified) ?? created
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(filmID, forKey: .filmID)
        try c.encode(filmName, forKey: .filmName)
        try c.encode(nickname, forKey: .nickname)
        try c.encode(recipe, forKey: .recipe)
        try c.encode(created, forKey: .created)
        try c.encode(modified, forKey: .modified)
        try c.encode(version, forKey: .version)
    }
}
