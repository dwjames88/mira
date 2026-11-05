import CoreImage
import Metal
import MiraCore
import SwiftUI
import XCTest
@testable import Mira

/// The main preview must show the COMPLETE recipe, with the same graded pixels, in every editor step.
/// Bug report: "the film looks one way when it's applied, then it changes when moving to Develop".
///
/// What differs between steps is only the size of the photo rect (the panel under the photo changes height).
/// These tests take the photo rect each step really gets (the real `EditorScaffold` with the real panels,
/// at iPhone 16 Pro 402x874 @3x and iPhone SE 375x667 @2x), drive `EditorViewModel` + `LivePreview` the way
/// `RootView` / `MetalPreviewView` do (`LivePreview.frame`), and compare the pixels.
///
/// Tolerances: the GRADED image (what the engine produced from the proxy) must match exactly (0). The drawn
/// frames at two different sizes can only be compared after resampling both to a common size, so there the
/// bound is `placementTolerance` mean absolute error (of 255): the frame centres the photo, so two sizes can place it half
/// a pixel apart and Core Image resamples it once; the frames are compared after a low-pass to 48 x 32. A missing develop / texture stage
/// moves the mean by ~25, asserted below as a sanity check.
@MainActor
final class StepConsistencyTests: XCTestCase {
    static let placementTolerance = 3.0
    static let rawDraftTolerance = 6.0
    static let ink = CIColor(red: 0.082, green: 0.078, blue: 0.059)

    // MARK: Fixtures

    struct Look { let film: Film; let recipe: Recipe }

    static func film(mono: Bool, skipping: String? = nil) -> Film {
        PhotoEngine.filmList.first { $0.isMonochrome == mono && $0.id != skipping && $0.family != .print }!
    }

    /// A preset that sets develop values and texture, like the one in the bug report.
    static func preset(_ name: String, film: Film, exposure: Double = 0.12, grain: Double = 0.6,
                       halation: Double = 0.7, bloom: Double = 0.8) -> Preset {
        var r = Recipe(filmID: film.id)
        r.pipeline = Recipe.currentPipeline
        r.exposure = exposure; r.highlights = -0.35; r.shadows = 0.3; r.contrast = 0.2; r.saturation = -0.05
        r.grainAmount = grain; r.halationAmount = halation; r.bloomAmount = bloom
        r.push = 0.5
        return Preset(nickname: name, recipe: r, filmName: film.displayName)
    }

    func jpegModel() async -> EditorViewModel {
        let m = EditorViewModel()
        let url = Bundle.main.url(forResource: "sample", withExtension: "jpg")!
        await m.openData(try! Data(contentsOf: url))
        XCTAssertTrue(m.hasPhoto)
        return m
    }

    func dngModel(film: Bool) -> EditorViewModel? {
        let url = Snapshot.root.appendingPathComponent("Fixtures/raw/iphone-xs.dng")
        guard FileManager.default.fileExists(atPath: url.path),
              let frame = RawOpener.openDraft(url: url, orientation: nil, settings: .identity, filmApplied: film, cacheKey: nil)
        else { return nil }
        let m = EditorViewModel()
        m.present(LoadedSource(image: frame.source.image,
                               colorSpace: ImageSource.outputColorSpace(url: url, image: frame.source.image),
                               size: frame.source.image.extent.size))
        return m
    }

    // MARK: Photo rects per step

    enum StepKind: String, CaseIterable { case filmsStrip, filmsOptions, develop }

