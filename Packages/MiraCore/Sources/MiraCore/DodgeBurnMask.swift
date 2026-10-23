import CoreGraphics
import CoreImage
import Foundation

// MARK: Geometry

/// How strokes (normalised to the uncropped, upright source) land in a mask bitmap.
///
/// The bitmap covers `region` of the image being graded (Core Image pixels, origin bottom left) at
/// `scale` bitmap pixels per graded pixel; row 0 is the top. Points go source -> crop output with
/// `CropGeometry.transform` (the same forward transform `CropGeometry.apply` uses), then to the
/// size of the graded image (a preview is smaller than the full-resolution output), then into the
/// bitmap. Rotation, flips and straighten only turn and uniformly scale, so a round brush stays round.
struct DodgeBurnGeometry: Hashable, Sendable {
    let crop: CropSettings
    let sourceSize: CGSize
    let gradedSize: CGSize
    let region: CGRect
    let scale: Double
    let width: Int
    let height: Int

    private let transform: CGAffineTransform
    private let gx: CGFloat
    private let gy: CGFloat
    /// Bitmap pixels per unit of `size` (a fraction of the source's short side).
    let pixelsPerSize: Double

    /// A geometry for the whole graded image, or `region` of it, at `scale`.
    init(crop: CropSettings, sourceSize: CGSize, gradedSize: CGSize, region: CGRect? = nil, scale: Double = 1) {
        self.crop = crop
        self.sourceSize = sourceSize
        self.gradedSize = gradedSize
        let whole = CGRect(origin: .zero, size: gradedSize)
        let r = (region ?? whole).intersection(whole)
        self.region = r.isNull || r.isEmpty ? whole : r
        self.scale = scale
        width = max(1, Int((self.region.width * scale).rounded()))
        height = max(1, Int((self.region.height * scale).rounded()))
        let extent = CGRect(origin: .zero, size: sourceSize)
        transform = CropGeometry.transform(for: crop, imageExtent: extent)
        let out = CropGeometry.outputExtent(for: crop, imageExtent: extent).size
        gx = out.width > 0 ? gradedSize.width / out.width : 1
        gy = out.height > 0 ? gradedSize.height / out.height : 1
        pixelsPerSize = Double(min(sourceSize.width, sourceSize.height) * hypot(transform.a, transform.b) * gx) * scale
    }

    var pixelCount: Int { width * height }

    /// A stroke point in bitmap pixels (y down).
    func map(_ p: StrokePoint) -> CGPoint {
        let s = CGPoint(x: p.x * sourceSize.width, y: (1 - p.y) * sourceSize.height).applying(transform)
        return CGPoint(x: (s.x * gx - region.minX) * scale, y: (region.maxY - s.y * gy) * scale)
    }

    /// Brush radius in bitmap pixels.
    func radius(size: Double) -> Double { max(0.5, size * pixelsPerSize / 2) }
}

// MARK: Layers

/// Strokes that share these settings share one mask and one kernel pass.
struct DodgeBurnLayerKey: Hashable, Sendable {
    var dodge: Bool
    var range: DodgeBurnRange
    var protect: Bool
    /// Luminosity limits in thousandths (low, high, softness), nil when unlimited.
    var luma: [Int]?

    init(_ s: DodgeBurnStroke) {
        dodge = s.mode == .dodge
        range = s.range
        protect = s.protectTones
        if let l = s.lumaRange?.clamped, !l.isFull {
            luma = [Int((l.low * 1000).rounded()), Int((l.high * 1000).rounded()), Int((l.softness * 1000).rounded())]
        } else {
            luma = nil
        }
    }
}

/// One mask: values 0...1, row 0 at the top, already multiplied by stroke strengths.
final class DodgeBurnLayerBuffer: @unchecked Sendable {
    var values: [Float]
    /// The mask as a Core Image image placed over the graded image; built once per published state.
    var image: CIImage?

    init(count: Int) { values = [Float](repeating: 0, count: count) }
    init(copying other: DodgeBurnLayerBuffer) { values = other.values }
}

