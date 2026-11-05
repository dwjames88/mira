import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One column of a contact sheet: a named variation of the film look (everything else neutral).
public enum ContactSheetState: String, CaseIterable, Sendable {
    case original, film, grain, halation
    case halationMax = "halation-max"
    case pushFrontier = "push-frontier"
    case paperCinema = "paper-cinema"
    case paperColor = "paper-color"
    case toningSelenium = "toning-selenium"

    public static let defaults: [ContactSheetState] = [.film, .grain, .halation, .pushFrontier]
    public static let defaultFilmIDs = [
        "kodak-portra-400", "kodak-ektar-100", "fuji-velvia-50",
        "kodak-kodachrome-64", "kodak-tri-x-400", "polaroid-px-680",
    ]

    public var usesFilm: Bool { self != .original }

    /// The recipe for this state on `filmID` (pipeline 2, all else neutral).
    public func recipe(filmID: String) -> Recipe {
        var r = Recipe(filmID: usesFilm ? filmID : nil)
        switch self {
        case .original, .film: break
        case .grain: r.grainAmount = 0.5
        case .halation: r.halationAmount = 0.5
        case .halationMax: r.halationAmount = 1.0; r.halationRadius = 0.5
        case .pushFrontier: r.push = 1; r.scanProfile = .frontier
        case .paperCinema: r.paper = .cinemaPrint
        case .paperColor: r.paper = .colorPaper
        case .toningSelenium: r.toning = .selenium
        }
        return r
    }
}

/// Pure geometry of a tile grid (films x states); testable without rendering.
public struct ContactSheetLayout: Equatable, Sendable {
    public var columns: Int
    public var rows: Int
    public var tileWidth: Int
    public var tileHeight: Int
    public var pad = 12
    public var labelHeight = 22

    public init(columns: Int, rows: Int, tileWidth: Int, tileHeight: Int) {
        self.columns = columns; self.rows = rows; self.tileWidth = tileWidth; self.tileHeight = tileHeight
    }

    /// Tile height for a source of the given aspect at `width`.
    public static func tileHeight(width: Int, sourceSize: CGSize) -> Int {
        max(1, Int((Double(width) * Double(sourceSize.height) / Double(max(sourceSize.width, 1))).rounded()))
    }

    public var cellHeight: Int { tileHeight + labelHeight }
    public var sheetWidth: Int { pad + columns * (tileWidth + pad) }
    public var sheetHeight: Int { pad + rows * (cellHeight + pad) }
    public func origin(column: Int, row: Int) -> (x: Int, topY: Int) {
        (pad + column * (tileWidth + pad), pad + row * (cellHeight + pad))
    }
}

/// Reports for a contact-sheet run.
public struct ContactSheetResult: Sendable {
    public var films: [String]
    public var states: [ContactSheetState]
    public var files: [URL]
    public var gridSize: (width: Int, height: Int)
    public var timings: [(String, Double)]
}

public enum ContactSheet {
    public struct Config {
        public var films: [String]
        public var states: [ContactSheetState]
        public var tileWidth: Int
        public var cropOnly: Bool
        public var cropSize: Int
        public var outDir: URL
        /// Exposure time in seconds and reciprocity mode for every tile (nil: the source's EXIF time, compensated).
        public var exposureTime: Double?
        public var reciprocity: ReciprocityMode?
        public init(films: [String] = ContactSheetState.defaultFilmIDs, states: [ContactSheetState] = ContactSheetState.defaults,
                    tileWidth: Int = 900, cropOnly: Bool = false, cropSize: Int = 300, outDir: URL,
                    exposureTime: Double? = nil, reciprocity: ReciprocityMode? = nil) {
            self.exposureTime = exposureTime; self.reciprocity = reciprocity
            self.films = films; self.states = states; self.tileWidth = tileWidth
            self.cropOnly = cropOnly; self.cropSize = cropSize; self.outDir = outDir
        }
    }

    public enum SheetError: Error { case renderFailed(String), noFilms, writeFailed(URL) }

    static let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    static let cropStates: [ContactSheetState] = [.grain, .halation, .halationMax]

