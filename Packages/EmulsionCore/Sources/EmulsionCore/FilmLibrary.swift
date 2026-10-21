import Foundation

/// Reads `films.json` from a directory and lazily loads (and caches) each film's LUT.
public final class FilmLibrary: @unchecked Sendable {
    public let directory: URL
    public let films: [Film]

    private let lock = NSLock()
    private var cache: [String: LUT] = [:]
    private let index: [String: Film]

    public init(directory: URL) throws {
        self.directory = directory
        let data = try Data(contentsOf: directory.appendingPathComponent("films.json"))
        let films = try JSONDecoder().decode([Film].self, from: data)
        self.films = films
        self.index = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func film(id: String) -> Film? { index[id] }

    public func lut(for film: Film) throws -> LUT {
        lock.lock()
        if let hit = cache[film.id] { lock.unlock(); return hit }
        lock.unlock()

        let url = directory.appendingPathComponent(film.file)
        let lut: LUT
        switch url.pathExtension.lowercased() {
        case "cube":
            lut = try LUT.parseCube(String(contentsOf: url, encoding: .utf8))
        default:
            lut = try LUT.loadHald(url: url)
        }

        lock.lock()
        cache[film.id] = lut
        lock.unlock()
        return lut
    }

    /// Looks for a folder named `Films` in the bundle's resources.
    public static func bundled(in bundle: Bundle = .main) -> FilmLibrary? {
        guard let dir = bundle.resourceURL?.appendingPathComponent("Films", isDirectory: true) else { return nil }
        return try? FilmLibrary(directory: dir)
    }
}