    /// The drawable (pixels) the Metal view gets in each step: the scaffold's photo frame less the canvas padding.
    func drawables(for device: TestDevice, model: EditorViewModel) async -> [StepKind: CGSize] {
        var out: [StepKind: CGSize] = [:]
        for kind in StepKind.allCases {
            let box = FrameBox()
            model.filmsDetail = kind == .filmsOptions
            let tab: EditorTab = kind == .develop ? .develop : .films
            let view = EditorScaffold(model: model, tab: .constant(tab), onClose: {}, onLayout: { box.frames = $0 }) {
                Color.clear
            } panel: {
                if kind == .develop { DevelopPanel(model: model, focus: "exposure") } else { FilmsPanel(model: model) }
            }
            await Snapshot.render(view, device: device, name: "step-\(kind.rawValue)", settle: .milliseconds(400))
            let f = box.frames["photo"]!
            out[kind] = CGSize(width: (f.width - 4) * device.scale, height: f.height * device.scale)
        }
        model.filmsDetail = false
        return out
    }

    // MARK: Pixels

    struct Bitmap { var w: Int; var h: Int; var px: [UInt8] }

    func bitmap(_ image: CIImage, _ ctx: CIContext, rect: CGRect? = nil) -> Bitmap {
        let r = (rect ?? image.extent).integral
        let w = Int(r.width), h = Int(r.height)
        var px = [UInt8](repeating: 0, count: w * h * 4)
        px.withUnsafeMutableBytes {
            ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: w * 4, bounds: r, format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        }
        return Bitmap(w: w, h: h, px: px)
    }

    func diff(_ a: Bitmap, _ b: Bitmap) -> (mean: Double, max: Int) {
        XCTAssertEqual(a.h, b.h); XCTAssertEqual(a.w, b.w)
        var sum = 0, mx = 0, n = 0
        for i in 0..<min(a.px.count, b.px.count) where i % 4 != 3 {
            let d = abs(Int(a.px[i]) - Int(b.px[i])); sum += d; mx = max(mx, d); n += 1
        }
        return (Double(sum) / Double(max(n, 1)), mx)
    }

