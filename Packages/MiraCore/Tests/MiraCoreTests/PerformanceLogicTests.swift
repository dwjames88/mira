import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import MiraCore

@Suite struct PreviewSizingTests {
    @Test func fitsInsideTheCanvasAndKeepsAspect() {
        let s = PreviewSizing.renderSize(content: CGSize(width: 6000, height: 4000), canvas: CGSize(width: 1500, height: 1000))
        #expect(s == CGSize(width: 1500, height: 1000))
        let tall = PreviewSizing.renderSize(content: CGSize(width: 4000, height: 6000), canvas: CGSize(width: 1500, height: 1000))
        #expect(tall == CGSize(width: 667, height: 1000))
    }

    @Test func neverUpscales() {
        let s = PreviewSizing.renderSize(content: CGSize(width: 800, height: 600), canvas: CGSize(width: 3000, height: 2000))
        #expect(s == CGSize(width: 800, height: 600))
    }

    @Test func tightCropsRenderAtCanvasSizeNotCropSize() {
        // A 1200x800 px crop of a 24 MP photo on a 1500x1000 canvas stays at 1200x800 (all its pixels).
        let s = PreviewSizing.renderSize(content: CGSize(width: 1200, height: 800), canvas: CGSize(width: 1500, height: 1000))
        #expect(s == CGSize(width: 1200, height: 800))
    }

    @Test func missingCanvasUsesFallbackAndHugeCanvasIsCapped() {
        let a = PreviewSizing.renderSize(content: CGSize(width: 6000, height: 4000), canvas: nil)
        #expect(max(a.width, a.height) == PreviewSizing.fallbackLongSide)
        let b = PreviewSizing.renderSize(content: CGSize(width: 12000, height: 8000), canvas: CGSize(width: 9000, height: 9000))
        #expect(max(b.width, b.height) == PreviewSizing.maxSide)
    }

    @Test func canvasIsQuantisedUp() {
        let q = PreviewSizing.quantised(canvas: CGSize(width: 1001, height: 640))
        #expect(q == CGSize(width: 1024, height: 640))
        #expect(PreviewSizing.quantised(canvas: CGSize(width: 1, height: 1)) == CGSize(width: 64, height: 64))
    }
}

@Suite struct RenderGateTests {
    @Test func idleGateStartsImmediately() {
        var gate = RenderGate<Int>()
        #expect(gate.submit(1) == 1)
        #expect(gate.isBusy)
    }

    @Test func latestWinsAndStaleRequestsAreDropped() {
        var gate = RenderGate<Int>()
        #expect(gate.submit(1) == 1)
        #expect(gate.submit(2) == nil)
        #expect(gate.submit(3) == nil)
        #expect(gate.submit(4) == nil)
        #expect(gate.dropped == 2)            // 2 and 3 never ran
        #expect(gate.finish() == 4)           // only the latest follows
        #expect(gate.isBusy)
        #expect(gate.finish() == nil)
        #expect(!gate.isBusy)
        #expect(gate.submit(5) == 5)
    }

    @Test func atMostOneInFlight() {
        var gate = RenderGate<Int>()
        var running = 0, maxRunning = 0
        func start(_ r: Int?) { if r != nil { running += 1; maxRunning = max(maxRunning, running) } }
        for i in 0..<100 {
            start(gate.submit(i))
            if i % 7 == 0 { running -= 1; start(gate.finish()) }
        }
        #expect(maxRunning == 1)
    }

    @Test func cancelPendingDropsWaitingRequest() {
        var gate = RenderGate<Int>()
        _ = gate.submit(1)
        _ = gate.submit(2)
        gate.cancelPending()
        #expect(gate.finish() == nil)
        #expect(!gate.isBusy)
    }
}

@Suite struct BlurReductionTests {
    let context = Renderer.sharedContext

    /// A mask with hard edges and small features, like the halation highlights.
    func mask(size: Int) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(colorSpace: space, components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: size / 5, y: size / 5, width: size / 3, height: size / 4))
        for i in 0..<12 {
            ctx.fillEllipse(in: CGRect(x: size / 2 + i * size / 30, y: size / 2 + (i % 3) * size / 12, width: 14, height: 14))
        }
        return CIImage(cgImage: ctx.makeImage()!)
    }

    func fullResBlur(_ image: CIImage, sigma: CGFloat) -> CIImage {
        let f = CIFilter.gaussianBlur()
        f.inputImage = image.clampedToExtent()
        f.radius = Float(sigma)
        return f.outputImage!.cropped(to: image.extent)
    }

    @Test(arguments: [10.0, 28.0, 60.0])
    func reducedBlurMatchesFullResolution(sigma: Double) {
        let image = mask(size: 800)
        let reference = Pixels(fullResBlur(image, sigma: sigma), context: context).channel(0)
        let reduced = Pixels(Renderer.softBlur(image, extent: image.extent, sigma: sigma), context: context).channel(0)
        #expect(reference.count == reduced.count)
        let diffs = zip(reference, reduced).map { abs($0 - $1) }
        let maxDiff = diffs.max() ?? 1
        #expect(maxDiff < 0.03, "max difference \(maxDiff)")
        #expect(mean(diffs) < 0.003, "mean difference \(mean(diffs))")
    }

    @Test func smallRadiiStayAtFullResolution() {
        let image = mask(size: 400)
        let a = Pixels(fullResBlur(image, sigma: 3), context: context).rgba
        let b = Pixels(Renderer.softBlur(image, extent: image.extent, sigma: 3), context: context).rgba
        #expect(a == b)
    }

    @Test func oddSizesAndOffsetExtentsKeepTheirExtent() {
        let image = mask(size: 777).transformed(by: CGAffineTransform(translationX: 13, y: -7))
        let out = Renderer.softBlur(image, extent: image.extent, sigma: 40)
        #expect(out.extent == image.extent)
    }
}