struct DodgeBurnState {
    var order: [DodgeBurnLayerKey] = []
    var buffers: [DodgeBurnLayerKey: DodgeBurnLayerBuffer] = [:]
    /// Buffers this state may write to without copying (transient, empty in published states).
    var owned: Set<DodgeBurnLayerKey> = []

    mutating func freeze() { owned = [] }

    mutating func writable(_ key: DodgeBurnLayerKey, count: Int) -> DodgeBurnLayerBuffer {
        if let b = buffers[key] {
            if owned.contains(key) { b.image = nil; return b }
            let copy = DodgeBurnLayerBuffer(copying: b)
            buffers[key] = copy
            owned.insert(key)
            return copy
        }
        let b = DodgeBurnLayerBuffer(count: count)
        buffers[key] = b
        order.append(key)
        owned.insert(key)
        return b
    }
}

// MARK: Coverage (dab stamping)

struct DodgeBurnRect: Equatable {
    var x0: Int, y0: Int, x1: Int, y1: Int   // half open
    var isEmpty: Bool { x1 <= x0 || y1 <= y0 }
    var width: Int { max(0, x1 - x0) }
    var height: Int { max(0, y1 - y0) }

    func intersection(_ o: DodgeBurnRect) -> DodgeBurnRect {
        DodgeBurnRect(x0: max(x0, o.x0), y0: max(y0, o.y0), x1: min(x1, o.x1), y1: min(y1, o.y1))
    }

    func union(_ o: DodgeBurnRect) -> DodgeBurnRect {
        if isEmpty { return o }
        if o.isEmpty { return self }
        return DodgeBurnRect(x0: min(x0, o.x0), y0: min(y0, o.y0), x1: max(x1, o.x1), y1: max(y1, o.y1))
    }
}

/// Stamps round dabs along a stroke into a coverage buffer. Feed it points; it emits dabs every
/// `0.15 * diameter` along the path (alpha `flow * pressure`, radial falloff by feather) and
/// accumulates `cov = cov + a (1 - cov)`. Feeding the same points in one go or in pieces gives the
/// same result, which is what makes a stroke in progress cheap to extend.
struct DodgeBurnCoverage {
    let bounds: DodgeBurnRect     // the area the buffer covers, in bitmap pixels
    var values: [Float]
    private(set) var dirty = DodgeBurnRect(x0: 0, y0: 0, x1: 0, y1: 0)

    private let radius: Double
    private let spacing: Double
    private let flow: Float
    private let lut: [Float]
    private let lutScale: Float
    private var previous: (point: CGPoint, pressure: Double)?
    private var carry = 0.0

    static let lutSize = 1024

    init(bounds: DodgeBurnRect, radius: Double, feather: Double, flow: Double) {
        self.bounds = bounds
        values = [Float](repeating: 0, count: max(0, bounds.width * bounds.height))
        self.radius = radius
        spacing = max(0.7, 2 * radius * 0.15)
        self.flow = Float(min(max(flow, 0), 1))
        // alpha as a function of d^2 / (r + 0.5)^2: flat core, smoothstep falloff to the rim, and a
        // one pixel antialiased edge for a hard brush.
        let reach = radius + 0.5
        let inner = 1 - min(max(feather, 0), 1)
        var table = [Float](repeating: 0, count: Self.lutSize + 1)
        for i in 0...Self.lutSize {
            let d = (Double(i) / Double(Self.lutSize)).squareRoot() * reach
            let u = d / radius
            var a = 1.0
            if u > inner {
                let t = inner >= 1 ? 1 : min(max((u - inner) / (1 - inner), 0), 1)
                a = 1 - t * t * (3 - 2 * t)
            }
            a *= min(max(radius + 0.5 - d, 0), 1)
            table[i] = Float(a)
        }
        lut = table
        lutScale = Float(Double(Self.lutSize) / (reach * reach))
    }

    /// Adds the dabs for the next path point.
    mutating func feed(_ point: CGPoint, pressure: Double) {
        guard point.x.isFinite, point.y.isFinite else { return }
        guard let prev = previous else {
            stamp(at: point, pressure: pressure)
            previous = (point, pressure)
            return
        }
        let dx = Double(point.x - prev.point.x), dy = Double(point.y - prev.point.y)
        let length = (dx * dx + dy * dy).squareRoot()
        var position = spacing - carry
        while position <= length {
            let t = position / length
            stamp(at: CGPoint(x: prev.point.x + CGFloat(dx * t), y: prev.point.y + CGFloat(dy * t)),
                  pressure: prev.pressure + (pressure - prev.pressure) * t)
            position += spacing
        }
        carry = length - (position - spacing)
        previous = (point, pressure)
    }

