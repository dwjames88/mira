import CoreImage
import Foundation
import Testing
@testable import MiraCore

private func close(_ a: CGFloat, _ b: CGFloat, _ eps: CGFloat = 1e-6) -> Bool { abs(a - b) <= eps }

@Suite struct CropGeometryTests {
    // MARK: Inscribed rect

    @Test func inscribedRectAtZeroIsWholeImage() {
        let r = CropGeometry.straightenedBounds(size: CGSize(width: 300, height: 200), angle: 0)
        #expect(r == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func inscribedRectAt45() {
        let size = CGSize(width: 200, height: 200)
        let r = CropGeometry.straightenedBounds(size: size, angle: 45)
        #expect(close(r.width, 200 / 2.0.squareRoot(), 1e-4))
        #expect(close(r.midX, 100) && close(r.midY, 100))
    }

    @Test func inscribedRectAt10KeepsAspectAndFits() {
        let size = CGSize(width: 300, height: 200)
        let r = CropGeometry.straightenedBounds(size: size, angle: 10)
        #expect(close(r.width / r.height, 1.5, 1e-9))
        #expect(r.width < 300 && r.height < 200)
        // Every corner of the inscribed rect lies inside the rotated image.
        let t = 10.0 * .pi / 180
        for corner in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY),
                       CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.minY)] {
            let dx = corner.x - 150, dy = corner.y - 100
            let u = dx * cos(t) + dy * sin(t), v = -dx * sin(t) + dy * cos(t)
            #expect(abs(u) <= 150 + 1e-6 && abs(v) <= 100 + 1e-6)
        }
        // It is the largest: at least one constraint is tight.
        let tight = abs(abs(r.maxX - 150) * cos(t) + abs(r.maxY - 100) * sin(t) - 150) < 1e-6
            || abs(abs(r.maxX - 150) * sin(t) + abs(r.maxY - 100) * cos(t) - 100) < 1e-6
        #expect(tight)
    }

    @Test func orientedSizeSwapsForOddTurns() {
        let size = CGSize(width: 300, height: 200)
        #expect(CropGeometry.orientedSize(for: CropSettings(rotate90: 1), size: size) == CGSize(width: 200, height: 300))
        #expect(CropGeometry.orientedSize(for: CropSettings(rotate90: 2), size: size) == size)
        #expect(CropGeometry.orientedSize(for: CropSettings(rotate90: 3), size: size) == CGSize(width: 200, height: 300))
    }

    @Test func canvasCornersMapInsideSource() {
        let extent = CGRect(x: 0, y: 0, width: 300, height: 200)
        for angle in [-30.0, -7.5, 12, 45] {
            let crop = CropSettings(straighten: angle)
            let inv = CropGeometry.canvasTransform(for: crop, imageExtent: extent).inverted()
            for p in [CGPoint(x: 0, y: 0), CGPoint(x: 300, y: 0), CGPoint(x: 0, y: 200), CGPoint(x: 300, y: 200)] {
                let q = p.applying(inv)
                #expect(q.x >= -1e-6 && q.x <= 300 + 1e-6 && q.y >= -1e-6 && q.y <= 200 + 1e-6)
            }
        }
    }

    // MARK: Rect editing

    let bounds = CGRect(x: 0, y: 0, width: 600, height: 400)

    @Test func constrainToThreeTwo() {
        let r = CropGeometry.constrain(rect: CGRect(x: 100, y: 100, width: 300, height: 300), toAspect: 1.5, within: bounds)
        #expect(close(r.width / r.height, 1.5, 1e-9))
        #expect(bounds.contains(r))
        #expect(close(r.width * r.height, 90_000, 1e-3))
    }

    @Test func constrainShrinksToFitBounds() {
        let r = CropGeometry.constrain(rect: bounds, toAspect: 1, within: bounds)
        #expect(close(r.width, 400) && close(r.height, 400))
        #expect(bounds.contains(r))
        #expect(CropGeometry.constrain(rect: bounds, toAspect: nil, within: bounds) == bounds)
    }

    @Test func cornerResizeKeepsLockedAspect() {
        let start = CGRect(x: 100, y: 100, width: 300, height: 200)
        for handle in [CropHandle.topLeft, .topRight, .bottomLeft, .bottomRight] {
            for d in [CGSize(width: 40, height: 10), CGSize(width: -60, height: -90), CGSize(width: 15, height: -25)] {
                let r = CropGeometry.resize(rect: start, handle: handle, by: d, aspect: 1.5, within: bounds, minSize: 20)
                #expect(close(r.width / r.height, 1.5, 1e-6))
                #expect(bounds.insetBy(dx: -1e-6, dy: -1e-6).contains(r))
            }
        }
        // The opposite corner stays put.
        let r = CropGeometry.resize(rect: start, handle: .bottomRight, by: CGSize(width: 30, height: 20), aspect: 1.5, within: bounds, minSize: 20)
        #expect(close(r.minX, 100) && close(r.minY, 100))
        let tl = CropGeometry.resize(rect: start, handle: .topLeft, by: CGSize(width: 30, height: 20), aspect: 1.5, within: bounds, minSize: 20)
        #expect(close(tl.maxX, 400) && close(tl.maxY, 300))
    }

    @Test func cornerResizeClampsToBoundsAndMinimum() {
        let start = CGRect(x: 100, y: 100, width: 300, height: 200)
        let big = CropGeometry.resize(rect: start, handle: .bottomRight, by: CGSize(width: 900, height: 900), aspect: 1.5, within: bounds, minSize: 20)
        #expect(close(big.maxY, 400) || close(big.maxX, 600))
        #expect(bounds.insetBy(dx: -1e-6, dy: -1e-6).contains(big))
        let tiny = CropGeometry.resize(rect: start, handle: .bottomRight, by: CGSize(width: -900, height: -900), aspect: 1.5, within: bounds, minSize: 40)
        #expect(close(tiny.height, 40) && close(tiny.width, 60))
    }

    @Test func freeResizeAndEdges() {
        let start = CGRect(x: 100, y: 100, width: 300, height: 200)
        let r = CropGeometry.resize(rect: start, handle: .right, by: CGSize(width: 50, height: 99), aspect: nil, within: bounds, minSize: 20)
        #expect(r == CGRect(x: 100, y: 100, width: 350, height: 200))
        let l = CropGeometry.resize(rect: start, handle: .left, by: CGSize(width: -500, height: 0), aspect: nil, within: bounds, minSize: 20)
        #expect(l.minX == 0 && l.maxX == 400)
        let squash = CropGeometry.resize(rect: start, handle: .top, by: CGSize(width: 0, height: 900), aspect: nil, within: bounds, minSize: 20)
        #expect(close(squash.height, 20) && close(squash.maxY, 300))
    }

    @Test func edgeResizeWithAspectStaysCentred() {
        let start = CGRect(x: 150, y: 100, width: 300, height: 200)
        let r = CropGeometry.resize(rect: start, handle: .right, by: CGSize(width: 60, height: 0), aspect: 1.5, within: bounds, minSize: 20)
        #expect(close(r.width, 360) && close(r.width / r.height, 1.5))
        #expect(close(r.midY, 200))
        let t = CropGeometry.resize(rect: start, handle: .top, by: CGSize(width: 0, height: -30), aspect: 1.5, within: bounds, minSize: 20)
        #expect(close(t.maxY, 300) && close(t.width / t.height, 1.5) && close(t.midX, 300))
        #expect(bounds.contains(t))
    }

    @Test func panIsClamped() {
        let start = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(CropGeometry.pan(rect: start, by: CGSize(width: 50, height: -20), within: bounds) == CGRect(x: 150, y: 80, width: 300, height: 200))
        #expect(CropGeometry.pan(rect: start, by: CGSize(width: 900, height: 900), within: bounds) == CGRect(x: 300, y: 200, width: 300, height: 200))
        #expect(CropGeometry.pan(rect: start, by: CGSize(width: -900, height: -900), within: bounds) == CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    @Test func hitTest() {
        let r = CGRect(x: 100, y: 100, width: 300, height: 200)
        #expect(CropGeometry.hitTest(point: CGPoint(x: 102, y: 98), rect: r, tolerance: 12) == .handle(.topLeft))
        #expect(CropGeometry.hitTest(point: CGPoint(x: 398, y: 302), rect: r, tolerance: 12) == .handle(.bottomRight))
        #expect(CropGeometry.hitTest(point: CGPoint(x: 250, y: 104), rect: r, tolerance: 12) == .handle(.top))
        #expect(CropGeometry.hitTest(point: CGPoint(x: 404, y: 200), rect: r, tolerance: 12) == .handle(.right))
        #expect(CropGeometry.hitTest(point: CGPoint(x: 250, y: 200), rect: r, tolerance: 12) == .move)
        #expect(CropGeometry.hitTest(point: CGPoint(x: 10, y: 10), rect: r, tolerance: 12) == .none)
    }

    @Test func aspectFit() {
        let r = CropGeometry.aspectFit(contentSize: CGSize(width: 300, height: 200), in: CGRect(x: 0, y: 0, width: 600, height: 600))
        #expect(r == CGRect(x: 0, y: 150, width: 600, height: 400))
    }

    @Test func rotateAndFlipUpdateRect() {
        var c = CropSettings(rect: CropRect(x: 0, y: 0, w: 0.5, h: 1), aspect: "3:2")
        c = CropGeometry.rotatedClockwise(c)
        #expect(c.rotate90 == 1 && c.aspect == "2:3")
        #expect(c.rect == CropRect(x: 0, y: 0, w: 1, h: 0.5))
        c = CropGeometry.flippedHorizontally(CropSettings(rect: CropRect(x: 0, y: 0, w: 0.25, h: 1), straighten: 5))
        #expect(c.flipH && c.straighten == -5 && c.rect == CropRect(x: 0.75, y: 0, w: 0.25, h: 1))
    }

    @Test func aspectPresets() {
        let canvas = CGSize(width: 300, height: 200)
        #expect(CropAspect.ratio(id: "original", canvas: canvas) == 1.5)
        #expect(CropAspect.ratio(id: "free", canvas: canvas) == nil)
        #expect(CropAspect.ratio(id: "square", canvas: canvas) == 1)
        #expect(CropAspect.ratio(id: "16:9", canvas: canvas) == 16.0 / 9)
        #expect(CropAspect.swapped("3:2") == "2:3")
        #expect(CropAspect.landscape("9:16") == "16:9")
        for id in CropAspect.allIDs { #expect(CropAspect.ratio(id: id, canvas: canvas) != nil || id == "free") }
    }
}

