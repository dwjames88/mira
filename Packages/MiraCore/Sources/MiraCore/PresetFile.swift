import Foundation
import UniformTypeIdentifiers

public extension UTType {
    /// A shared Mira preset: one `.mirapreset` JSON file. Declared in the app's Info.plist
    /// (`UTExportedTypeDeclarations`).
    static let miraPreset = UTType(exportedAs: PresetFile.typeIdentifier, conformingTo: .json)
}

/// Why a `.mirapreset` file was not imported. `description` is a short phrase for a notice.
public enum PresetFileError: Error, Equatable, Sendable, CustomStringConvertible {
    case unreadable
    case notAPresetFile
    case newerVersion(Int)
    case missingNickname
    case tooLarge

    public var description: String {
        switch self {
        case .unreadable: "the file could not be read"
        case .notAPresetFile: "not a Mira preset file"
        case .newerVersion: "made by a newer version of Mira"
        case .missingNickname: "the preset has no name"
        case .tooLarge: "the file is too large"
        }
    }
}

/// The `.mirapreset` share format: one preset per file, JSON with sorted keys.
///
/// ```
/// {"appVersion":"0.3.1","exported":"...","format":"com.fieldframes.mira.preset",
///  "preset":{"created":"...","filmID":"...","filmName":"...","nickname":"...","recipe":{...}},
///  "schemaVersion":1}
/// ```
///
/// No photo data is stored, and the recipe carries no crop and no dodge and burn strokes (they belong to a photo). Reading is
/// tolerant: unknown keys are ignored and the recipe uses `Recipe`'s tolerant decoder.
public enum PresetFile {
    public static let typeIdentifier = "com.fieldframes.mira.preset"
    public static let fileExtension = "mirapreset"
    public static let format = "com.fieldframes.mira.preset"
    public static let schemaVersion = 1
    /// A real preset file is a couple of kilobytes; anything past this is not one.
    static let maxBytes = 1_000_000

    // MARK: Names

    /// "Portra 400 - Last Summer.mirapreset", with `/` and `:` (and control characters) made safe.
    public static func fileName(for preset: Preset) -> String {
        sanitized(preset.displayName) + "." + fileExtension
    }

    /// Replaces path separators and colons with a hyphen, drops control characters, trims dots and spaces.
    public static func sanitized(_ name: String) -> String {
        var out = ""
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" {
                out.append("-")
            } else if scalar.properties.generalCategory == .control {
                continue
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        out = out.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".")))
        if out.count > 120 { out = String(out.prefix(120)).trimmingCharacters(in: .whitespaces) }
        return out.isEmpty ? "Preset" : out
    }

    /// `nickname` made unique among `existing` display names for `filmName`: "Last Summer" becomes
    /// "Last Summer 2", then "Last Summer 3"... Unchanged when nothing clashes.
    public static func uniqueNickname(_ nickname: String, filmName: String, among existing: [Preset]) -> String {
        let taken = Set(existing.map { key($0.displayName) })
        if !taken.contains(key(Preset.displayName(filmName: filmName, nickname: nickname))) { return nickname }
        var n = 2
        while taken.contains(key(Preset.displayName(filmName: filmName, nickname: "\(nickname) \(n)"))) { n += 1 }
        return "\(nickname) \(n)"
    }

    /// Display names are compared without case and surrounding space.
    public static func key(_ displayName: String) -> String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    // MARK: Encoding

    public static func encode(_ preset: Preset, appVersion: String, exported: Date = Date()) throws -> Data {
        var recipe = preset.recipe
        recipe.crop = .identity
        recipe.dodgeBurn = .identity
        let file = FileModel(
            format: format, schemaVersion: schemaVersion, appVersion: appVersion, exported: dateText(exported),
            preset: Body(nickname: preset.nickname, filmID: preset.filmID, filmName: preset.filmName,
                         created: dateText(preset.created), recipe: recipe))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(file)
    }

    /// Writes `<dir>/<file name>`, adding " 2", " 3"... before the extension rather than replacing a file.
    @discardableResult
    public static func write(_ preset: Preset, into directory: URL, appVersion: String,
                             uniquely: Bool = true) throws -> URL {
        let data = try encode(preset, appVersion: appVersion)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = sanitized(preset.displayName)
        var url = directory.appendingPathComponent(base + "." + fileExtension)
        var n = 2
        while uniquely, fm.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base) \(n).\(fileExtension)")
            n += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: Decoding

    /// A preset with a new id, ready to add to a store. Throws `PresetFileError`.
    public static func decode(_ data: Data) throws -> Preset {
        guard data.count <= maxBytes else { throw PresetFileError.tooLarge }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data), header.format == format else {
            throw PresetFileError.notAPresetFile
        }
        guard let version = header.schemaVersion, version >= 1 else { throw PresetFileError.notAPresetFile }
        guard version <= schemaVersion else { throw PresetFileError.newerVersion(version) }
        guard let body = try? decoder.decode(LossyBody.self, from: data).preset else {
            throw PresetFileError.notAPresetFile
        }
        let nickname = (body.nickname ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nickname.isEmpty else { throw PresetFileError.missingNickname }
        var recipe = body.recipe ?? .neutral
        recipe.crop = .identity
        recipe.dodgeBurn = .identity
        if let film = body.filmID, !film.isEmpty { recipe.filmID = film }
        let created = body.created.flatMap(parseDate) ?? Date()
        return Preset(nickname: nickname, recipe: recipe, filmName: body.filmName, created: created, modified: Date())
    }

    /// Reads and decodes a file, with the sandbox access the URL carries (open panel, drop, Finder).
    public static func read(_ url: URL) throws -> Preset {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            throw PresetFileError.tooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw PresetFileError.unreadable }
        return try decode(data)
    }

    /// True for a URL that names a preset file (by extension).
    public static func isPresetFile(_ url: URL) -> Bool {
        url.isFileURL && url.pathExtension.lowercased() == fileExtension
    }

    // MARK: Model

    private struct Header: Decodable {
        var format: String?
        var schemaVersion: Int?
    }

    private struct Body: Codable {
        var nickname: String?
        var filmID: String?
        var filmName: String?
        var created: String?
        var recipe: Recipe?
    }

    private struct LossyBody: Decodable {
        var preset: Body?
    }

    private struct FileModel: Encodable {
        var format: String
        var schemaVersion: Int
        var appVersion: String
        var exported: String
        var preset: Body
    }

    private static func dateText(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private static func parseDate(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: text) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: text)
    }
}