    private mutating func stamp(at c: CGPoint, pressure: Double) {
        let alpha = flow * Float(min(max(pressure, 0), 1))
        guard alpha > 0 else { return }
        let reach = radius + 0.5
        let box = DodgeBurnRect(x0: Int((Double(c.x) - reach).rounded(.down)), y0: Int((Double(c.y) - reach).rounded(.down)),
                                x1: Int((Double(c.x) + reach).rounded(.up)) + 1, y1: Int((Double(c.y) + reach).rounded(.up)) + 1)
            .intersection(bounds)
        guard !box.isEmpty else { return }
        dirty = dirty.union(box)
        let stride = bounds.width
        let cx = Float(c.x), cy = Float(c.y)
        let scale = lutScale, last = Float(Self.lutSize)
        values.withUnsafeMutableBufferPointer { buffer in
            lut.withUnsafeBufferPointer { table in
                for y in box.y0..<box.y1 {
                    let dy = Float(y) + 0.5 - cy
                    let dy2 = dy * dy
                    let row = (y - bounds.y0) * stride - bounds.x0
                    for x in box.x0..<box.x1 {
                        let dx = Float(x) + 0.5 - cx
                        let t = (dx * dx + dy2) * scale
                        if t >= last { continue }
                        let a = table[Int(t)] * alpha
                        if a <= 0 { continue }
                        let v = buffer[row + x]
                        buffer[row + x] = v + a - v * a
                    }
                }
            }
        }
    }
}

// MARK: Compositing and rasterising

enum DodgeBurnRaster {
    /// The bitmap area a stroke can touch, or nil when it is entirely outside.
    static func bounds(of stroke: DodgeBurnStroke, geometry: DodgeBurnGeometry) -> DodgeBurnRect? {
        guard !stroke.points.isEmpty else { return nil }
        let r = geometry.radius(size: stroke.size) + 2
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for p in stroke.points {
            let q = geometry.map(p)
            guard q.x.isFinite, q.y.isFinite else { continue }
            minX = min(minX, Double(q.x)); maxX = max(maxX, Double(q.x))
            minY = min(minY, Double(q.y)); maxY = max(maxY, Double(q.y))
        }
        guard minX.isFinite else { return nil }
        let full = DodgeBurnRect(x0: 0, y0: 0, x1: geometry.width, y1: geometry.height)
        let box = DodgeBurnRect(x0: Int((minX - r).rounded(.down)), y0: Int((minY - r).rounded(.down)),
                                x1: Int((maxX + r).rounded(.up)) + 1, y1: Int((maxY + r).rounded(.up)) + 1)
            .intersection(full)
        return box.isEmpty ? nil : box
    }

    /// A coverage buffer for `stroke`, over `bounds`, with every point fed.
    static func coverage(of stroke: DodgeBurnStroke, geometry: DodgeBurnGeometry, bounds: DodgeBurnRect) -> DodgeBurnCoverage {
        var cov = DodgeBurnCoverage(bounds: bounds, radius: geometry.radius(size: stroke.size),
                                    feather: stroke.feather, flow: stroke.flow)
        for p in stroke.points { cov.feed(geometry.map(p), pressure: p.pressure) }
        return cov
    }

