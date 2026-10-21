import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

@Suite struct ZoomGeometryTests {
    /// A 24 MP picture in a 1500 x 1000 px pane, fit into the pane minus 48 px of padding.
    let vp = ZoomViewport(content: CGSize(width: 6000, height: 4000), pane: CGSize(width: 1500, height: 1000),
                          fitArea: CGSize(width: 1404, height: 904))

    func near(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 0.5) -> Bool { abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol }

    @Test func fitScaleAndFitMapping() {
        let fit = ZoomGeometry.fitScale(vp)
        #expect(abs(fit - 904.0 / 4000) < 1e-9)
        // The whole picture lands centred in the pane at the fit scale.
        let r = ZoomGeometry.paneRect(ofContentRect: CGRect(origin: .zero, size: vp.content), state: .fit, in: vp)
        #expect(abs(r.midX - 750) < 1e-6 && abs(r.midY - 500) < 1e-6)
        #expect(abs(r.height - 904) < 1e-6)
    }

    @Test func clickZoomsTo200PercentAroundThePointAndBack() {
        // The pane centre is the picture centre.
        let z = ZoomGeometry.clicked(.fit, atPane: CGPoint(x: 750, y: 500), in: vp)
        #expect(z.scale == 2)
        #expect(near(z.center, CGPoint(x: 3000, y: 2000)))

        // A point right of and below centre: that picture point becomes the centre.
        let p = CGPoint(x: 900, y: 560)
        let expected = ZoomGeometry.contentPoint(atPane: p, state: .fit, in: vp)
        let z2 = ZoomGeometry.clicked(.fit, atPane: p, in: vp)
        #expect(near(z2.center, expected))
        #expect(near(ZoomGeometry.contentPoint(atPane: CGPoint(x: 750, y: 500), state: z2, in: vp), expected))

        // Click again: fit.
        #expect(ZoomGeometry.clicked(z2, atPane: p, in: vp).isFit)
    }

    @Test func clickNearAnEdgeIsClampedToTheImage() {
        let z = ZoomGeometry.clicked(.fit, atPane: CGPoint(x: 80, y: 60), in: vp)
        #expect(z.scale == 2)
        // The view may not show anything outside the picture: half a pane (at 200%) from the corner.
        #expect(near(z.center, CGPoint(x: 375, y: 250)))
        let visible = ZoomGeometry.visibleContentRect(state: z, in: vp)
        #expect(visible == CGRect(x: 0, y: 0, width: 750, height: 500))

        // A click on the letterbox of a narrow picture lands on the picture's edge.
        let narrow = ZoomViewport(content: CGSize(width: 1000, height: 4000), pane: vp.pane, fitArea: vp.fitArea)
        let z2 = ZoomGeometry.clicked(.fit, atPane: CGPoint(x: 20, y: 500), in: narrow)
        #expect(z2.scale == 2)
        #expect(z2.center.x == 375) // clamped to the picture's left edge
    }

    @Test func smallPicturesDoNotZoomOnClick() {
        let small = ZoomViewport(content: CGSize(width: 400, height: 300), pane: vp.pane, fitArea: vp.fitArea)
        #expect(ZoomGeometry.fitScale(small) > 2)
        #expect(ZoomGeometry.clicked(.fit, atPane: CGPoint(x: 750, y: 500), in: small).isFit)
        #expect(ZoomGeometry.ladder(in: small).count == 2) // fit, 400%
    }

    @Test func stepsClampAtBothEnds() {
        var z = ZoomState.fit
        var seen: [Double?] = []
        for _ in 0..<6 {
            z = ZoomGeometry.stepped(z, by: 1, anchor: nil, in: vp)
            seen.append(z.scale)
        }
        #expect(seen == [0.5, 1, 2, 4, 4, 4])
        seen = []
        for _ in 0..<6 {
            z = ZoomGeometry.stepped(z, by: -1, anchor: nil, in: vp)
            seen.append(z.scale)
        }
        #expect(seen == [2, 1, 0.5, nil, nil, nil])
        #expect(z.isFit)
    }