    /// Renders the sheets. `source` supplies the developed source for a recipe (RAW needs a different
    /// decode with a film than without); it is called once per film/state and should cache.
    public static func run(
        config: Config, library: FilmLibrary, context: CIContext = Renderer.sharedContext,
        warn: (String) -> Void = { _ in }, source: (Recipe) -> CIImage?
    ) throws -> ContactSheetResult {
        let renderer = Renderer(library: library)
        let known = Set(library.films.map(\.id))
        var films: [String] = []
        for id in config.films {
            if known.contains(id) { films.append(id) } else { warn("unknown film id \(id), skipped") }
        }
        guard !films.isEmpty else { throw SheetError.noFilms }
        try FileManager.default.createDirectory(at: config.outDir, withIntermediateDirectories: true)

        var timings: [(String, Double)] = []
        var files: [URL] = []
        let t0 = DispatchTime.now().uptimeNanoseconds
        func ms(_ since: UInt64) -> Double { Double(DispatchTime.now().uptimeNanoseconds - since) / 1e6 }

        guard let probe = source(config.states.first?.recipe(filmID: films[0]) ?? Recipe()) else { throw SheetError.renderFailed("source") }
        let size = probe.extent.size
        let layout = ContactSheetLayout(columns: config.states.count, rows: films.count, tileWidth: config.tileWidth,
                                        tileHeight: ContactSheetLayout.tileHeight(width: config.tileWidth, sourceSize: size))

        // Crop windows come from the neutral source so every film is judged on the same pixels.
        let windows: [CGRect]? = cropWindows(for: probe, context: context, size: config.cropSize)

        var rowCells: [[(String, CGImage)]] = []
        var cropRows: [[CGImage]] = []
        let renderStates = config.cropOnly ? cropStates : Array(Set(config.states).union(cropStates))
        for id in films {
            let tf = DispatchTime.now().uptimeNanoseconds
            let film = library.films.first { $0.id == id }
            let name = film.map { "\($0.brand) \($0.displayName)" } ?? id
            var tiles: [ContactSheetState: CGImage] = [:]
            var crops: [CGImage] = []
            var cropByState: [ContactSheetState: [CGImage]] = [:]
            for state in ContactSheetState.allCases where renderStates.contains(state) {
                var recipe = state.recipe(filmID: id)
                if let t = config.exposureTime { recipe.exposureTime = t }
                if let m = config.reciprocity { recipe.reciprocity = m }
                guard let src = source(recipe) else { throw SheetError.renderFailed("\(id)/\(state.rawValue) source") }
                let out = renderer.apply(recipe, to: src)
                guard let full = context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: srgb)
                else { throw SheetError.renderFailed("\(id)/\(state.rawValue)") }
                if !config.cropOnly && config.states.contains(state) {
                    tiles[state] = try downscale(full, toWidth: layout.tileWidth, height: layout.tileHeight, context: context)
                }
                if Self.cropStates.contains(state), let windows {
                    cropByState[state] = windows.enumerated().compactMap { (wi, w) in
                        let r = CGRect(x: w.minX, y: w.minY, width: w.width, height: w.height)
                            .intersection(CGRect(x: 0, y: 0, width: full.width, height: full.height))
                        return full.cropping(to: r).map {
                            labeled($0, text: "\(name) · \(state.rawValue) · \(wi == 0 ? "highlights" : "midtones") 1:1", labelHeight: 22)
                        }
                    }
                }
            }
            // Order: highlight (grain, halation, halation-max), then midtone (same).
            let present = Self.cropStates.filter { cropByState[$0] != nil && (config.cropOnly || $0 != .halationMax || config.states.contains($0)) }
            for wi in 0..<(windows?.count ?? 0) { for st in present { if let c = cropByState[st], wi < c.count { crops.append(c[wi]) } } }
            cropRows.append(crops)

            if !config.cropOnly {
                let cells = config.states.compactMap { s in tiles[s].map { (s, $0) } }
                let labeled = cells.map { ("\(name) · \($0.0.rawValue)", $0.1) }
                rowCells.append(labeled)
                let one = ContactSheetLayout(columns: labeled.count, rows: 1, tileWidth: layout.tileWidth, tileHeight: layout.tileHeight)
                let url = config.outDir.appendingPathComponent("\(id).png")
                try writePNG(compose(layout: one, rows: [labeled]), to: url); files.append(url)
            }
            timings.append((id, ms(tf)))
        }

