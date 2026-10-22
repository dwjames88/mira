import Foundation

/// One downloadable file of a GitHub release.
public struct ReleaseAsset: Sendable, Equatable {
    public var name: String
    public var downloadURL: URL
    public var size: Int64
    /// Lowercase hex SHA-256 from GitHub's `digest` field ("sha256:..."), when present.
    public var sha256: String?

    public init(name: String, downloadURL: URL, size: Int64, sha256: String? = nil) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.sha256 = sha256
    }

    public var isZip: Bool { name.lowercased().hasSuffix(".zip") }
    public var isDiskImage: Bool { name.lowercased().hasSuffix(".dmg") }
}

/// The parts of `GET /repos/{owner}/{repo}/releases/latest` the updater uses.
public struct Release: Sendable, Equatable {
    public var tag: String
    public var version: SemanticVersion
    public var title: String
    /// Release notes as published (markdown).
    public var notes: String
    public var pageURL: URL
    public var isPrerelease: Bool
    public var assets: [ReleaseAsset]

    public init(tag: String, version: SemanticVersion, title: String, notes: String, pageURL: URL,
                isPrerelease: Bool = false, assets: [ReleaseAsset]) {
        self.tag = tag
        self.version = version
        self.title = title
        self.notes = notes
        self.pageURL = pageURL
        self.isPrerelease = isPrerelease
        self.assets = assets
    }

    // MARK: Decoding

    private struct DTO: Decodable {
        struct Asset: Decodable {
            var name: String
            var browser_download_url: String
            var size: Int64?
            var digest: String?
        }
        var tag_name: String
        var name: String?
        var body: String?
        var html_url: String?
        var prerelease: Bool?
        var draft: Bool?
        var assets: [Asset]?
    }

    public static func decode(_ data: Data) throws -> Release {
        let dto: DTO
        do {
            dto = try JSONDecoder().decode(DTO.self, from: data)
        } catch {
            throw UpdateError.invalidResponse("not a release (\(error.localizedDescription))")
        }
        guard let version = SemanticVersion(dto.tag_name) else {
            throw UpdateError.invalidResponse("tag \"\(dto.tag_name)\" is not a version")
        }
        guard let page = dto.html_url.flatMap(URL.init(string:)) else {
            throw UpdateError.invalidResponse("no release page URL")
        }
        let assets: [ReleaseAsset] = (dto.assets ?? []).compactMap { asset in
            guard let url = URL(string: asset.browser_download_url) else { return nil }
            var digest: String?
            if let value = asset.digest?.lowercased(), value.hasPrefix("sha256:") {
                digest = String(value.dropFirst("sha256:".count))
            }
            return ReleaseAsset(name: asset.name, downloadURL: url, size: asset.size ?? 0, sha256: digest)
        }
        let title = (dto.name?.isEmpty == false ? dto.name : nil) ?? "Mira \(version)"
        return Release(tag: dto.tag_name, version: version, title: title, notes: dto.body ?? "", pageURL: page,
                       isPrerelease: dto.prerelease ?? false, assets: assets)
    }

    // MARK: Asset selection

    /// Only GitHub download hosts over https are trusted to serve the update.
    public static func isTrustedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host?.lowercased() else { return false }
        return host == "github.com" || host.hasSuffix(".github.com")
            || host == "githubusercontent.com" || host.hasSuffix(".githubusercontent.com")
    }

    /// The archive to install from: `Mira-<version>.zip`, else another Mira `.zip`. `nil` when there is none.
    public var zipAsset: ReleaseAsset? {
        let trusted = assets.filter { Self.isTrustedDownloadURL($0.downloadURL) }
        let exact = "mira-\(version.description).zip"
        let tagged = "mira-\(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag).zip"
        return trusted.first { $0.name.lowercased() == exact }
            ?? trusted.first { $0.name.lowercased() == tagged }
            ?? trusted.first { $0.isZip && $0.name.lowercased().hasPrefix("mira") }
    }

    /// The disk image, used for a manual install only when there is no zip.
    public var diskImageAsset: ReleaseAsset? {
        let trusted = assets.filter { Self.isTrustedDownloadURL($0.downloadURL) }
        let exact = "mira-\(version.description).dmg"
        return trusted.first { $0.name.lowercased() == exact }
            ?? trusted.first { $0.isDiskImage && $0.name.lowercased().hasPrefix("mira") }
    }

    /// What the updater downloads: the zip, else the dmg.
    public var installableAsset: ReleaseAsset? { zipAsset ?? diskImageAsset }
}
