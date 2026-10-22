import Foundation

/// A Semantic Versioning 2.0 version. Lenient on input ("1", "1.2", a leading "v", "+build" metadata)
/// because bundle versions in the wild are rarely strict, strict on precedence.
public struct SemanticVersion: Comparable, Hashable, Sendable, Codable, CustomStringConvertible {
    public var major: Int
    public var minor: Int
    public var patch: Int
    public var prerelease: [String]

    public init(major: Int, minor: Int, patch: Int, prerelease: [String] = []) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    public init?(_ string: String) {
        var text = Substring(string.trimmingCharacters(in: .whitespacesAndNewlines))
        if let first = text.first, first == "v" || first == "V" { text = text.dropFirst() }
        // Build metadata never affects precedence, so it is dropped.
        if let plus = text.firstIndex(of: "+") { text = text[..<plus] }

        var core = text
        var identifiers: [String] = []
        if let dash = text.firstIndex(of: "-") {
            core = text[..<dash]
            identifiers = text[text.index(after: dash)...]
                .split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            guard identifiers.allSatisfy(Self.isValidIdentifier) else { return nil }
        }

        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard Self.isDigits(part), let value = Int(part) else { return nil }
            numbers.append(value)
        }
        while numbers.count < 3 { numbers.append(0) }
        self.init(major: numbers[0], minor: numbers[1], patch: numbers[2], prerelease: identifiers)
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : core + "-" + prerelease.joined(separator: ".")
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        let l = (lhs.major, lhs.minor, lhs.patch)
        let r = (rhs.major, rhs.minor, rhs.patch)
        if l != r { return l < r }
        return comparePrerelease(lhs.prerelease, rhs.prerelease) < 0
    }

    // MARK: Codable as a single string

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = SemanticVersion(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid version \"\(string)\"")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }

    // MARK: Helpers

    private static func isDigits(_ text: some StringProtocol) -> Bool {
        !text.isEmpty && text.utf8.allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    private static func isValidIdentifier(_ id: String) -> Bool {
        guard !id.isEmpty else { return false }
        if isDigits(id) { return id == "0" || !id.hasPrefix("0") }
        return id.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D
        }
    }

    /// A version without a prerelease outranks one with it; otherwise identifiers compare left to right,
    /// numeric below alphanumeric, and a longer list outranks its own prefix.
    private static func comparePrerelease(_ l: [String], _ r: [String]) -> Int {
        switch (l.isEmpty, r.isEmpty) {
        case (true, true): return 0
        case (true, false): return 1
        case (false, true): return -1
        default: break
        }
        for (a, b) in zip(l, r) {
            let order = compareIdentifier(a, b)
            if order != 0 { return order }
        }
        return l.count == r.count ? 0 : (l.count < r.count ? -1 : 1)
    }

    private static func compareIdentifier(_ a: String, _ b: String) -> Int {
        switch (isDigits(a), isDigits(b)) {
        case (true, true):
            // No leading zeros, so length then lexical order is numeric order and cannot overflow.
            if a.count != b.count { return a.count < b.count ? -1 : 1 }
            return a == b ? 0 : (a < b ? -1 : 1)
        case (true, false): return -1
        case (false, true): return 1
        case (false, false):
            let l = Array(a.utf8), r = Array(b.utf8)
            if l == r { return 0 }
            return l.lexicographicallyPrecedes(r) ? -1 : 1
        }
    }
}