    @Test func steppingKeepsThePointUnderTheAnchor() {
        let anchor = CGPoint(x: 1000, y: 620)
        let before = ZoomGeometry.contentPoint(atPane: anchor, state: .fit, in: vp)
        let z = ZoomGeometry.stepped(.fit, by: 1, anchor: anchor, in: vp)
        #expect(z.scale == 0.5)
        #expect(near(ZoomGeometry.contentPoint(atPane: anchor, state: z, in: vp), before, 0.01))
        let z2 = ZoomGeometry.stepped(z, by: 1, anchor: anchor, in: vp)
        #expect(near(ZoomGeometry.contentPoint(atPane: anchor, state: z2, in: vp), before, 0.01))

        // No anchor: the pane centre stays.
        let c = ZoomGeometry.contentPoint(atPane: CGPoint(x: 750, y: 500), state: z2, in: vp)
        let z3 = ZoomGeometry.stepped(z2, by: 1, anchor: nil, in: vp)
        #expect(near(ZoomGeometry.contentPoint(atPane: CGPoint(x: 750, y: 500), state: z3, in: vp), c, 0.01))
    }

    @Test func panIsClampedToTheImage() {
        var z = ZoomState(scale: 1, center: CGPoint(x: 3000, y: 2000))
        z = ZoomGeometry.panned(z, byPane: CGSize(width: -200, height: 50), in: vp)
        #expect(near(z.center, CGPoint(x: 3200, y: 1950)))
        // Far past the right and bottom edges.
        z = ZoomGeometry.panned(z, byPane: CGSize(width: -1e6, height: -1e6), in: vp)
        #expect(near(z.center, CGPoint(x: 6000 - 750, y: 4000 - 500)))
        // Far past the left and top edges.
        z = ZoomGeometry.panned(z, byPane: CGSize(width: 1e6, height: 1e6), in: vp)
        #expect(near(z.center, CGPoint(x: 750, y: 500)))
        // Fit ignores a pan.
        #expect(ZoomGeometry.panned(.fit, byPane: CGSize(width: 40, height: 40), in: vp).isFit)
    }

    @Test func aPictureSmallerThanThePaneStaysCentred() {
        let narrow = ZoomViewport(content: CGSize(width: 1000, height: 4000), pane: vp.pane, fitArea: vp.fitArea)
        let z = ZoomGeometry.panned(ZoomState(scale: 1, center: CGPoint(x: 500, y: 2000)), byPane: CGSize(width: 300, height: -300), in: narrow)
        #expect(z.center.x == 500)
        #expect(near(z.center, CGPoint(x: 500, y: 2300)))
    }

    @Test func viewportToImageRectIncludingCrop() {
        // A crop to the middle quarter of a 6000 x 4000 picture: 3000 x 2000 content.
        var recipe = Recipe.neutral
        recipe.crop.rect = CropRect(x: 0.25, y: 0.25, w: 0.5, h: 0.5)
        let content = PreviewEngine.zoomContentSize(for: recipe, imageSize: CGSize(width: 6000, height: 4000))
        #expect(content == CGSize(width: 3000, height: 2000))
        let cropped = ZoomViewport(content: content, pane: vp.pane, fitArea: vp.fitArea)

        let z = ZoomState(scale: 1, center: CGPoint(x: 1500, y: 1000))
        #expect(ZoomGeometry.visibleContentRect(state: z, in: cropped) == CGRect(x: 750, y: 500, width: 1500, height: 1000))
        // At 200% the same pane shows half the area.
        let z2 = ZoomState(scale: 2, center: CGPoint(x: 1500, y: 1000))
        #expect(ZoomGeometry.visibleContentRect(state: z2, in: cropped) == CGRect(x: 1125, y: 750, width: 750, height: 500))
        // At 50% the 3000 x 2000 picture exactly fills the pane.
        let z3 = ZoomState(scale: 0.5, center: CGPoint(x: 1500, y: 1000))
        #expect(ZoomGeometry.visibleContentRect(state: z3, in: cropped) == CGRect(x: 0, y: 0, width: 3000, height: 2000))

        // The pixels to render: the same view in scaled pixels, whole numbers.
        let region = ZoomGeometry.renderRegion(state: z2, in: cropped)
        #expect(region == ZoomRegion(scale: 2, rect: CGRect(x: 2250, y: 1500, width: 1500, height: 1000)))
        #expect(ZoomGeometry.renderRegion(state: .fit, in: cropped) == nil)

        // A pane point maps back to the picture, then the picture point forward to the pane.
        let p = CGPoint(x: 300, y: 900)
        let c = ZoomGeometry.contentPoint(atPane: p, state: z, in: cropped)
        #expect(near(c, CGPoint(x: 1500 + (300 - 750), y: 1000 + (900 - 500))))
        let back = ZoomGeometry.paneRect(ofContentRect: CGRect(origin: c, size: CGSize(width: 10, height: 10)), state: z, in: cropped)
        #expect(near(back.origin, p))
    }

