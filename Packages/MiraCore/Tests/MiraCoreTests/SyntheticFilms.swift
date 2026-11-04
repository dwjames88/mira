import Foundation
@testable import MiraCore

/// Builds throwaway film libraries from `.cube` files so pipeline tests do not depend on films.json.
enum SyntheticFilms {
    enum Cube {
        case identity
        /// out = in^2 on the sRGB-encoded values (strongly non-linear, so the order of stages matters).
        case square
        case invert
    }

    struct Spec {
        var id: String
        var family: FilmFamily
        var iso: Int = 400
        var cube: Cube = .identity
        var monochrome: Bool? = nil
        var character: FilmCharacter.Override? = nil
    }

    static func cubeText(_ cube: Cube) -> String {
        let n = cube == .identity ? 2 : 17
        var text = "LUT_3D_SIZE \(n)\n"
        func f(_ v: Double) -> Double {
            switch cube {
            case .identity: v
            case .square: v * v
            case .invert: 1 - v
            }
        }
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let d = Double(n - 1)
            text += "\(f(Double(r) / d)) \(f(Double(g) / d)) \(f(Double(b) / d))\n"
        } } }
        return text
    }

    static func library(_ specs: [Spec]) throws -> FilmLibrary {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-synth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Cube"), withIntermediateDirectories: true)
        var films: [Film] = []
        for s in specs {
            let file = "Cube/\(s.id).cube"
            try cubeText(s.cube).write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            films.append(Film(id: s.id, displayName: s.id, brand: "Test", family: s.family, iso: s.iso,
                              description: "d", file: file, monochrome: s.monochrome, character: s.character))
        }
        let data = try JSONEncoder().encode(films)
        try data.write(to: dir.appendingPathComponent("films.json"))
        return try FilmLibrary(directory: dir)
    }
}
