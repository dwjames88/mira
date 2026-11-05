import Compression
import Foundation
import MiraCore

/// `--pack-films <FilmSources dir> <Films dir>`: regenerates `<Films>/Packed/<id>.mlut` from the Hald PNGs
/// (`<FilmSources>/<film.png>`) for every non-procedural film in `<Films>/films.json`. Deterministic.
enum PackFilms {
    static func run(sources: String, films: String) throws {
        let src = URL(fileURLWithPath: sources, isDirectory: true)
        let dst = URL(fileURLWithPath: films, isDirectory: true)
        let library = try FilmLibrary(directory: dst)
        let packedDir = dst.appendingPathComponent("Packed", isDirectory: true)
        try? FileManager.default.removeItem(at: packedDir)
        try FileManager.default.createDirectory(at: packedDir, withIntermediateDirectories: true)
        var total = 0, count = 0
        for film in library.films where film.proceduralID == nil {
            guard let png = film.png else { throw PackError.noSource(film.id) }
            let (n, rgb) = try LUT.haldSamples(url: src.appendingPathComponent(png))
            guard n <= LUT.maxHaldDimension else { throw PackError.tooLarge(film.id, n) }
            let data = try PackedLUT.pack(dimension: n, rgb: rgb)
            try data.write(to: dst.appendingPathComponent(film.file), options: .atomic)
            total += data.count; count += 1
        }
        print("Packed \(count) films, \(total) bytes (\(String(format: "%.1f", Double(total) / 1_048_576)) MB)")
    }

    /// `--pack-bench <FilmSources dir>`: size and decode time of every transform/codec on a sample of cubes.
    static func bench(sources: String) throws {
        let dir = URL(fileURLWithPath: sources, isDirectory: true).appendingPathComponent("HaldCLUT")
        let all = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()
        let sample = all.enumerated().filter { $0.offset % 13 == 0 }.map(\.element)
        let cubes = try sample.map { try LUT.haldSamples(url: dir.appendingPathComponent($0)) }
        print("sample: \(cubes.count) of \(all.count) cubes")
        func measure(_ t: PackedLUT.Transform, _ codec: PackedLUT.Codec, _ cubes: ArraySlice<(dimension: Int, rgb: [UInt16])>) throws -> Double {
            var bytes = 0
            var packed: [Data] = []
            let t0 = DispatchTime.now().uptimeNanoseconds
            for c in cubes {
                let d = try PackedLUT.pack(dimension: c.dimension, rgb: c.rgb, transform: t, codec: codec)
                bytes += d.count; packed.append(d)
            }
            let enc = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6 / Double(packed.count)
            let t1 = DispatchTime.now().uptimeNanoseconds
            for d in packed { _ = try PackedLUT.unpackSamples(d) }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - t1) / 1e6 / Double(packed.count)
            let avg = Double(bytes) / Double(cubes.count)
            print(String(format: "%@ pred=%@ zig=%d split=%d  avg %8.0f B  encode %7.0f ms  decode %5.1f ms",
                         "\(codec)", "\(t.predictor)", t.zigzag ? 1 : 0, t.split ? 1 : 0, avg, enc, ms))
            fflush(stdout)
            return avg
        }
        // Lossless best candidates (LZMA is slow to encode, so few cubes).
        let left = PackedLUT.Transform(predictor: .left, zigzag: false, split: false)
        _ = try measure(left, .lzma, cubes.prefix(2))
        // Exploration (lossy, NOT shipped): drop low bits / resample, to see how much is noise.
        for shift in [0, 2, 4, 6, 8] {
            let q = cubes.map { c in (dimension: c.dimension, rgb: c.rgb.map { v in shift == 0 ? v : UInt16(min(65535, ((Int(v) + (1 << (shift - 1))) >> shift) << shift)) }) }
            print("quantize low \(shift) bits:", terminator: " ")
            _ = try measure(left, .lzfse, q[...])
        }
        for m in [48, 32] {
            let q = cubes.map { c -> (dimension: Int, rgb: [UInt16]) in
                let r = LUT(dimension: c.dimension, rgb16: c.rgb).resampled(to: m)
                let f = r.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                var out = [UInt16](repeating: 0, count: m * m * m * 3)
                for i in 0..<(m * m * m) { for ch in 0..<3 { out[i * 3 + ch] = UInt16((min(max(f[i * 4 + ch], 0), 1) * 65535).rounded()) } }
                return (m, out)
            }
            print("resample \(m)^3:", terminator: " ")
            _ = try measure(left, .lzfse, q[...])
        }
    }

    enum PackError: Error, CustomStringConvertible {
        case noSource(String)
        case tooLarge(String, Int)
        var description: String {
            switch self {
            case .noSource(let id): "\(id): films.json has no \"png\" source"
            case .tooLarge(let id, let n): "\(id): cube dimension \(n) exceeds \(LUT.maxHaldDimension)"
            }
        }
    }
}
