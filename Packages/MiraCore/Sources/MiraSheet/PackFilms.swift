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
            let m = PackedLUT.shippedDimension
            let data = try PackedLUT.pack(dimension: m, rgb: n == m ? rgb : PackedLUT.resampled(rgb, from: n, to: m))
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
        let cubes = try sample.map { name -> (dimension: Int, rgb: [UInt16]) in
            let (n, rgb) = try LUT.haldSamples(url: dir.appendingPathComponent(name))
            let m = PackedLUT.shippedDimension
            return (m, PackedLUT.resampled(rgb, from: n, to: m))
        }
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
        for predictor in PackedLUT.Transform.Predictor.allCases {
            for zigzag in [false, true] {
                for split in [false, true] {
                    let t = PackedLUT.Transform(predictor: predictor, zigzag: zigzag, split: split)
                    _ = try measure(t, .lzma, cubes.prefix(4))
                }
            }
        }
    }

    enum PackError: Error, CustomStringConvertible {
        case noSource(String)
        var description: String {
            switch self {
            case .noSource(let id): "\(id): films.json has no \"png\" source"
            }
        }
    }
}

/// `--pack-fidelity <FilmSources> <Films>`: error of each shipped cube against its 64^3 original (exploration/report).
extension PackFilms {
    static func fidelity(sources: String, films: String) throws {
        let src = URL(fileURLWithPath: sources, isDirectory: true)
        let dst = URL(fileURLWithPath: films, isDirectory: true)
        let library = try FilmLibrary(directory: dst)
        var worstMax: (Float, String) = (0, ""), worstMean: (Float, String) = (0, "")
        var p99s: [Float] = []
        for film in library.films where film.proceduralID == nil {
            let orig = try LUT.loadHald(url: src.appendingPathComponent(film.png!))
            let packed = try PackedLUT.unpack(Data(contentsOf: dst.appendingPathComponent(film.file)))
            let up = packed.resampled(to: 64)   // trilinear at the 64^3 lattice points
            let a = orig.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let b = up.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            var errs: [Float] = []; errs.reserveCapacity(a.count / 4 * 3)
            var sums = [Double](repeating: 0, count: 3)
            for i in 0..<(a.count / 4) { for c in 0..<3 { let e = abs(a[i * 4 + c] - b[i * 4 + c]); errs.append(e); sums[c] += Double(e) } }
            errs.sort()
            let mx = errs.last!, mean = Float(sums.max()! / Double(a.count / 4))
            p99s.append(errs[Int(Double(errs.count) * 0.999)])
            if mx > worstMax.0 { worstMax = (mx, film.id) }
            if mean > worstMean.0 { worstMean = (mean, film.id) }
        }
        p99s.sort()
        print(String(format: "worst max %.2f/255 (%@), worst mean %.3f/255 (%@), median p99.9 %.2f/255, worst p99.9 %.2f/255",
                     worstMax.0 * 255, worstMax.1, worstMean.0 * 255, worstMean.1, p99s[p99s.count / 2] * 255, p99s.last! * 255))
    }
}

extension PackFilms {
    /// `--pack-dims <FilmSources>`: error and LZMA size for several cube dimensions on a 20-cube sample.
    static func dims(sources: String) throws {
        let dir = URL(fileURLWithPath: sources, isDirectory: true).appendingPathComponent("HaldCLUT")
        let all = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".png") }.sorted()
        let sample = all.enumerated().filter { $0.offset % 13 == 0 }.map(\.element)
        for m in [40, 48, 56, 64] {
            var worstMax: Float = 0, worstMean: Float = 0, bytes = 0
            for (k, name) in sample.enumerated() {
                let orig = try LUT.loadHald(url: dir.appendingPathComponent(name))
                let rgb = PackedLUT.resampled(orig.data.withUnsafeBytes { raw -> [UInt16] in
                    let f = Array(raw.bindMemory(to: Float.self))
                    var o = [UInt16](repeating: 0, count: 64 * 64 * 64 * 3)
                    for i in 0..<(64 * 64 * 64) { for c in 0..<3 { o[i * 3 + c] = UInt16((f[i * 4 + c] * 65535).rounded()) } }
                    return o }, from: 64, to: m)
                if k < 3 { bytes += try PackedLUT.pack(dimension: m, rgb: rgb).count }
                let up = LUT(dimension: m, rgb16: rgb).resampled(to: 64)
                let a = orig.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                let b = up.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                var mx: Float = 0; var sums = [Double](repeating: 0, count: 3)
                for i in 0..<(a.count / 4) { for c in 0..<3 { let e = abs(a[i * 4 + c] - b[i * 4 + c]); mx = max(mx, e); sums[c] += Double(e) } }
                worstMax = max(worstMax, mx); worstMean = max(worstMean, Float(sums.max()! / Double(a.count / 4)))
            }
            print(String(format: "%d^3: worst max %.2f/255, worst mean %.3f/255, LZMA avg %d KB -> ~%d MB for 260", m, worstMax * 255, worstMean * 255, bytes / 3 / 1024, bytes / 3 * 260 / 1_048_576))
            fflush(stdout)
        }
    }
}