    @Test func borderEnlargesTheZoomContent() {
        var recipe = Recipe.neutral
        recipe.borderEnabled = true
        recipe.borderWidth = 0.1
        let size = PreviewEngine.zoomContentSize(for: recipe, imageSize: CGSize(width: 3000, height: 2000))
        #expect(size == CGSize(width: 3400, height: 2400))
    }

    @Test func resizingRevalidatesTheState() {
        let z = ZoomState(scale: 0.5, center: CGPoint(x: 3000, y: 2000))
        #expect(ZoomGeometry.revalidated(z, in: vp) == z)
        // A pane so large that fit is bigger than 50%: back to fit.
        let big = ZoomViewport(content: vp.content, pane: CGSize(width: 4000, height: 3000), fitArea: CGSize(width: 3900, height: 2900))
        #expect(ZoomGeometry.revalidated(z, in: big).isFit)
    }

    @Test func readouts() {
        #expect(ZoomGeometry.readout(for: .fit) == "Fit")
        #expect(ZoomGeometry.readout(for: ZoomState(scale: 1, center: .zero)) == "100%")
        #expect(ZoomGeometry.readout(for: ZoomState(scale: 0.5, center: .zero)) == "50%")
        #expect(ZoomGeometry.readout(for: ZoomState(scale: 4, center: .zero)) == "400%")
    }
}

@Suite struct ZoomRenderTests {
    let context = Renderer.sharedContext

    func engine(_ image: CIImage) throws -> PreviewEngine {
        let e = PreviewEngine(renderer: Renderer(library: try emptyLibrary()), context: context)
        e.setSource(image)
        return e
    }

    /// RGB (0...1) at (x, y), top-left origin, of a frame.
    func pixel(_ frame: PreviewFrame, _ x: Int, _ y: Int) throws -> [Double] {
        let image = CIImage(cvPixelBuffer: frame.pixelBuffer, options: [.colorSpace: PreviewEngine.srgbSpace])
        var px = [UInt8](repeating: 0, count: 4)
        let h = Int(image.extent.height)
        context.render(image, toBitmap: &px, rowBytes: 4,
                       bounds: CGRect(x: x, y: h - 1 - y, width: 1, height: 1), format: .RGBA8,
                       colorSpace: PreviewEngine.srgbSpace)
        return px.prefix(3).map { Double($0) / 255 }
    }

    func close(_ a: [Double], _ b: [Double], _ tol: Double = 0.03) -> Bool {
        zip(a, b).allSatisfy { abs($0 - $1) <= tol }
    }

    @Test func regionAtFullScaleIsTheSourcePixels() throws {
        // 800 x 800: grey gradient on the top half, eight colour patches (100 px wide) on the bottom.
        let e = try engine(Fixture.gradientAndPatches(size: 800))
        let top = try #require(e.renderZoomed(.neutral, region: ZoomRegion(scale: 1, rect: CGRect(x: 0, y: 0, width: 800, height: 200))))
        #expect(top.pixelSize == CGSize(width: 800, height: 200))
        #expect(top.placement == ZoomPlacement(scale: 1, origin: .zero))
        let g = try pixel(top, 400, 100)
        #expect(abs(g[0] - g[1]) < 0.01 && abs(g[1] - g[2]) < 0.01)   // a grey: the gradient is on top
        #expect(abs(g[0] - 0.5) < 0.03)

        let bottom = try #require(e.renderZoomed(.neutral, region: ZoomRegion(scale: 1, rect: CGRect(x: 0, y: 600, width: 800, height: 200))))
        #expect(bottom.placement?.origin == CGPoint(x: 0, y: 600))
        #expect(close(try pixel(bottom, 50, 100), [0.8, 0.2, 0.2]))     // first patch
        #expect(close(try pixel(bottom, 250, 100), [0.2, 0.3, 0.85]))   // third patch
        #expect(close(try pixel(bottom, 750, 100), [0.9, 0.9, 0.9]))    // eighth patch
    }

    @Test func regionOffsetsMatchTheSourceColumns() throws {
        let e = try engine(Fixture.gradientAndPatches(size: 800))
        // Window over the boundary between patch 2 (green, x 100...200) and patch 3 (blue).
        let f = try #require(e.renderZoomed(.neutral, region: ZoomRegion(scale: 1, rect: CGRect(x: 190, y: 650, width: 20, height: 20))))
        #expect(close(try pixel(f, 2, 10), [0.2, 0.7, 0.3]))
        #expect(close(try pixel(f, 17, 10), [0.2, 0.3, 0.85]))
    }

