import CoreGraphics
import CoreImage
import CoreText
import MiraCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

// mira-sheet: renders a contact sheet of every film and prints sanity statistics.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mira-sheet: \(message)\n".utf8))
    exit(2)
}

struct Options {
    var films: String?
    var input: String?
    var output: String?
    var columns = 6
    var tile = 360
    var film: String?
    var recipeJSON: String?
    var limit: Int?
    var timeLUTs = false
}

func parseArguments() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func next(_ flag: String) -> String {
        guard !args.isEmpty else { fail("missing value for \(flag)") }
        return args.removeFirst()
    }
    func nextInt(_ flag: String) -> Int {
        guard let n = Int(next(flag)), n > 0 else { fail("\(flag) needs a positive integer") }
        return n
    }
    while !args.isEmpty {
        let flag = args.removeFirst()
        switch flag {
        case "--films": o.films = next(flag)
        case "--input": o.input = next(flag)
        case "--output": o.output = next(flag)
        case "--columns": o.columns = nextInt(flag)
        case "--tile": o.tile = nextInt(flag)
        case "--film": o.film = next(flag)
        case "--recipe-json": o.recipeJSON = next(flag)
        case "--limit": o.limit = nextInt(flag)
        case "--time-luts": o.timeLUTs = true
        default: fail("unknown argument \(flag)")
        }
    }
    return o
}

let opts = parseArguments()

/// `--time-luts`: loads every film LUT cold (empty cache, sequential and parallel) and warm.
func timeLUTs(filmsPath: String) -> Never {
    let dir = URL(fileURLWithPath: filmsPath, isDirectory: true)
    func fresh() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("mira-lut-time-\(UUID().uuidString)")
    }
    func time(_ label: String, _ body: () throws -> Void) rethrows {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        print(String(format: "%-40@ %8.0f ms", label as NSString, ms))
    }
    do {
        let seqCache = fresh(), parCache = fresh()
        let seq = try FilmLibrary(directory: dir, cacheDirectory: seqCache)
        try time("cold, sequential (\(seq.films.count) films)") { for f in seq.films { _ = try seq.lut(for: f) } }
        let par = try FilmLibrary(directory: dir, cacheDirectory: parCache)
        time("cold, prewarm concurrency 4") { par.prewarmSync(concurrency: 4) }
        let warm = try FilmLibrary(directory: dir, cacheDirectory: parCache)
        try time("warm, sequential") { for f in warm.films { _ = try warm.lut(for: f) } }
        let warm2 = try FilmLibrary(directory: dir, cacheDirectory: parCache)
        time("warm, prewarm concurrency 4") { warm2.prewarmSync(concurrency: 4) }
        try? FileManager.default.removeItem(at: seqCache)
        try? FileManager.default.removeItem(at: parCache)
        exit(0)
    } catch { fail("time-luts failed: \(error)") }
}
if opts.timeLUTs {
    guard let p = opts.films else { fail("--time-luts needs --films <dir>") }
    timeLUTs(filmsPath: p)
}

guard let filmsPath = opts.films, let inputPath = opts.input, let outputPath = opts.output else {
    fail("usage: mira-sheet --films <dir> --input <image> --output <png> [--columns 6] [--tile 360] [--film id] [--recipe-json '{...}'] [--limit N]")
}

let library: FilmLibrary
do { library = try FilmLibrary(directory: URL(fileURLWithPath: filmsPath, isDirectory: true)) }
catch { fail("cannot read films.json: \(error)") }

var base = Recipe()
if let json = opts.recipeJSON {
    do { base = try Recipe.decode(Data(json.utf8)) } catch { fail("bad --recipe-json: \(error)") }
}

guard let source = ImageSource.load(url: URL(fileURLWithPath: inputPath)) else {
    fail("cannot load \(inputPath)")
}

let renderer = Renderer(library: library)
let context = Renderer.makeContext()
let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

// Downsize and move the origin to (0, 0).
var small = renderer.previewImage(from: source, maxPixelSize: CGFloat(opts.tile))
small = small.transformed(by: CGAffineTransform(translationX: -small.extent.minX, y: -small.extent.minY))

var selected = library.films
if let id = opts.film {
    selected = selected.filter { $0.id == id }
    if selected.isEmpty { fail("no film with id \(id)") }
}
if let limit = opts.limit { selected = Array(selected.prefix(limit)) }

struct Stats { var luma: Double; var chroma: Double }

