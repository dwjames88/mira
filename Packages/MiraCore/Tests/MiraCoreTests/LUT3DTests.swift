import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import Testing
@testable import MiraCore

/// The float 3D LUT stage of pipeline 2 (`miraLUT3D`): precision, agreement with `CIColorCubeWithColorSpace`.
@Suite struct LUT3DTests {
    let context = Renderer.sharedContext
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func decode(_ v: Double) -> Float {
        Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
    }

    /// 4,000 steps of sRGB-encoded grey, held as linear float.
    static func ramp(_ steps: Int = 4000) -> CIImage {
        PipelineFixture.linearImage(width: steps, height: 1) { x, _ in
            let l = decode(Double(x) / Double(steps - 1))
            return (l, l, l)
        }
    }

    func distinctLevels(_ image: CIImage) -> Int {
        let r = image.extent
        let w = Int(r.width)
        var buf = [UInt16](repeating: 0, count: w * 4)
        context.render(image, toBitmap: &buf, rowBytes: w * 8, bounds: r, format: .RGBA16, colorSpace: Self.sRGB)
        return Set((0..<w).map { buf[$0 * 4 + 1] }).count
    }

    static func realLibrary() throws -> FilmLibrary? {
        let dir = FilmTests.filmsDirectory()
        guard FileManager.default.fileExists(atPath: dir.appendingPathComponent("films.json").path) else { return nil }
        return try FilmLibrary(directory: dir)
    }

    @Test func rampKeepsFloatPrecisionThroughIdentityAndRealFilm() throws {
        let identity = Renderer(library: try SyntheticFilms.library([.init(id: "id", family: .colorNegative)]))
        let viaIdentity = distinctLevels(identity.apply(Recipe(filmID: "id"), to: Self.ramp()))
        print("LUT3D distinct 16-bit levels, identity LUT: \(viaIdentity)")
        #expect(viaIdentity >= 3000)

        guard let lib = try Self.realLibrary(), let film = lib.film(id: "kodak-portra-400") ?? lib.films.first else { return }
        let viaFilm = distinctLevels(Renderer(library: lib).apply(Recipe(filmID: film.id), to: Self.ramp()))
        print("LUT3D distinct 16-bit levels, \(film.id): \(viaFilm)")
        #expect(viaFilm >= 3000)
    }

    @Test func matchesColorCubeWithinOneLevel() throws {
        let input = Fixture.gradientAndPatches(size: 256)
        var luts: [(String, LUT)] = []
        let synthetic = try SyntheticFilms.library([.init(id: "sq", family: .colorNegative, cube: .square),
                                                    .init(id: "inv", family: .colorNegative, cube: .invert)])
        for id in ["sq", "inv"] { luts.append((id, try synthetic.lut(for: try #require(synthetic.film(id: id))))) }
        if let lib = try Self.realLibrary() {
            for film in lib.films.prefix(5) { luts.append((film.id, try lib.lut(for: film))) }
        }
        var worst = 0.0
        for (id, lut) in luts {
            let f = CIFilter.colorCubeWithColorSpace()
            f.inputImage = input
            f.cubeDimension = Float(lut.dimension)
            f.cubeData = lut.data
            f.colorSpace = Self.sRGB
            let old = Pixels(f.outputImage!, context: context)
            let new = Pixels(try #require(GradeKernels.applyLUT3D(lut, cacheKey: "test:\(id)", to: input)), context: context)
            var d = 0.0
            for i in 0..<old.rgba.count where i % 4 != 3 { d = max(d, abs(Double(old.rgba[i]) - Double(new.rgba[i]))) }
            print("LUT3D vs CIColorCube, \(id): max difference \(d) / 255")
            worst = max(worst, d)
            #expect(d <= 1.0 + 1e-9, "\(id): \(d)")
        }
        print("LUT3D vs CIColorCube worst case over \(luts.count) cubes: \(worst) / 255")
    }

    @Test func atlasCacheIsBoundedAndNotStale() throws {
        let a = try SyntheticFilms.library([.init(id: "x", family: .colorNegative, cube: .square)])
        let b = try SyntheticFilms.library([.init(id: "x", family: .colorNegative, cube: .invert)])
        let lutA = try a.lut(for: try #require(a.film(id: "x"))), lutB = try b.lut(for: try #require(b.film(id: "x")))
        let input = Fixture.solid(gray: 0.5, size: 8)
        func mid(_ lut: LUT) throws -> UInt8 {
            Pixels(try #require(GradeKernels.applyLUT3D(lut, cacheKey: "stale", to: input)), context: context).rgba[1]
        }
        #expect(abs(Int(try mid(lutA)) - 64) <= 1)    // 0.5^2 = 0.25
        #expect(abs(Int(try mid(lutB)) - 128) <= 1)   // same id, new cube
        for i in 0..<(LUTAtlasCache.limit + 10) { _ = LUTAtlasCache.shared.atlas(for: lutA, key: "bound\(i)") }
        #expect(LUTAtlasCache.shared.count <= LUTAtlasCache.limit)
    }
}