    @Test func cropIsAppliedBeforeTheRegion() throws {
        let e = try engine(Fixture.gradientAndPatches(size: 800))
        var recipe = Recipe.neutral
        recipe.crop.rect = CropRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5) // bottom right: patches 4...7
        let content = PreviewEngine.zoomContentSize(for: recipe, imageSize: CGSize(width: 800, height: 800))
        #expect(content == CGSize(width: 400, height: 400))
        let f = try #require(e.renderZoomed(recipe, region: ZoomRegion(scale: 1, rect: CGRect(x: 0, y: 0, width: 400, height: 400))))
        #expect(f.pixelSize == CGSize(width: 400, height: 400))
        #expect(close(try pixel(f, 50, 200), [0.85, 0.6, 0.5]))   // patch 4
        #expect(close(try pixel(f, 350, 200), [0.9, 0.9, 0.9]))   // patch 7
    }

    @Test func otherScalesGiveRegionsOfTheRightSize() throws {
        let e = try engine(Fixture.gradientAndPatches(size: 800))
        var recipe = Recipe.neutral
        recipe.crop.rect = CropRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5)
        // 200%: the top-left 100 x 100 picture pixels (patch 4) fill a 200 x 200 region.
        let big = try #require(e.renderZoomed(recipe, region: ZoomRegion(scale: 2, rect: CGRect(x: 0, y: 0, width: 200, height: 200))))
        #expect(big.pixelSize == CGSize(width: 200, height: 200))
        #expect(close(try pixel(big, 100, 100), [0.85, 0.6, 0.5]))
        #expect(big.contentRect(whole: CGSize(width: 400, height: 400)) == CGRect(x: 0, y: 0, width: 100, height: 100))
        // 50%: the whole 400 x 400 crop is 200 x 200.
        let half = try #require(e.renderZoomed(recipe, region: ZoomRegion(scale: 0.5, rect: CGRect(x: 0, y: 0, width: 200, height: 200))))
        #expect(half.pixelSize == CGSize(width: 200, height: 200))
        #expect(close(try pixel(half, 25, 100), [0.85, 0.6, 0.5]))    // content x 50 -> source 450: patch 4
        #expect(close(try pixel(half, 175, 100), [0.9, 0.9, 0.9], 0.04)) // content x 350 -> source 750: patch 7
    }

    @Test func regionBeyondThePictureIsClipped() throws {
        let e = try engine(Fixture.gradientAndPatches(size: 800))
        let f = try #require(e.renderZoomed(.neutral, region: ZoomRegion(scale: 1, rect: CGRect(x: 700, y: 700, width: 500, height: 500))))
        #expect(f.pixelSize == CGSize(width: 100, height: 100))
        #expect(f.placement?.origin == CGPoint(x: 700, y: 700))
        #expect(e.renderZoomed(.neutral, region: ZoomRegion(scale: 1, rect: CGRect(x: 900, y: 0, width: 50, height: 50))) == nil)
    }

    @Test func effectsFollowTheWholePictureNotTheRegion() throws {
        // A vignette darkens towards the picture's corners, so a region at the centre stays bright
        // and a region at a corner is darker than the same region without the vignette.
        let e = try engine(Fixture.solid(gray: 0.6, size: 1000))
        var recipe = Recipe.neutral
        recipe.vignetteAmount = 1
        let centre = try #require(e.renderZoomed(recipe, region: ZoomRegion(scale: 1, rect: CGRect(x: 450, y: 450, width: 100, height: 100))))
        let corner = try #require(e.renderZoomed(recipe, region: ZoomRegion(scale: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 100))))
        let c = try pixel(centre, 50, 50)[0], k = try pixel(corner, 5, 5)[0]
        #expect(c > k + 0.05)
    }

    @Test func zoomBaseIsCachedAcrossPans() throws {
        let e = try engine(Fixture.gradientAndPatches(size: 800))
        let a = try #require(e.zoomBase(crop: .identity, scale: 1))
        let b = try #require(e.zoomBase(crop: .identity, scale: 1))
        #expect(a === b)
        e.setSource(Fixture.gradientAndPatches(size: 800))
        let c = try #require(e.zoomBase(crop: .identity, scale: 1))
        #expect(c !== a)
    }
}
