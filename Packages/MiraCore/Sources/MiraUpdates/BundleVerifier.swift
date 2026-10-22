import Foundation
import Security

/// Checks that an unpacked app really is the Mira release it should be: identifier, version, and a valid
/// code signature from the FieldFrames team. This is the trust anchor for updates (there is no appcast
/// signature), so it reads everything from disk and pins the team.
public enum BundleVerifier {
    public static let bundleIdentifier = "com.fieldframes.mira"
    public static let teamIdentifier = "VF945J28YU"

    /// `anchor apple generic and identifier "..." and certificate leaf[subject.OU] = "..."`
    public static func requirement(bundleIdentifier: String = bundleIdentifier, teamIdentifier: String = teamIdentifier) -> String {
        "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }

    /// Info.plist keys read from disk (not `Bundle(url:)`, which can return a cached dictionary).
    public static func readInfo(ofBundleAt url: URL) -> [String: Any]? {
        let plist = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = object as? [String: Any] else { return nil }
        return info
    }

    /// Throws `bundleMismatch` or `signatureInvalid`. Pass `version: nil` to skip the version check.
    public static func verify(
        bundleAt url: URL, bundleIdentifier: String = bundleIdentifier, teamIdentifier: String = teamIdentifier,
        version: SemanticVersion?
    ) throws {
        guard let info = readInfo(ofBundleAt: url) else { throw UpdateError.bundleMismatch("no readable Info.plist") }
        let identifier = info["CFBundleIdentifier"] as? String
        guard identifier == bundleIdentifier else {
            throw UpdateError.bundleMismatch("identifier \(identifier ?? "(none)") is not \(bundleIdentifier)")
        }
        if let version {
            let short = info["CFBundleShortVersionString"] as? String
            guard let short, SemanticVersion(short) == version else {
                throw UpdateError.bundleMismatch("version \(short ?? "(none)") is not \(version)")
            }
        }
        try checkSignature(at: url, requirement: requirement(bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier))
    }

    static func checkSignature(at url: URL, requirement text: String) throws {
        var code: SecStaticCode?
        var status = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        guard status == errSecSuccess, let code else { throw UpdateError.signatureInvalid(describe(status)) }
        var requirement: SecRequirement?
        status = SecRequirementCreateWithString(text as CFString, [], &requirement)
        guard status == errSecSuccess, let requirement else { throw UpdateError.signatureInvalid(describe(status)) }
        let flags = SecCSFlags(rawValue: UInt32(kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode))
        status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else { throw UpdateError.signatureInvalid(describe(status)) }
    }

    private static func describe(_ status: OSStatus) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
    }
}