@Suite struct CropRenderTests {
    let context = Renderer.makeContext()

    /// Visual quadrants: top-left red, top-right green, bottom-left blue, bottom-right yellow.
    static func quadrants(width: Int, height: Int) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        func block(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ rect: CGRect) -> CIImage {
            CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 1, colorSpace: space)!).cropped(to: rect)
        }
        let w = CGFloat(width), h = CGFloat(height)
        let red = block(1, 0, 0, CGRect(x: 0, y: h / 2, width: w / 2, height: h / 2))
        let green = block(0, 1, 0, CGRect(x: w / 2, y: h / 2, width: w / 2, height: h / 2))
        let blue = block(0, 0, 1, CGRect(x: 0, y: 0, width: w / 2, height: h / 2))
        let yellow = block(1, 1, 0, CGRect(x: w / 2, y: 0, width: w / 2, height: h / 2))
        return red.composited(over: green).composited(over: blue).composited(over: yellow)
    }

    /// Dominant channel name at a pixel (row 0 = top).
    func colour(_ p: Pixels, x: Int, y: Int) -> String {
        let i = (y * p.width + x) * 4
        let (r, g, b) = (p.rgba[i] > 128, p.rgba[i + 1] > 128, p.rgba[i + 2] > 128)
        switch (r, g, b) {
        case (true, false, false): return "red"
        case (false, true, false): return "green"
        case (false, false, true): return "blue"
        case (true, true, false): return "yellow"
        default: return "other"
        }
    }

    @Test func rotate90SwapsDimensions() throws {
        let r = Renderer(library: try emptyLibrary())
        let out = r.apply(Recipe(crop: CropSettings(rotate90: 1)), to: Self.quadrants(width: 200, height: 100))
        #expect(out.extent == CGRect(x: 0, y: 0, width: 100, height: 200))
        let p = Pixels(out, context: context)
        // Clockwise: old bottom-left (blue) is now top-left, old top-left (red) top-right.
        #expect(colour(p, x: 10, y: 10) == "blue")
        #expect(colour(p, x: 90, y: 10) == "red")
        #expect(colour(p, x: 10, y: 190) == "yellow")
        #expect(colour(p, x: 90, y: 190) == "green")
    }

    @Test func cropLeftHalfAfterRotate90() throws {
        let r = Renderer(library: try emptyLibrary())
        let crop = CropSettings(rect: CropRect(x: 0, y: 0, w: 0.5, h: 1), rotate90: 1)
        let out = r.apply(Recipe(crop: crop), to: Self.quadrants(width: 200, height: 100))
        #expect(out.extent == CGRect(x: 0, y: 0, width: 50, height: 200))
        let p = Pixels(out, context: context)
        #expect(colour(p, x: 25, y: 20) == "blue")
        #expect(colour(p, x: 25, y: 180) == "yellow")
        #expect(colour(p, x: 5, y: 5) == "blue")
    }

    @Test func flipsMirrorTheCanvas() throws {
        let r = Renderer(library: try emptyLibrary())
        let h = Pixels(r.apply(Recipe(crop: CropSettings(flipH: true)), to: Self.quadrants(width: 200, height: 100)), context: context)
        #expect(colour(h, x: 10, y: 10) == "green")
        #expect(colour(h, x: 190, y: 90) == "blue")
        let v = Pixels(r.apply(Recipe(crop: CropSettings(flipV: true)), to: Self.quadrants(width: 200, height: 100)), context: context)
        #expect(colour(v, x: 10, y: 10) == "blue")
        #expect(colour(v, x: 190, y: 90) == "green")
    }

    @Test func rotatingTheSettingsMatchesRotatingTheCanvas() throws {
        // Rotating settings clockwise must give the same picture as rotating the picture.
        let r = Renderer(library: try emptyLibrary())
        let src = Self.quadrants(width: 200, height: 100)
        let base = CropSettings(flipH: true)
        let rotated = CropGeometry.rotatedClockwise(base)
        let a = Pixels(r.apply(Recipe(crop: rotated), to: src), context: context)
        let b = Pixels(r.apply(Recipe(crop: base), to: src).transformed(by: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 200)), context: context)
        #expect(a.rgba == b.rgba)
    }

    @Test func straightenLeavesNoTransparentPixels() throws {
        let r = Renderer(library: try emptyLibrary())
        let src = Fixture.solid(gray: 0.6, size: 240)
        for angle in [12.0, -12, 45] {
            let out = r.apply(Recipe(crop: CropSettings(straighten: angle)), to: src)
            #expect(out.extent == src.extent)
            let p = Pixels(out, context: context)
            for (x, y) in [(0, 0), (p.width - 1, 0), (0, p.height - 1), (p.width - 1, p.height - 1), (120, 0), (0, 120)] {
                let i = (y * p.width + x) * 4
                #expect(p.rgba[i + 3] == 255)
                #expect(abs(Int(p.rgba[i]) - Int(p.rgba[i + 1])) <= 1)
            }
        }
    }

    @Test func straightenAndCropExtent() throws {
        let r = Renderer(library: try emptyLibrary())
        let crop = CropSettings(rect: CropRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5), straighten: 6)
        let out = r.apply(Recipe(crop: crop), to: Fixture.gradientAndPatches(size: 200))
        #expect(out.extent == CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    @Test func identityCropIsBitIdentical() throws {
        let r = Renderer(library: try emptyLibrary())
        let input = Fixture.gradientAndPatches(size: 128)
        var withCrop = Recipe(exposure: 0.3, grainAmount: 0.4, vignetteAmount: 0.3)
        withCrop.crop = CropSettings(aspect: "3:2") // aspect alone is not geometry
        let plain = Recipe(exposure: 0.3, grainAmount: 0.4, vignetteAmount: 0.3)
        #expect(Pixels(r.apply(withCrop, to: input), context: context).rgba
                == Pixels(r.apply(plain, to: input), context: context).rgba)
        #expect(r.apply(Recipe.neutral, to: input).extent == input.extent)
    }

    @Test func effectsScaleToCroppedOutput() throws {
        // The vignette is centred on the cropped output, not on the source.
        let r = Renderer(library: try emptyLibrary())
        let src = Fixture.solid(gray: 0.7, size: 400)
        var recipe = Recipe(vignetteAmount: 1)
        recipe.crop = CropSettings(rect: CropRect(x: 0, y: 0, w: 0.5, h: 0.5))
        let p = Pixels(r.apply(recipe, to: src), context: context)
        let centre = p.luma[(p.height / 2) * p.width + p.width / 2]
        let corner = p.luma[0]
        #expect(corner < centre)
    }

    @Test func borderUsesCroppedExtent() throws {
        let r = Renderer(library: try emptyLibrary())
        var recipe = Recipe(borderEnabled: true, borderWidth: 0.1)
        recipe.crop = CropSettings(rect: CropRect(x: 0, y: 0, w: 0.5, h: 1))
        let out = r.apply(recipe, to: Fixture.solid(gray: 0.5, size: 200))
        #expect(out.extent == CGRect(x: -10, y: -10, width: 120, height: 220))
    }
}