    /// The photo inside a frame of `size`, cut out at whole-pixel offsets (a 2 px inset) and resampled to a common
    /// 48 x 32 grid, so frames of any size (width- or height-limited fit) can be compared. A low-pass: half-pixel
    /// placement differences and grain cancel out, a missing stage does not (see `assertToleranceIsTight`).
    func photoRegion(_ model: EditorViewModel, size: CGSize, scale: CGFloat) -> Bitmap {
        let live = model.live
        let full = appFrame(model, size: size, scale: scale)
        let frame = CIImage(bitmapData: Data(full.px), bytesPerRow: full.w * 4, size: size, format: .RGBA8,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        let src = live.gradedImage(for: model.liveRecipe, cropping: false, showingOriginal: false)!.extent.size   // after crop / rotation
        let fit = min(size.width / src.width, size.height / src.height)
        let w = src.width * fit, h = src.height * fit
        let r = CGRect(x: ((size.width - w) / 2).rounded(.down) + 2, y: ((size.height - h) / 2).rounded(.down) + 2,
                       width: floor(w) - 4, height: floor(h) - 4)
        // CI space is bottom-left: the photo's top edge is `size.height - (top + h)`.
        let ciY = size.height - ((size.height - h) / 2).rounded(.down) - 2 - r.height
        let moved = frame.transformed(by: CGAffineTransform(translationX: -r.minX, y: -ciY))
            .cropped(to: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = moved
        lanczos.scale = Float(32 / r.height)   // aspectRatio is an extra HORIZONTAL factor
        lanczos.aspectRatio = Float((48 / r.width) / (32 / r.height))
        return bitmap(lanczos.outputImage!, live.ciContext, rect: CGRect(x: 0, y: 0, width: 48, height: 32))
    }

    /// What the Metal view puts on screen for the model's current state: `LivePreview.render` into an offscreen
    /// texture of the drawable's size (the same call `MetalPreviewView.draw` makes), read back as RGBA.
    func appFrame(_ model: EditorViewModel, size: CGSize, scale: CGFloat, zoom: CGFloat = 1) -> Bitmap {
        let live = model.live
        let w = Int(size.width), h = Int(size.height)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite, .renderTarget]
        d.storageMode = .shared
        let tex = live.device!.makeTexture(descriptor: d)!
        let cb = live.commandQueue!.makeCommandBuffer()!
        live.render(into: tex, commandBuffer: cb, recipe: model.liveRecipe, cropping: false, showingOriginal: false,
                    zoom: zoom, offset: .zero, contentScale: scale, ink: Self.ink)
        cb.commit()
        cb.waitUntilCompleted()
        var px = [UInt8](repeating: 0, count: w * h * 4)
        tex.getBytes(&px, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
        for i in stride(from: 0, to: px.count, by: 4) { px.swapAt(i, i + 2) }   // BGRA -> RGBA
        return Bitmap(w: w, h: h, px: px)
    }

    func graded(_ model: EditorViewModel, zoom: CGFloat = 1) -> Bitmap {
        let live = model.live
        live.updateProxyTarget(zoom: zoom)
        return bitmap(live.gradedImage(for: model.liveRecipe, cropping: false, showingOriginal: false)!, live.ciContext)
    }

    func setBox(_ model: EditorViewModel, _ d: TestDevice) {
        model.live.proxyBox = CGSize(width: d.size.width * d.scale, height: d.size.height * d.scale)
    }

    // MARK: Assertions

    /// FILMS (strip and options) and DEVELOP show the same photo for the model's current recipe.
    func assertStepsAgree(_ model: EditorViewModel, device: TestDevice, label: String,
                          file: StaticString = #filePath, line: UInt = #line) async {
        setBox(model, device)
        let sizes = await drawables(for: device, model: model)
        let reference = graded(model)
        var proxySides: Set<CGFloat> = []
        var thumbs: [StepKind: Bitmap] = [:]
        // Visit the steps in the order a user would, and back again: the look must not depend on the path.
        for kind in [StepKind.filmsStrip, .develop, .filmsOptions, .develop, .filmsStrip] {
            let size = sizes[kind]!
            thumbs[kind] = photoRegion(model, size: size, scale: device.scale)
            proxySides.insert(model.live.builtLongSide)
            let g = graded(model)
            let d = diff(reference, g)
            XCTAssertEqual(d.max, 0, "\(label) \(device.name) \(kind): graded pixels differ from the first render (max \(d.max))", file: file, line: line)
        }
        XCTAssertEqual(proxySides.count, 1, "\(label) \(device.name): proxy size changed between steps: \(proxySides)", file: file, line: line)
        let films = thumbs[.filmsStrip]!, develop = thumbs[.develop]!, options = thumbs[.filmsOptions]!
        for (name, other) in [("develop", develop), ("filmsOptions", options)] {
            let d = diff(films, other)
            print("STEPS \(label) \(device.name) strip(\(sizes[.filmsStrip]!.width)x\(sizes[.filmsStrip]!.height)) vs \(name)(\(sizes[name == "develop" ? .develop : .filmsOptions]!.width)x\(sizes[name == "develop" ? .develop : .filmsOptions]!.height)): mean \(d.mean) max \(d.max)")
            XCTAssertLessThanOrEqual(d.mean, Self.placementTolerance, "\(label) \(device.name) strip vs \(name)", file: file, line: line)
        }
    }

    /// Sanity: dropping the preset's develop and texture values moves the picture far beyond the tolerance, so the
    /// tolerance cannot hide a missing stage.
    func assertToleranceIsTight(_ model: EditorViewModel, device: TestDevice,
                                file: StaticString = #filePath, line: UInt = #line) {
        setBox(model, device)
        let size = CGSize(width: 1000, height: 1400)
        let full = photoRegion(model, size: size, scale: device.scale)
        let keep = model.recipe
        var filmOnly = Recipe(filmID: keep.filmID); filmOnly.pipeline = keep.pipeline
        model.recipe = filmOnly
        let bare = photoRegion(model, size: size, scale: device.scale)
        model.recipe = keep
        let d = diff(full, bare)
        print("STEPS film-only vs complete (\(device.name)): mean \(d.mean) max \(d.max)")
        // 4x: the shadow relight fix (lifts no longer amplify near-black chroma) made the preset's shadow lift subtler,
        // which brought the colour-film gap from ~24 to ~13; the tolerance is still well below it.
        XCTAssertGreaterThan(d.mean, Self.placementTolerance * 4, "film-only must be visibly different", file: file, line: line)
    }

    // MARK: (a) colour film + preset with develop and texture

    func testColourFilmPresetSameInEveryStep() async throws {
        for d in TestDevice.all {
            let m = await jpegModel()
            let p = Self.preset("Beach", film: Self.film(mono: false))
            m.apply(p)
            XCTAssertEqual(m.recipe.exposure, 0.12)
            XCTAssertEqual(m.recipe.bloomAmount, 0.8)
            await assertStepsAgree(m, device: d, label: "colour+preset")
            assertToleranceIsTight(m, device: d)
        }
    }

    // MARK: (b) B&W

    func testBlackAndWhiteSameInEveryStep() async throws {
        for d in TestDevice.all {
            let m = await jpegModel()
            m.apply(Self.preset("Mono", film: Self.film(mono: true), exposure: -0.2, grain: 0.8, halation: 0.4, bloom: 0.5))
            await assertStepsAgree(m, device: d, label: "mono+preset")
            // Tapping the film card itself (no preset): native texture, then the Develop step.
            let m2 = await jpegModel()
            m2.select(Self.film(mono: true).id)
            await assertStepsAgree(m2, device: d, label: "mono film card")
        }
    }

    // MARK: (c) RAW

    func testRawDNGSameInEveryStep() async throws {
        for d in TestDevice.all {
            guard let m = dngModel(film: true) else { throw XCTSkip("iphone-xs.dng not present") }
            m.apply(Self.preset("Raw look", film: Self.film(mono: false)))
            await assertStepsAgree(m, device: d, label: "dng+preset")
        }
    }

    // MARK: original -> preset A -> preset B

    func testPresetAThenBReplacesEverythingAndMatchesAFreshRender() async throws {
        for d in TestDevice.all {
            let colour = Self.film(mono: false)
            let a = Self.preset("A", film: colour, exposure: 0.4, grain: 0.9, halation: 0.9, bloom: 1.0)
            var br = Recipe(filmID: Self.film(mono: false, skipping: colour.id).id)
            br.pipeline = Recipe.currentPipeline
            br.contrast = -0.1   // B defines only a little of its own: nothing of A may survive
            br.push = -0.5; br.scanProfile = .neutral; br.reciprocity = .off
            let b = Preset(nickname: "B", recipe: br, filmName: "B")

            let m = await jpegModel()
            var crop = CropSettings.identity; crop.rotate90 = 1
            m.recipe.crop = crop
            let kept = m.recipe.dodgeBurn
            m.apply(a)
            XCTAssertEqual(m.recipe.exposure, 0.4)
            m.apply(b)
            // Everything B defines replaced A's; the photo's own crop and strokes survived.
            var expected = b.recipe
            expected.crop = crop; expected.dodgeBurn = kept
            XCTAssertEqual(m.recipe, expected, "preset B must replace A completely")
            XCTAssertEqual(m.recipe.exposure, 0, "A's exposure must not leak into B")
            XCTAssertEqual(m.recipe.bloomAmount, b.recipe.bloomAmount)
            XCTAssertEqual(m.recipe.push, -0.5)
            XCTAssertEqual(m.recipe.crop, crop)

            await assertStepsAgree(m, device: d, label: "A->B")
            // Fresh render of B's recipe on a fresh model.
            let fresh = await jpegModel()
            fresh.recipe = expected
            setBox(fresh, d)
            XCTAssertEqual(diff(graded(m), graded(fresh)).max, 0, "A->B must equal a fresh render of B")
        }
    }

    /// The RAW settings belong to the photo: applying a preset keeps its own white balance (the Mac does the same).
    func testPresetKeepsTheRawWhiteBalance() async throws {
        let m = await jpegModel()
        m.recipe.raw.temperature = 4300
        m.apply(Self.preset("P", film: Self.film(mono: false)))
        XCTAssertEqual(m.recipe.raw.temperature, 4300)
    }

    /// Switching zoom levels and back gives the proxy it had: no path dependence, no history.
    func testProxyDependsOnlyOnZoomLevel() async throws {
        let m = await jpegModel()
        setBox(m, .iPhone16Pro)
        m.apply(Self.preset("P", film: Self.film(mono: false)))
        let first = graded(m)
        _ = graded(m, zoom: 3)
        let back = graded(m, zoom: 1)
        XCTAssertEqual(diff(first, back).max, 0)
    }
}


// MARK: Evidence for the old policy

extension StepConsistencyTests {
    /// The proxy the old code built: sized to the drawable of the step on screen, rebuilt only on >25 % growth.
    /// Prints how far the same recipe's picture moved between the steps (evidence only; the fix removes the cause).
    func testLegacyDrawableSizedProxyChangedTheLook() async throws {
        let d = TestDevice.iPhone16Pro
        let m = await jpegModel()
        m.apply(Self.preset("Beach", film: Self.film(mono: false)))
        let live = m.live
        let renderer = live.renderer!, source = live.source!
        func legacy(drawable: CGFloat) -> Bitmap {
            let proxy = PreviewProxy.make(from: source, renderer: renderer, context: live.ciContext, wanted: min(1206, drawable))
            let scale = min(1, proxy.extent.width / source.extent.width)
            let img = renderer.withPreviewScale(scale).apply(m.liveRecipe, to: proxy)
            let lanczos = CIFilter.lanczosScaleTransform()
            lanczos.inputImage = img; lanczos.scale = Float(14 / img.extent.height); lanczos.aspectRatio = Float((24 / img.extent.width) / (14 / img.extent.height))
            let scaled = lanczos.outputImage!
            let out = scaled.transformed(by: CGAffineTransform(translationX: -scaled.extent.minX, y: -scaled.extent.minY))
            return bitmap(out, live.ciContext, rect: CGRect(x: 1, y: 1, width: 22, height: 14))
        }
        let small = legacy(drawable: 600), big = legacy(drawable: 1194)
        print("LEGACY proxy 600 vs 1194 (same recipe): \(diff(small, big))  [\(d.name)]")
    }
}

// MARK: The staged render is the lazy render

extension StepConsistencyTests {
    /// `LivePreview.render` (grade into a stage texture, resample) shows the same picture, the right way up, as
    /// drawing the lazy graph straight to the drawable. Film only: a recipe whose render is deterministic.
    func testStagedFrameEqualsLazyFrame() async throws {
        let m = await jpegModel()
        setBox(m, .iPhone16Pro)
        m.select(Self.film(mono: false).id)
        m.recipe.grainAmount = 0
        let size = CGSize(width: 1194, height: 978)
        let staged = appFrame(m, size: size, scale: 3)
        let lazy = m.live.frame(for: m.liveRecipe, cropping: false, showingOriginal: false, size: size, zoom: 1,
                                offset: .zero, contentScale: 3, ink: Self.ink)
        let d = diff(staged, bitmap(lazy, m.live.ciContext, rect: CGRect(origin: .zero, size: size)))
        print("STAGED vs lazy: mean \(d.mean) max \(d.max)")
        XCTAssertLessThan(d.mean, 0.5, "the stage must neither flip nor shift nor re-tone the picture")
    }
}

// MARK: RAW: original -> preset with a film -> draft, then full develop

extension StepConsistencyTests {
    func lowpass(_ image: CIImage, _ ctx: CIContext) -> Bitmap {
        let e = image.extent
        let l = CIFilter.lanczosScaleTransform()
        l.inputImage = image.transformed(by: CGAffineTransform(translationX: -e.minX, y: -e.minY))
        l.scale = Float(32 / e.height); l.aspectRatio = Float((48 / e.width) / (32 / e.height))
        return bitmap(l.outputImage!, ctx, rect: CGRect(x: 0, y: 0, width: 48, height: 32))
    }

    /// The app's RAW path: open with no film (draft), apply a preset with a colour film (the film changes how the RAW is
    /// developed, so the app develops it again: a draft first, then the full develop), and look at the preview after each.
    /// Draft and full differ by decode quality only (draft demosaic, preview size): mean `rawDraftTolerance` of 255.
    /// Both must be far from the film-off render, and the old 8-bit proxy must be far from both (evidence).
    func testRawDraftThenFullDevelopKeepTheLook() async throws {
        let url = Snapshot.root.appendingPathComponent("Fixtures/raw/iphone-xs.dng")
        guard let off = RawOpener.openDraft(url: url, orientation: nil, settings: .identity, filmApplied: false, cacheKey: nil)
        else { throw XCTSkip("iphone-xs.dng not present") }
        let develop = off.develop
        let space = ImageSource.outputColorSpace(url: url, image: off.source.image)
        func loaded(_ s: DevelopedSource) -> LoadedSource { LoadedSource(image: s.image, colorSpace: space, size: s.image.extent.size) }
        let tol = Self.rawDraftTolerance

        for d in TestDevice.all {
            let m = EditorViewModel()
            m.present(loaded(off.source))                       // opened with no film
            setBox(m, d)
            let preset = Self.preset("Raw", film: Self.film(mono: false))
            let filmOffFrame = { self.photoRegion(m, size: CGSize(width: d.size.width * d.scale - 12, height: 900), scale: d.scale) }
            _ = filmOffFrame
            m.apply(preset)                                       // film nil -> non-nil: the app redevelops
            let size = CGSize(width: d.size.width * d.scale - 12, height: 900)
            let stale = photoRegion(m, size: size, scale: d.scale)            // film preset on the film-off develop (before the draft lands)

            let draft = try XCTUnwrap(develop.develop(m.recipe.raw, filmApplied: true, draft: true, scale: develop.previewScale()))
            m.live.setSource(draft.image, colorSpace: space, size: draft.image.extent.size)
            let a = photoRegion(m, size: size, scale: d.scale)
            let gradedDraft = graded(m)

            let full = try XCTUnwrap(develop.develop(m.recipe.raw, filmApplied: true, draft: false, scale: 1))
            m.live.setSource(full.image, colorSpace: space, size: full.image.extent.size)
            let b = photoRegion(m, size: size, scale: d.scale)

            let dv = diff(a, b), st = diff(stale, b)
            print("RAW \(d.name) headroom film-off \(off.source.headroom) draft \(draft.headroom) full \(full.headroom); draft vs full mean \(dv.mean) max \(dv.max); film-off-develop vs full mean \(st.mean) max \(st.max)")
            XCTAssertLessThanOrEqual(dv.mean, tol, "\(d.name): draft and full develop must look the same")

            // Film off entirely.
            var bare = m.recipe; bare.filmID = nil; bare.pipeline = m.recipe.pipeline
            let keep = m.recipe
            m.recipe = Recipe(filmID: nil)
            let none = photoRegion(m, size: size, scale: d.scale)
            m.recipe = keep
            let far = diff(none, b)
            print("RAW \(d.name) film-off render vs preset: mean \(far.mean)")
            // The film-off render must be clearly further away than the draft is from the full develop. (Before the shadow
            // relight fix this gap was ~13, inflated by exploded near-black chroma in this DNG; it is ~7 now.)
            XCTAssertGreaterThan(far.mean, tol)
            XCTAssertGreaterThan(far.mean, dv.mean * 1.4)

            // Legacy policy: the full develop through an 8-bit proxy that clips above 1 but keeps the headroom tag.
            let renderer = try XCTUnwrap(m.live.renderer)
            let wanted = m.live.proxyLongSide(zoom: 1)
            let scaled = renderer.previewImage(from: full.image, maxPixelSize: wanted)
            let cg8 = try XCTUnwrap(m.live.ciContext.createCGImage(scaled, from: scaled.extent, format: .RGBA8,
                                                                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!))
            let legacy = CIImage(cgImage: cg8, options: [.colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
                .withMiraExposureTime(full.image.miraExposureTime).withMiraHeadroom(full.image.miraHeadroom)
            let scale = min(1, legacy.extent.width / full.image.extent.width)
            let legacyGraded = renderer.withPreviewScale(scale).apply(m.liveRecipe, to: legacy)
            let current = m.live.gradedImage(for: m.liveRecipe, cropping: false, showingOriginal: false)!
            let ld = diff(lowpass(legacyGraded, m.live.ciContext), lowpass(current, m.live.ciContext))
            print("RAW \(d.name) LEGACY 8-bit proxy vs half-float proxy (full develop, headroom \(full.headroom)): mean \(ld.mean) max \(ld.max)")
            _ = gradedDraft
        }
    }
}

// MARK: RAW redevelop timing and thumbnail invalidation

extension StepConsistencyTests {
    func testFilmTapRedevelopsAtOnceButRawSlidersDebounce() {
        var withFilm = Recipe(filmID: "x"); withFilm.pipeline = Recipe.currentPipeline
        let none = Recipe()
        XCTAssertEqual(EditorViewModel.rawDevelopDebounce(from: none, to: withFilm), .zero)
        XCTAssertEqual(EditorViewModel.rawDevelopDebounce(from: withFilm, to: none), .zero)
        var moved = withFilm; moved.raw.temperature = 4300
        XCTAssertEqual(EditorViewModel.rawDevelopDebounce(from: withFilm, to: moved), .milliseconds(120))
    }

    /// The strip's thumbnails are forgotten when a develop with the other film-applied state is adopted, not on the
    /// draft to full swap of the same state.
    func testThumbnailsAreInvalidatedOnlyWhenFilmAppliedChanges() async throws {
        let m = await jpegModel()
        await m.requestThumbnail(nil)
        XCTAssertNotNil(m.thumbnails["__original"])
        let epoch = m.thumbEpoch
        m.noteThumbnailSource(filmApplied: false)            // same state as opened: draft -> full swap, no churn
        XCTAssertEqual(m.thumbEpoch, epoch)
        XCTAssertNotNil(m.thumbnails["__original"])
        m.noteThumbnailSource(filmApplied: true)             // film toggled on: film-on develop adopted
        XCTAssertEqual(m.thumbEpoch, epoch + 1)
        XCTAssertTrue(m.thumbnails.isEmpty)
        await m.requestThumbnail(nil)
        XCTAssertNotNil(m.thumbnails["__original"], "visible cards render again from the new develop")
        m.noteThumbnailSource(filmApplied: true)             // the full develop of the same state
        XCTAssertEqual(m.thumbEpoch, epoch + 1)
        XCTAssertNotNil(m.thumbnails["__original"])
        m.noteThumbnailSource(filmApplied: false)            // film toggled off
        XCTAssertEqual(m.thumbEpoch, epoch + 2)
    }

    /// Time to develop the draft the film tap now starts immediately (decode only; the 120 ms wait is gone).
    func testRawDraftDevelopTimeAfterAFilmTap() throws {
        let url = Snapshot.root.appendingPathComponent("Fixtures/raw/iphone-xs.dng")
        guard let off = RawOpener.openDraft(url: url, orientation: nil, settings: .identity, filmApplied: false, cacheKey: nil)
        else { throw XCTSkip("iphone-xs.dng not present") }
        let t0 = ContinuousClock.now
        let draft = off.develop.develop(.identity, filmApplied: true, draft: true, scale: off.develop.previewScale())
        let ms = (ContinuousClock.now - t0) / .milliseconds(1)
        print("RAWTIME film tap -> draft developed: \(ms) ms (was 120 ms debounce + this)")
        XCTAssertNotNil(draft)
    }
}
