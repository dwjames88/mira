import Foundation
import Testing
@testable import MiraCore

@Suite struct PackedLUTTests {
    /// A smooth-ish 16^3 cube with some noise, every sample UInt16 extremes included.
    static func sampleCube(n: Int = 16) -> [UInt16] {
        var rng = SystemRandomNumberGenerator()
        var out: [UInt16] = []
        for b in 0..<n { for g in 0..<n { for r in 0..<n {
            let f = { (v: Int) in UInt16(min(65535, v * 65535 / (n - 1))) }
            out += [f(r), f(g) ^ UInt16.random(in: 0...3, using: &rng), f(b)]
        } } }
        out[0] = 0; out[1] = 65535; out[2] = 32768
        return out
    }

    @Test func everyTransformAndCodecRoundTrips() throws {
        let rgb = Self.sampleCube()
        for codec in PackedLUT.Codec.allCases {
            for p in PackedLUT.Transform.Predictor.allCases {
                for z in [false, true] { for s in [false, true] {
                    let t = PackedLUT.Transform(predictor: p, zigzag: z, split: s)
                    let data = try PackedLUT.pack(dimension: 16, rgb: rgb, transform: t, codec: codec)
                    let (n, back) = try PackedLUT.unpackSamples(data)
                    #expect(n == 16 && back == rgb, "\(codec) \(p) zig=\(z) split=\(s)")
                } }
            }
        }
    }

    @Test func packingIsDeterministicAndMatchesFloatScale() throws {
        let rgb = Self.sampleCube()
        let a = try PackedLUT.pack(dimension: 16, rgb: rgb)
        #expect(a == (try PackedLUT.pack(dimension: 16, rgb: rgb)))
        let lut = try PackedLUT.unpack(a)
        let f = lut.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(f[0] == 0 && f[1] == 1 && f[3] == 1)
        for i in stride(from: 0, to: rgb.count, by: 97) {
            #expect(f[(i / 3) * 4 + i % 3] == Float(rgb[i]) * (1.0 / 65535.0))
        }
    }

    @Test func corruptFilesAreRejected() throws {
        let good = try PackedLUT.pack(dimension: 16, rgb: Self.sampleCube())
        func fails(_ d: Data, _ why: String) {
            #expect(throws: (any Error).self, "\(why)") { _ = try PackedLUT.unpack(d) }
        }
        fails(Data(), "empty")
        fails(good.prefix(10), "short header")
        fails(good.prefix(good.count / 2), "truncated payload")
        fails(Data("garbage garbage garbage".utf8), "bad magic")
        var v = good; v[4] = 9; fails(v, "version")
        var d = good; d[6] = 1; d[7] = 0; fails(d, "dimension 1")
        var d2 = good; d2[6] = 17; fails(d2, "dimension vs length")
        var c = good; c[8] = 4; fails(c, "channels")
        var t = good; t[9] = 0xF0; fails(t, "transform")
        var k = good; k[10] = 9; fails(k, "codec")
        var l = good; l[13] = 0x50; fails(l, "length")
        var junk = good; for i in 20..<min(80, junk.count) { junk[i] ^= 0xA5 }; fails(junk, "garbled payload")
    }

    @Test func libraryLoadsPackedFilesWithoutTouchingTheDiskCache() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mira-mlut-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Packed"), withIntermediateDirectories: true)
        let cache = dir.appendingPathComponent("cache")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rgb = Self.sampleCube()
        try PackedLUT.pack(dimension: 16, rgb: rgb).write(to: dir.appendingPathComponent("Packed/a.mlut"))
        try #"[{"id":"a","displayName":"A","brand":"T","family":"slide","iso":100,"file":"Packed/a.mlut"}]"#
            .write(to: dir.appendingPathComponent("films.json"), atomically: true, encoding: .utf8)
        let lib = try FilmLibrary(directory: dir, cacheDirectory: cache)
        let lut = try lib.lut(for: lib.films[0])
        #expect(lut.data == LUT(dimension: 16, rgb16: rgb).data)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
    }

    @Test func realLibraryMemoryCacheStaysBounded() throws {
        let lib = try FilmLibrary(directory: FilmTests.filmsDirectory())
        let films = lib.films.filter { $0.proceduralID == nil }
        let limit = FilmLibrary.memoryCacheLimit
        try #require(films.count > limit + 8)
        for f in films.prefix(limit + 12) {
            _ = try lib.lut(for: f)
            #expect(lib.memoryCacheCount <= limit)
        }
        #expect(lib.memoryCacheCount == limit)
    }

    @Test func singleCubeDecodeIsFast() throws {
        let lib = try FilmLibrary(directory: FilmTests.filmsDirectory())
        let film = try #require(lib.films.first { $0.proceduralID == nil })
        let data = try Data(contentsOf: lib.directory.appendingPathComponent(film.file))
        let t0 = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<5 { _ = try PackedLUT.unpack(data) }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 5e6
        // Release builds decode a 64^3 cube in ~65 ms (48^3 in ~9 ms); debug test builds are several times slower,
        // so this only catches blow-ups.
        #expect(ms < 2000, "decode took \(ms) ms")
    }

    /// A bundled packed film renders through the current (atlas) pipeline and changes the picture.
    @Test func bundledPackedCubeRendersThroughThePipeline() throws {
        let lib = try FilmLibrary(directory: FilmTests.filmsDirectory())
        let film = try #require(lib.film(id: "kodak-portra-400"))
        #expect(PackedLUT.candidateDimensions.contains(try lib.lut(for: film).dimension))
        let r = Renderer(library: lib)
        let ctx = Renderer.makeContext()
        let input = Fixture.gradientAndPatches(size: 128)
        let plain = Pixels(r.apply(Recipe(), to: input), context: ctx)
        let graded = Pixels(r.apply(Recipe(filmID: film.id), to: input), context: ctx)
        let diff = zip(plain.rgba, graded.rgba).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        #expect(diff > plain.rgba.count)   // clearly different from the ungraded image
        #expect((0..<3).allSatisfy { mean(graded.channel($0)) > 0.05 && mean(graded.channel($0)) < 0.95 })
    }
}
