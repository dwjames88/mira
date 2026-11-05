import Foundation
import MiraCore

/// `--pack-films <FilmSources dir> <Films dir>`: regenerates `<Films>/Packed/<id>.mlut` from the Hald PNGs
/// (`<FilmSources>/<film.png>`) for every non-procedural film in `<Films>/films.json`. Deterministic.
/// Each film gets the smallest cube dimension (48, 56, else the exact 64) whose error against the 64^3 original
/// stays within `PackedLUT.acceptedMaxError` / `acceptedP999Error`. Prints a summary table.
enum PackFilms {
    static func run(sources: String, films: String) throws {
        let src = URL(fileURLWithPath: sources, isDirectory: true)
        let dst = URL(fileURLWithPath: films, isDirectory: true)
        let library = try FilmLibrary(directory: dst)
        let packedDir = dst.appendingPathComponent("Packed", isDirectory: true)
        try? FileManager.default.removeItem(at: packedDir)
        try FileManager.default.createDirectory(at: packedDir, withIntermediateDirectories: true)
        // Optional what-if limits (in 1/255 units) for reports; the shipped files use the defaults.
        let env = ProcessInfo.processInfo.environment
        let maxLimit = env["MIRA_PACK_MAX"].flatMap(Float.init).map { $0 / 255 } ?? PackedLUT.acceptedMaxError
        let p999Limit = env["MIRA_PACK_P999"].flatMap(Float.init).map { $0 / 255 } ?? PackedLUT.acceptedP999Error
        var total = 0
        var perDim: [Int: (count: Int, bytes: Int)] = [:]
        var worstMax: Float = 0, worstP999: Float = 0
        let todo = library.films.filter { $0.proceduralID == nil }
        for film in todo {
            guard let png = film.png else { throw PackError.noSource(film.id) }
            let (n, rgb) = try LUT.haldSamples(url: src.appendingPathComponent(png))
            let pick = PackedLUT.choose(rgb, dimension: n, maxError: maxLimit, p999Error: p999Limit)
            let data = try PackedLUT.pack(dimension: pick.dimension, rgb: pick.rgb)
            try data.write(to: dst.appendingPathComponent(film.file), options: .atomic)
            total += data.count
            perDim[pick.dimension, default: (0, 0)].count += 1
            perDim[pick.dimension, default: (0, 0)].bytes += data.count
            worstMax = max(worstMax, pick.fidelity.max); worstP999 = max(worstP999, pick.fidelity.p999)
        }
        print("dimension  films       MB")
        for d in perDim.keys.sorted() {
            let v = perDim[d]!
            print(String(format: "%5d^3  %6d  %7.1f", d, v.count, Double(v.bytes) / 1_048_576))
        }
        print(String(format: "Packed %d films, %d bytes (%.1f MB); worst chosen error max %.2f/255, p99.9 %.2f/255",
                     todo.count, total, Double(total) / 1_048_576, worstMax * 255, worstP999 * 255))
    }

    enum PackError: Error, CustomStringConvertible {
        case noSource(String)
        var description: String {
            switch self { case .noSource(let id): "\(id): films.json has no \"png\" source" }
        }
    }
}