/// Mean Rec. 709 luma and mean |r-g|+|g-b| over sRGB-encoded 0...1 values.
@MainActor func stats(of image: CGImage) -> Stats {
    let w = image.width, h = image.height
    var data = [UInt8](repeating: 0, count: w * h * 4)
    data.withUnsafeMutableBytes { buf in
        let ctx = CGContext(
            data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var luma = 0.0, chroma = 0.0
    for i in stride(from: 0, to: data.count, by: 4) {
        let r = Double(data[i]) / 255, g = Double(data[i + 1]) / 255, b = Double(data[i + 2]) / 255
        luma += 0.2126 * r + 0.7152 * g + 0.0722 * b
        chroma += abs(r - g) + abs(g - b)
    }
    let n = Double(w * h)
    return Stats(luma: luma / n, chroma: chroma / n)
}

struct Tile { var label: String; var image: CGImage }

var tiles: [Tile] = []
var warnCount = 0

if let original = renderer.render(Recipe(), input: small, context: context, colorSpace: srgb) {
    tiles.append(Tile(label: "Original", image: original))
} else {
    fail("cannot render original")
}

print("id\tluma\tchroma")
for film in selected {
    var recipe = base
    recipe.filmID = film.id
    guard let cg = renderer.render(recipe, input: small, context: context, colorSpace: srgb) else {
        print("\(film.id)\tWARN render failed")
        warnCount += 1
        continue
    }
    let s = stats(of: cg)
    print(String(format: "%@\t%.4f\t%.4f", film.id, s.luma, s.chroma))
    var warnings: [String] = []
    if s.luma < 0.08 { warnings.append(String(format: "mean luma %.4f < 0.08 (too dark)", s.luma)) }
    if s.luma > 0.95 { warnings.append(String(format: "mean luma %.4f > 0.95 (blown out)", s.luma)) }
    if film.family == .blackAndWhite, s.chroma > 0.02 {
        warnings.append(String(format: "black & white film has chroma %.4f > 0.02", s.chroma))
    }
    if film.family != .blackAndWhite, s.chroma < 0.005 {
        warnings.append(String(format: "colour film has chroma %.4f < 0.005", s.chroma))
    }
    for w in warnings { print("WARN \(film.id): \(w)"); warnCount += 1 }
    tiles.append(Tile(label: "\(film.brand) \(film.displayName) · \(film.family.displayName)", image: cg))
}

// MARK: Compose

let columns = min(opts.columns, tiles.count)
let rows = (tiles.count + columns - 1) / columns
let pad = 16, labelH = 40
let cellW = opts.tile, cellH = opts.tile + labelH
let sheetW = pad + columns * (cellW + pad)
let sheetH = pad + rows * (cellH + pad)

guard let sheet = CGContext(
    data: nil, width: sheetW, height: sheetH, bitsPerComponent: 8, bytesPerRow: 0,
    space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fail("cannot create sheet context") }

sheet.setFillColor(CGColor(colorSpace: srgb, components: [0.09, 0.09, 0.10, 1])!)
sheet.fill(CGRect(x: 0, y: 0, width: sheetW, height: sheetH))

let font = CTFontCreateWithName("Helvetica Neue" as CFString, 15, nil)
let textColor = CGColor(colorSpace: srgb, components: [1, 1, 1, 1])!

@MainActor func drawLabel(_ text: String, centeredIn rect: CGRect) {
    let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: textColor]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs as [NSAttributedString.Key: Any]))
    var width = CTLineGetTypographicBounds(line, nil, nil, nil)
    var drawLine = line
    if width > rect.width, let truncated = CTLineCreateTruncatedLine(line, rect.width, .end, nil) {
        drawLine = truncated
        width = CTLineGetTypographicBounds(truncated, nil, nil, nil)
    }
    sheet.textPosition = CGPoint(x: rect.minX + (rect.width - width) / 2, y: rect.midY - 5)
    CTLineDraw(drawLine, sheet)
}

for (i, tile) in tiles.enumerated() {
    let col = i % columns, row = i / columns
    let x = pad + col * (cellW + pad)
    let topY = pad + row * (cellH + pad)         // from the top of the sheet
    let cellBottom = sheetH - topY - cellH       // CG origin is bottom-left
    let iw = CGFloat(tile.image.width), ih = CGFloat(tile.image.height)
    let k = min(CGFloat(cellW) / iw, CGFloat(opts.tile) / ih)
    let dw = iw * k, dh = ih * k
    let imageRect = CGRect(
        x: CGFloat(x) + (CGFloat(cellW) - dw) / 2,
        y: CGFloat(cellBottom + labelH),
        width: dw, height: dh)
    sheet.interpolationQuality = .high
    sheet.draw(tile.image, in: imageRect)
    drawLabel(tile.label, centeredIn: CGRect(x: x, y: cellBottom, width: cellW, height: labelH))
}

guard let sheetImage = sheet.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outputPath) as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fail("cannot create output \(outputPath)") }
CGImageDestinationAddImage(dest, sheetImage, nil)
guard CGImageDestinationFinalize(dest) else { fail("cannot write \(outputPath)") }

print("Wrote \(outputPath) (\(sheetW)x\(sheetH), \(tiles.count) tiles)")
print("Summary: \(selected.count) films, \(warnCount) warning(s)")