@Suite struct CropRecipeTests {
    @Test func roundTripWithCrop() throws {
        var r = Recipe(filmID: "x", exposure: 0.2)
        r.crop = CropSettings(rect: CropRect(x: 0.1, y: 0.2, w: 0.6, h: 0.5), straighten: -4.5, rotate90: 3,
                              flipH: true, flipV: false, aspect: "4:5")
        let data = try r.encoded()
        #expect(try Recipe.decode(data) == r)
        #expect(try r.encoded() == data)
        let json = String(decoding: data, as: UTF8.self)
        #expect(json.contains("\"crop\":{\"aspect\":\"4:5\",\"flipH\":true,\"flipV\":false,\"rect\":{"))
    }

    @Test func adjustmentCodecRoundTrip() throws {
        var r = Recipe(filmID: "kodak-portra-400")
        r.crop = CropSettings(rect: CropRect(x: 0.05, y: 0.1, w: 0.9, h: 0.8), straighten: 3.25, rotate90: 1)
        let data = try MiraAdjustment.encode(r)
        let back = MiraAdjustment.decode(formatIdentifier: MiraAdjustment.formatIdentifier,
                                         formatVersion: MiraAdjustment.formatVersion, data: data)
        #expect(back == r)
        #expect(MiraAdjustment.formatVersion == "1")
    }