        if !config.cropOnly {
            let grid = compose(layout: layout, rows: rowCells)
            let url = config.outDir.appendingPathComponent("contact-sheet.png")
            try writePNG(grid, to: url); files.append(url)
        }
        let flat = cropRows.filter { !$0.isEmpty }
        if !flat.isEmpty {
            let url = config.outDir.appendingPathComponent("crops.png")
            try writePNG(cropGrid(flat), to: url); files.append(url)
        }
        timings.append(("total", ms(t0)))
        return ContactSheetResult(films: films, states: config.states, files: files,
                                  gridSize: (layout.sheetWidth, layout.sheetHeight), timings: timings)
    }

    // MARK: Crop windows

    /// Top-left-origin windows (highlight-rich, midtone) found on a coarse luma map of `image`.
    static func cropWindows(for image: CIImage, context: CIContext, size: Int) -> [CGRect] {
        let e = image.extent
        let w = Int(e.width), h = Int(e.height)
        let side = min(size, w, h)
        let f = max(1, side / 40)    // analysis cell = f source pixels
        let gw = max(1, w / f), gh = max(1, h / f)
        let small = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(gw) / CGFloat(w), y: CGFloat(gh) / CGFloat(h)))
        guard let cg = context.createCGImage(small, from: CGRect(x: 0, y: 0, width: gw, height: gh), format: .RGBA8, colorSpace: srgb)
        else { return [CGRect(x: 0, y: 0, width: side, height: side)] }
        var px = [UInt8](repeating: 0, count: gw * gh * 4)
        px.withUnsafeMutableBytes { b in
            let c = CGContext(data: b.baseAddress, width: gw, height: gh, bitsPerComponent: 8, bytesPerRow: gw * 4,
                              space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(cg, in: CGRect(x: 0, y: 0, width: gw, height: gh))
        }
        // Rows in `px` are top-first when drawn this way into a bottom-left context? CGContext data is top row first.
        var luma = [Double](repeating: 0, count: gw * gh)
        for i in 0..<(gw * gh) {
            luma[i] = (0.2126 * Double(px[i * 4]) + 0.7152 * Double(px[i * 4 + 1]) + 0.0722 * Double(px[i * 4 + 2])) / 255
        }
        let cw = max(1, min(gw, side / f)), ch = max(1, min(gh, side / f))
        // Integral images of "linear luma > 0.9" and of luma, so any window is O(1).
        let iw = gw + 1
        var hiI = [Int32](repeating: 0, count: iw * (gh + 1)), lumI = [Double](repeating: 0, count: iw * (gh + 1))
        for y in 0..<gh { for x in 0..<gw {
            let v = luma[y * gw + x]
            let lin = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            let i = (y + 1) * iw + x + 1
            hiI[i] = hiI[i - 1] + hiI[i - iw] - hiI[i - iw - 1] + (lin > 0.9 ? 1 : 0)
            lumI[i] = lumI[i - 1] + lumI[i - iw] - lumI[i - iw - 1] + v
        } }
        func box<T: AdditiveArithmetic>(_ a: [T], _ x: Int, _ y: Int) -> T {
            a[(y + ch) * iw + x + cw] - a[y * iw + x + cw] - a[(y + ch) * iw + x] + a[y * iw + x]
        }
        var bestHi = (hi: Int32(-1), mean: Double.infinity, x: 0, y: 0), bestMid = (score: Double.infinity, x: 0, y: 0)
        let step = max(1, cw / 8)
        for y in stride(from: 0, through: gh - ch, by: step) {
            for x in stride(from: 0, through: gw - cw, by: step) {
                let n = Double(cw * ch)
                let hi = box(hiI, x, y), mean = box(lumI, x, y) / n
                // Highlight window: centre inside the central 60% of the frame.
                let cx = Double(x + cw / 2) / Double(gw), cy = Double(y + ch / 2) / Double(gh)
                if (0.2...0.8).contains(cx) && (0.2...0.8).contains(cy),
                   hi > bestHi.hi || (hi == bestHi.hi && mean < bestHi.mean) { bestHi = (hi, mean, x, y) }
                let midScore = abs(mean - 0.45)
                if midScore < bestMid.score { bestMid = (midScore, x, y) }
            }
        }
        // Re-centre the highlight window on the centroid of its bright pixels.
        do {
            var sx = 0.0, sy = 0.0, n = 0.0
            for y in bestHi.y..<(bestHi.y + ch) { for x in bestHi.x..<(bestHi.x + cw) {
                let i = (y + 1) * iw + x + 1
                if hiI[i] - hiI[i - 1] - hiI[i - iw] + hiI[i - iw - 1] > 0 { sx += Double(x); sy += Double(y); n += 1 }
            } }
            if n > 0 {
                bestHi.x = min(max(0, Int(sx / n) - cw / 2), gw - cw)
                bestHi.y = min(max(0, Int(sy / n) - ch / 2), gh - ch)
            }
        }
        func rect(_ p: (x: Int, y: Int)) -> CGRect {
            CGRect(x: min(p.x * f, w - side), y: min(p.y * f, h - side), width: side, height: side)
        }
        return [rect((bestHi.x, bestHi.y)), rect((bestMid.x, bestMid.y))]
    }

    // MARK: Drawing

    static func downscale(_ image: CGImage, toWidth w: Int, height h: Int, context: CIContext) throws -> CGImage {
        let ci = CIImage(cgImage: image)
        if image.width == w && image.height == h { return image }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = ci
        f.scale = Float(Double(h) / Double(image.height))
        f.aspectRatio = Float((Double(w) / Double(image.width)) / (Double(h) / Double(image.height)))
        guard let out = f.outputImage,
              let cg = context.createCGImage(out, from: CGRect(x: 0, y: 0, width: w, height: h), format: .RGBA8, colorSpace: srgb)
        else { throw SheetError.renderFailed("downscale") }
        return cg
    }

    static func newContext(_ w: Int, _ h: Int) -> CGContext {
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(CGColor(colorSpace: srgb, components: [0.09, 0.09, 0.10, 1])!)
        c.fill(CGRect(x: 0, y: 0, width: w, height: h))
        return c
    }

    static func drawText(_ text: String, in rect: CGRect, ctx: CGContext) {
        let font = CTFontCreateWithName("Helvetica Neue" as CFString, 13, nil)
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(colorSpace: srgb, components: [0.92, 0.92, 0.92, 1])!,
        ]
        var line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        if CTLineGetTypographicBounds(line, nil, nil, nil) > rect.width,
           let t = CTLineCreateTruncatedLine(line, rect.width, .end, nil) { line = t }
        ctx.textPosition = CGPoint(x: rect.minX, y: rect.minY + 6)
        CTLineDraw(line, ctx)
    }

    /// Rows of labelled tiles on one sheet.
    static func compose(layout l: ContactSheetLayout, rows: [[(String, CGImage)]]) -> CGImage {
        let c = newContext(l.sheetWidth, l.sheetHeight)
        c.interpolationQuality = .high
        for (r, cells) in rows.enumerated() {
            for (i, cell) in cells.enumerated() {
                let o = l.origin(column: i, row: r)
                let bottom = l.sheetHeight - o.topY - l.cellHeight
                c.draw(cell.1, in: CGRect(x: o.x, y: bottom + l.labelHeight, width: l.tileWidth, height: l.tileHeight))
                drawText(cell.0, in: CGRect(x: o.x, y: bottom, width: l.tileWidth, height: l.labelHeight), ctx: c)
            }
        }
        return c.makeImage()!
    }

    static func labeled(_ image: CGImage, text: String, labelHeight: Int) -> CGImage {
        let c = newContext(image.width, image.height + labelHeight)
        c.draw(image, in: CGRect(x: 0, y: labelHeight, width: image.width, height: image.height))
        drawText(text, in: CGRect(x: 4, y: 0, width: image.width - 8, height: labelHeight), ctx: c)
        return c.makeImage()!
    }

    /// Rows of 1:1 crops, four per row.
    static func cropGrid(_ rows: [[CGImage]]) -> CGImage {
        let pad = 8
        let cols = rows.map(\.count).max() ?? 1
        let cw = rows.flatMap { $0 }.map(\.width).max() ?? 1
        let ch = rows.flatMap { $0 }.map(\.height).max() ?? 1
        let w = pad + cols * (cw + pad), h = pad + rows.count * (ch + pad)
        let c = newContext(w, h)
        for (r, row) in rows.enumerated() {
            for (i, img) in row.enumerated() {
                c.draw(img, in: CGRect(x: pad + i * (cw + pad), y: h - pad - (r + 1) * (ch + pad) + pad,
                                       width: img.width, height: img.height))
            }
        }
        return c.makeImage()!
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw SheetError.writeFailed(url) }
        CGImageDestinationAddImage(d, image, nil)
        guard CGImageDestinationFinalize(d) else { throw SheetError.writeFailed(url) }
    }
}
