import Foundation

/// Why an update step could not complete. `userMessage` is the sentence shown in the update window;
/// `description` is for logs.
public enum UpdateError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The server could not be reached (offline, DNS, TLS, timeout).
    case network(String)
    /// The server answered with a non-200 status. 404 means no release yet, 401/403 an access or rate limit problem.
    case httpStatus(Int)
    /// The response was not the JSON we expect.
    case invalidResponse(String)
    /// The release has no `.zip` or `.dmg` asset, or its URL is not a GitHub download URL.
    case noInstallableAsset
    case sizeMismatch(expected: Int64, actual: Int64)
    case digestMismatch
    case archiveInvalid(String)
    /// The unpacked app is not Mira, or not the version the release promised.
    case bundleMismatch(String)
    /// The unpacked app is unsigned, tampered with, or signed by another team.
    case signatureInvalid(String)
    case installFailed(String)
    /// The user did not grant access to the folder Mira lives in.
    case accessDenied
    case cancelled

    public var description: String {
        switch self {
        case .network(let reason): "Could not reach GitHub: \(reason)"
        case .httpStatus(let code): "GitHub answered HTTP \(code)."
        case .invalidResponse(let reason): "Unexpected response from GitHub: \(reason)"
        case .noInstallableAsset: "The release has no downloadable Mira archive."
        case .sizeMismatch(let expected, let actual): "The download is \(actual) bytes, expected \(expected)."
        case .digestMismatch: "The download's SHA-256 does not match the release."
        case .archiveInvalid(let reason): "The update archive is invalid: \(reason)"
        case .bundleMismatch(let reason): "The update is not the expected app: \(reason)"
        case .signatureInvalid(let reason): "The update's code signature is not valid: \(reason)"
        case .installFailed(let reason): "The update could not be installed: \(reason)"
        case .accessDenied: "Mira was not given access to its folder."
        case .cancelled: "The update was cancelled."
        }
    }

    public var userMessage: String {
        switch self {
        case .network: "Mira could not reach GitHub. Check your internet connection and try again."
        case .httpStatus(404): "No Mira release was found on GitHub."
        case .httpStatus(401), .httpStatus(403): "GitHub refused the request (access denied or rate limited). Try again later."
        case .httpStatus(let code): "GitHub answered with an error (HTTP \(code)). Try again later."
        case .invalidResponse: "GitHub sent a response Mira could not read."
        case .noInstallableAsset: "The latest release has no Mira download attached."
        case .sizeMismatch, .digestMismatch: "The download did not match what GitHub published, so it was discarded."
        case .archiveInvalid: "The download could not be unpacked, so it was discarded."
        case .bundleMismatch: "The download is not the Mira release it claimed to be, so it was discarded."
        case .signatureInvalid: "The download is not signed by FieldFrames or was modified, so it was discarded."
        case .installFailed(let reason): "The update could not be installed: \(reason)"
        case .accessDenied: "Without access to the folder Mira lives in, it cannot replace itself."
        case .cancelled: "The update was cancelled."
        }
    }
}
