import CoreImage
import Foundation
import Testing
@testable import MiraCore

@Suite struct FilmTests {
    static func filmsDirectory() -> URL {
        // Tests/MiraCoreTests/FilmTests.swift -> repo root
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("Films", isDirectory: true)
    }

    @Test func synthesizedFilmRoundTripsAndStrengthBlends() throws {
        // Build a tiny library on disk: one .cube film that inverts, one identity Hald-free film.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-lib-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Cube"), withIntermediateDirectories: true)
        var cube = "LUT_3D_SIZE 2\n"
        for b in 0..<2 { for g in 0..<2 { for r in 0..<2 { cube += "\(1 - r) \(1 - g) \(1 - b)\n" } } }
        try cube.write(to: dir.appendingPathComponent("Cube/invert.cube"), atomically: true, encoding: .utf8)
        let json = """
        [{"id":"invert","displayName":"Invert","brand":"Test","family":"blackAndWhite","iso":100,
          "description":"d","file":"Cube/invert.cube"}]
        """
        try json.write(to: dir.appendingPathComponent("films.json"), atomically: true, encoding: .utf8)

        let lib = try FilmLibrary(directory: dir)
        #expect(lib.films.count == 1)
        #expect(lib.film(id: "invert")?.family.displayName == "Black & White")
        #expect(lib.film(id: "nope") == nil)
        #expect(try lib.lut(for: lib.films[0]).dimension == 2)

        let r = Renderer(library: lib)
        let ctx = Renderer.makeContext()
        let input = Fixture.solid(gray: 0.25, size: 16)
        let full = Pixels(r.apply(Recipe(filmID: "invert"), to: input), context: ctx)
        // Inverted in sRGB-encoded space: 0.25 -> 0.75 (the cube is applied to gamma values).
        #expect(abs(mean(full.channel(0)) - 0.75) < 0.02)
        let half = Pixels(r.apply(Recipe(filmID: "invert", strength: 0.5), to: input), context: ctx)
        #expect(abs(mean(half.channel(0)) - 0.5) < 0.1)
        let none = Pixels(r.apply(Recipe(filmID: "invert", strength: 0), to: input), context: ctx)
        #expect(abs(mean(none.channel(0)) - 0.25) < 0.01)
    }

    @Test func everyBundledFilmRendersPlausibly() throws {
        let dir = Self.filmsDirectory()
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("films.json").path) else {
            print("SKIPPED: \(dir.path)/films.json not present yet")
            return
        }
        let library = try FilmLibrary(directory: dir)
        let renderer = Renderer(library: library)
        let ctx = Renderer.makeContext()
        let input = Fixture.gradientAndPatches(size: 256)
        let before = Pixels(input, context: ctx)

        for film in library.films {
            let after = Pixels(renderer.apply(Recipe(filmID: film.id, strength: 1), to: input), context: ctx)
            var diff = 0.0
            for i in 0..<before.rgba.count where i % 4 != 3 {
                diff += abs(Double(after.rgba[i]) - Double(before.rgba[i])) / 255
            }
            diff /= Double(before.count * 3)
            #expect(diff > 0.005, "\(film.id) barely changes the image (\(diff))")
            #expect(mean(after.luma) > 0.05, "\(film.id) renders black")
            if film.family == .blackAndWhite {
                let r = after.channel(0), g = after.channel(1), b = after.channel(2)
                let rg = mean((0..<r.count).map { abs(r[$0] - g[$0]) })
                let gb = mean((0..<r.count).map { abs(g[$0] - b[$0]) })
                #expect(rg < 0.02 && gb < 0.02, "\(film.id) is not neutral (rg \(rg), gb \(gb))")
            }
        }
    }
}