    /// Writes `coverage` (limited to `area`) into `state`: dodge and burn add `cov * strength` over
    /// what is there, erase takes `cov` away from every layer.
    static func composite(_ cov: DodgeBurnCoverage, area: DodgeBurnRect, stroke: DodgeBurnStroke,
                          into state: inout DodgeBurnState, geometry: DodgeBurnGeometry) {
        let area = area.intersection(cov.bounds)
        guard !area.isEmpty else { return }
        let count = geometry.pixelCount
        let stride = geometry.width
        let keys: [DodgeBurnLayerKey]
        let erase = stroke.mode == .erase
        if erase { keys = state.order } else { keys = [DodgeBurnLayerKey(stroke)] }
        let strength = erase ? Float(1) : Float(min(max(stroke.strength, 0), 1))
        for key in keys {
            let layer = state.writable(key, count: count)
            cov.values.withUnsafeBufferPointer { src in
                layer.values.withUnsafeMutableBufferPointer { dst in
                    for y in area.y0..<area.y1 {
                        let s = (y - cov.bounds.y0) * cov.bounds.width - cov.bounds.x0
                        let d = y * stride
                        for x in area.x0..<area.x1 {
                            let c = src[s + x] * strength
                            if c <= 0 { continue }
                            let m = dst[d + x]
                            dst[d + x] = erase ? m * (1 - c) : m + c - m * c
                        }
                    }
                }
            }
        }
    }

    /// Rasterises `strokes` (already filtered to the active ones) from scratch.
    static func rasterize(_ strokes: [DodgeBurnStroke], geometry: DodgeBurnGeometry) -> DodgeBurnState {
        var state = DodgeBurnState()
        for stroke in strokes {
            guard let box = bounds(of: stroke, geometry: geometry) else { continue }
            let cov = coverage(of: stroke, geometry: geometry, bounds: box)
            composite(cov, area: cov.dirty, stroke: stroke, into: &state, geometry: geometry)
        }
        return state
    }

    /// The mask as a Core Image image over the graded image (`geometry.region` in graded pixels).
    static func image(for buffer: DodgeBurnLayerBuffer, geometry: DodgeBurnGeometry) -> CIImage {
        if let image = buffer.image { return image }
        let data = buffer.values.withUnsafeBufferPointer { Data(buffer: $0) }
        let raw = CIImage(bitmapData: data, bytesPerRow: geometry.width * 4,
                          size: CGSize(width: geometry.width, height: geometry.height),
                          format: .Rf, colorSpace: nil)
        let region = geometry.region
        let sx = region.width / CGFloat(geometry.width), sy = region.height / CGFloat(geometry.height)
        var image: CIImage
        if abs(sx - 1) < 1e-6, abs(sy - 1) < 1e-6 {
            image = raw.transformed(by: CGAffineTransform(translationX: region.minX, y: region.minY))
        } else {
            image = raw.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: sx, y: sy).translatedBy(x: region.minX / sx, y: region.minY / sy))
                .cropped(to: region)
        }
        buffer.image = image
        return image
    }
}

// MARK: Cache

/// One mask ready to be applied: the kernel settings of its strokes and the mask image.
struct DodgeBurnLayer {
    let key: DodgeBurnLayerKey
    let image: CIImage
}

/// Keeps the rasterised masks between renders. Entries are keyed by geometry (crop, source and
/// output sizes, region); within an entry the committed strokes' state is kept, plus a checkpoint
/// one stroke back and the live stroke's coverage, so a stroke in progress only stamps the new dabs
/// and a finished stroke only the one stroke on top of the cached ones.
final class DodgeBurnMaskCache: @unchecked Sendable {
    private final class Entry {
        let geometry: DodgeBurnGeometry
        var strokes: [DodgeBurnStroke] = []
        var state = DodgeBurnState()
        var checkpointStrokes: [DodgeBurnStroke]?
        var checkpoint = DodgeBurnState()
        var live: Live?
        init(geometry: DodgeBurnGeometry) { self.geometry = geometry }
    }

    private struct Live {
        var stroke: DodgeBurnStroke   // the stroke as last seen
        var coverage: DodgeBurnCoverage
        var fed: Int
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private let limit = 2
    /// Masks bigger than this many pixels are built for one render and not kept.
    static let keepLimit = 4_000_000

    /// Stamping counters (tests, benchmarks).
    private(set) var rebuilds = 0
    private(set) var incremental = 0
    private(set) var hits = 0

