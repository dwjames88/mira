import CoreGraphics
import Foundation
import ImageIO

/// What the metadata index remembers about one Photos asset. Plain values, so it can be stored,
/// searched and handed between threads without touching PhotoKit.
public struct AssetMetadata: Codable, Hashable, Sendable {
    public var id: String
    /// The asset's `modificationDate` when this entry was read; a different value invalidates the entry.
    public var modificationDate: Date?
    public var creationDate: Date?
    public var filename: String
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Int?
    public var focalLength: Double?
    public var fNumber: Double?
    public var exposureTime: Double?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var isRAW: Bool
    /// The original's bytes were not on this Mac (iCloud), so no EXIF could be read. Retried once per launch.
    public var unavailable: Bool

    public init(
        id: String, modificationDate: Date? = nil, creationDate: Date? = nil, filename: String = "",
        make: String? = nil, model: String? = nil, lens: String? = nil, iso: Int? = nil,
        focalLength: Double? = nil, fNumber: Double? = nil, exposureTime: Double? = nil,
        pixelWidth: Int = 0, pixelHeight: Int = 0, isRAW: Bool = false, unavailable: Bool = false
    ) {
        self.id = id
        self.modificationDate = modificationDate
        self.creationDate = creationDate
        self.filename = filename
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.focalLength = focalLength
        self.fNumber = fNumber
        self.exposureTime = exposureTime
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.isRAW = isRAW
        self.unavailable = unavailable
    }

    /// "Make Model" without repeating the make when the model already starts with it ("Canon EOS R5").
    public var cameraName: String? {
        let make = (make ?? "").trimmingCharacters(in: .whitespaces)
        let model = (model ?? "").trimmingCharacters(in: .whitespaces)
        if model.isEmpty { return make.isEmpty ? nil : make }
        if make.isEmpty || model.lowercased().hasPrefix(make.lowercased()) { return model }
        return "\(make) \(model)"
    }

    /// Copies the parsed EXIF fields in.
    public mutating func apply(_ exif: ParsedEXIF) {
        make = exif.make
        model = exif.model
        lens = exif.lens
        iso = exif.iso
        focalLength = exif.focalLength
        fNumber = exif.fNumber
        exposureTime = exif.exposureTime
    }

    // Short keys keep the 48k-line index small.
    enum CodingKeys: String, CodingKey {
        case id = "i", modificationDate = "m", creationDate = "c", filename = "f", make = "mk", model = "md"
        case lens = "l", iso = "s", focalLength = "fl", fNumber = "fn", exposureTime = "et"
        case pixelWidth = "w", pixelHeight = "h", isRAW = "r", unavailable = "u"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        modificationDate = try c.decodeIfPresent(Date.self, forKey: .modificationDate)
        creationDate = try c.decodeIfPresent(Date.self, forKey: .creationDate)
        filename = try c.decodeIfPresent(String.self, forKey: .filename) ?? ""
        make = try c.decodeIfPresent(String.self, forKey: .make)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        lens = try c.decodeIfPresent(String.self, forKey: .lens)
        iso = try c.decodeIfPresent(Int.self, forKey: .iso)
        focalLength = try c.decodeIfPresent(Double.self, forKey: .focalLength)
        fNumber = try c.decodeIfPresent(Double.self, forKey: .fNumber)
        exposureTime = try c.decodeIfPresent(Double.self, forKey: .exposureTime)
        pixelWidth = try c.decodeIfPresent(Int.self, forKey: .pixelWidth) ?? 0
        pixelHeight = try c.decodeIfPresent(Int.self, forKey: .pixelHeight) ?? 0
        isRAW = try c.decodeIfPresent(Bool.self, forKey: .isRAW) ?? false
        unavailable = try c.decodeIfPresent(Bool.self, forKey: .unavailable) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(modificationDate, forKey: .modificationDate)
        try c.encodeIfPresent(creationDate, forKey: .creationDate)
        if !filename.isEmpty { try c.encode(filename, forKey: .filename) }
        try c.encodeIfPresent(make, forKey: .make)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(lens, forKey: .lens)
        try c.encodeIfPresent(iso, forKey: .iso)
        try c.encodeIfPresent(focalLength, forKey: .focalLength)
        try c.encodeIfPresent(fNumber, forKey: .fNumber)
        try c.encodeIfPresent(exposureTime, forKey: .exposureTime)
        if pixelWidth > 0 { try c.encode(pixelWidth, forKey: .pixelWidth) }
        if pixelHeight > 0 { try c.encode(pixelHeight, forKey: .pixelHeight) }
        if isRAW { try c.encode(true, forKey: .isRAW) }
        if unavailable { try c.encode(true, forKey: .unavailable) }
    }
}