    @Test func legacyRecipeWithoutCropDecodesToIdentity() throws {
        let legacy = Data(#"{"exposure":0.4,"filmID":"fuji-velvia-50","version":1}"#.utf8)
        let r = try Recipe.decode(legacy)
        #expect(r.crop == .identity && r.crop.isIdentity)
        let viaLegacyID = MiraAdjustment.decode(formatIdentifier: "com.dwjames.emulsion", formatVersion: "1", data: legacy)
        #expect(viaLegacyID?.crop == .identity)
        #expect(viaLegacyID?.exposure == 0.4)
    }

    @Test func partialCropDecodesWithDefaults() throws {
        let r = try Recipe.decode(Data(#"{"crop":{"straighten":99,"rotate90":5}}"#.utf8))
        #expect(r.crop.straighten == 45)
        #expect(r.crop.rotate90 == 1)
        #expect(r.crop.rect == .full)
        #expect(r.crop.aspect == "original")
        let empty = try Recipe.decode(Data(#"{"crop":{}}"#.utf8))
        #expect(empty.crop.isIdentity)
    }

    @Test func identityDetection() {
        #expect(CropSettings.identity.isIdentity)
        #expect(!CropSettings(straighten: 0.1).isIdentity)
        #expect(!CropSettings(rotate90: 1).isIdentity)
        #expect(CropSettings(rotate90: 4).isIdentity)
        #expect(!CropSettings(flipV: true).isIdentity)
        #expect(!CropSettings(rect: CropRect(x: 0, y: 0, w: 0.9, h: 1)).isIdentity)
    }
}