    func layers(for strokes: [DodgeBurnStroke], geometry: DodgeBurnGeometry) -> [DodgeBurnLayer] {
        lock.lock()
        defer { lock.unlock() }
        let keep = geometry.pixelCount <= Self.keepLimit
        let entry: Entry
        if let i = entries.firstIndex(where: { $0.geometry == geometry }) {
            entry = entries.remove(at: i)
            entries.append(entry)
        } else {
            entry = Entry(geometry: geometry)
            if keep {
                entries.append(entry)
                while entries.count > limit { entries.removeFirst() }
            }
        }
        if entry.strokes == strokes {
            hits += 1
        } else {
            update(entry, to: strokes)
        }
        return entry.state.order.compactMap { key in
            entry.state.buffers[key].map { DodgeBurnLayer(key: key, image: DodgeBurnRaster.image(for: $0, geometry: geometry)) }
        }
    }

    /// The cached state for `geometry` (tests).
    func stateForTesting(geometry: DodgeBurnGeometry) -> DodgeBurnState? {
        lock.lock(); defer { lock.unlock() }
        return entries.first { $0.geometry == geometry }?.state
    }

    func removeAll() {
        lock.lock(); entries = []; lock.unlock()
    }

    private func update(_ entry: Entry, to strokes: [DodgeBurnStroke]) {
        let geometry = entry.geometry
        let n = strokes.count
        guard n > 0 else {
            entry.strokes = []; entry.state = DodgeBurnState(); entry.checkpointStrokes = nil; entry.live = nil
            return
        }
        var state: DodgeBurnState
        var from: Int
        var haveCheckpoint = false
        if let cps = entry.checkpointStrokes, cps.count == n - 1, cps == Array(strokes.dropLast()) {
            state = entry.checkpoint
            from = n - 1
            haveCheckpoint = true
            incremental += 1
        } else if entry.strokes.count < n, Array(strokes.prefix(entry.strokes.count)) == entry.strokes {
            state = entry.state
            from = entry.strokes.count
            entry.live = nil
            incremental += 1
        } else {
            state = DodgeBurnState()
            from = 0
            entry.live = nil
            rebuilds += 1
        }
        state.freeze()
        for i in from..<n {
            let stroke = strokes[i]
            if i < n - 1 {
                guard let box = DodgeBurnRaster.bounds(of: stroke, geometry: geometry) else { continue }
                let cov = DodgeBurnRaster.coverage(of: stroke, geometry: geometry, bounds: box)
                DodgeBurnRaster.composite(cov, area: cov.dirty, stroke: stroke, into: &state, geometry: geometry)
                continue
            }
            // The last stroke is the one that may still grow: keep the state just before it, and
            // keep its coverage so the next frame only adds the new dabs.
            if !haveCheckpoint {
                entry.checkpointStrokes = Array(strokes.dropLast())
                state.freeze()
                entry.checkpoint = state
            }
            updateLive(entry, stroke: stroke, state: &state)
        }
        state.freeze()
        entry.strokes = strokes
        entry.state = state
    }

    private func updateLive(_ entry: Entry, stroke: DodgeBurnStroke, state: inout DodgeBurnState) {
        let geometry = entry.geometry
        var live: Live
        if var current = entry.live, current.stroke.id == stroke.id,
           sameSettings(current.stroke, stroke), stroke.points.count >= current.fed,
           Array(stroke.points.prefix(current.fed)) == Array(current.stroke.points.prefix(current.fed)) {
            for p in stroke.points[current.fed...] { current.coverage.feed(geometry.map(p), pressure: p.pressure) }
            current.fed = stroke.points.count
            current.stroke = stroke
            live = current
        } else {
            let full = DodgeBurnRect(x0: 0, y0: 0, x1: geometry.width, y1: geometry.height)
            var cov = DodgeBurnCoverage(bounds: full, radius: geometry.radius(size: stroke.size),
                                        feather: stroke.feather, flow: stroke.flow)
            for p in stroke.points { cov.feed(geometry.map(p), pressure: p.pressure) }
            live = Live(stroke: stroke, coverage: cov, fed: stroke.points.count)
        }
        DodgeBurnRaster.composite(live.coverage, area: live.coverage.dirty, stroke: stroke, into: &state, geometry: geometry)
        entry.live = live
    }

    private func sameSettings(_ a: DodgeBurnStroke, _ b: DodgeBurnStroke) -> Bool {
        var x = a, y = b
        x.points = []; y.points = []
        return x == y
    }
}