/// The camera fields read from an image's EXIF / TIFF / ExifAux dictionaries.
public struct ParsedEXIF: Equatable, Sendable {
    public var make: String?
    public var model: String?
    public var lens: String?
    public var iso: Int?
    public var focalLength: Double?
    public var fNumber: Double?
    public var exposureTime: Double?

    public init(make: String? = nil, model: String? = nil, lens: String? = nil, iso: Int? = nil,
                focalLength: Double? = nil, fNumber: Double? = nil, exposureTime: Double? = nil) {
        self.make = make
        self.model = model
        self.lens = lens
        self.iso = iso
        self.focalLength = focalLength
        self.fNumber = fNumber
        self.exposureTime = exposureTime
    }

    /// The parse found the camera, which is what the facets need; reading can stop.
    public var hasCamera: Bool { make != nil || model != nil }
    public var isEmpty: Bool { self == ParsedEXIF() }
}

/// Parses `CGImageSourceCopyPropertiesAtIndex` output, or image bytes (possibly only the first part of a file).
public enum EXIFParser {
    public static func parse(properties: [String: Any]) -> ParsedEXIF {
        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
        let aux = properties[kCGImagePropertyExifAuxDictionary as String] as? [String: Any] ?? [:]
        let dng = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any] ?? [:]

        var result = ParsedEXIF()
        result.make = string(tiff[kCGImagePropertyTIFFMake as String])
        result.model = string(tiff[kCGImagePropertyTIFFModel as String]) ?? string(dng[kCGImagePropertyDNGUniqueCameraModel as String])
        result.lens = string(exif[kCGImagePropertyExifLensModel as String]) ?? string(aux["LensModel"]) ?? string(aux["Lens"])
        if let isos = exif[kCGImagePropertyExifISOSpeedRatings as String] as? [Any], let first = isos.first {
            result.iso = int(first)
        } else if let iso = int(exif[kCGImagePropertyExifISOSpeedRatings as String]) {
            result.iso = iso
        }
        result.focalLength = number(exif[kCGImagePropertyExifFocalLength as String])
        result.fNumber = number(exif[kCGImagePropertyExifFNumber as String])
        result.exposureTime = number(exif[kCGImagePropertyExifExposureTime as String])
        return result
    }

    /// Parses bytes with an incremental image source, so a truncated file (the first ~256 KB) still yields
    /// its header metadata. `isFinal` tells ImageIO that no more bytes will come.
    public static func parse(data: Data, isFinal: Bool = true) -> ParsedEXIF? {
        let source = CGImageSourceCreateIncremental(nil)
        CGImageSourceUpdateData(source, data as CFData, isFinal)
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else { return nil }
        return parse(properties: props)
    }

    private static func string(_ value: Any?) -> String? {
        guard let s = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)), !s.isEmpty else { return nil }
        return s
    }
    private static func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }
    private static func int(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
}

/// A reusable incremental reader: feed it chunks as they arrive and it says when the camera fields are known.
/// Not thread-safe; the caller serialises access.
public final class EXIFAccumulator {
    public private(set) var received = 0
    private var buffer = Data()
    private var nextAttempt: Int
    private let step: Int
    public let limit: Int

    /// - Parameters: `limit` is the most bytes to read; `step` how many new bytes between parse attempts.
    public init(limit: Int = 256 * 1024, firstAttempt: Int = 24 * 1024, step: Int = 48 * 1024) {
        self.limit = limit
        self.nextAttempt = firstAttempt
        self.step = step
    }

    public enum Outcome: Equatable {
        case needMore
        /// Camera fields found, or the byte limit reached: stop reading.
        case done(ParsedEXIF)
    }

    public func append(_ chunk: Data) -> Outcome {
        buffer.append(chunk)
        received = buffer.count
        let atLimit = received >= limit
        guard received >= nextAttempt || atLimit else { return .needMore }
        nextAttempt = received + step
        let parsed = EXIFParser.parse(data: buffer, isFinal: false)
        if let parsed, parsed.hasCamera { return .done(parsed) }
        return atLimit ? .done(parsed ?? ParsedEXIF()) : .needMore
    }

    /// The stream ended (or failed) before `append` said done: parse whatever arrived as the whole file.
    public func finish() -> ParsedEXIF? {
        guard !buffer.isEmpty else { return nil }
        return EXIFParser.parse(data: buffer, isFinal: true)
    }
}
