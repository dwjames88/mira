import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

public enum RendererError: Error, CustomStringConvertible {
    case cannotLoad(URL)
    case renderFailed
    case cannotWrite(URL)

    public var description: String {
        switch self {
        case .cannotLoad(let u): "Could not load image at \(u.path)"
        case .renderFailed: "Rendering failed"
        case .cannotWrite(let u): "Could not write image to \(u.path)"
        }
    }
}

/// Builds the film look as a pure CIFilter graph (plus two small Metal kernels for curves and the colour mixer).
///
/// Colour management: the shared context works in extended *linear* sRGB. Film LUTs are
/// authored on sRGB-encoded values, so the cube is applied with
/// `CIColorCubeWithColorSpace` and `colorSpace = sRGB`: Core Image converts working-space
/// pixels into gamma-encoded sRGB, looks them up in the cube, then converts the result back.
/// No manual tone-curve conversion is needed for the LUT. Contrast, saturation and grain are
/// also done on sRGB-encoded values (wrapped in explicit tone curves) so they behave
/// perceptually; exposure, white balance, halation and bloom stay in linear light.
///
/// All spatial parameters are multiplied by `scale = min(width, height) / 1000`, so the look
/// is the same at any resolution.
///
/// Two pipelines, chosen by `Recipe.pipeline` (a saved edit keeps its pipeline so it reopens the same):
///
/// Pipeline 1 (legacy, every recipe saved before 0.5): crop, exposure (`CIExposureAdjust`), dodge and
/// burn, colour mixer, curves, film LUT (blended by strength), contrast, tone, texture, clarity,
/// saturation, vibrance, warmth / tint, a screen-blended halation, bloom, soft-light white-noise
/// grain, vignette, mask overlay, border. Its output must not change.
///
/// Pipeline 2 (film science, see `FilmCharacter` for the physics): the order follows the light.
///  1. Exposure with latitude (`miraFilmExposure`): a gain in linear light whose highlights roll off
///     like a negative's shoulder, by the film's latitude, instead of clipping.
///     A scene-referred source (RAW with extended range) carries a headroom H > 1: the white point
///     gain x H then maps to 1 through a shoulder with a knee at 0.6, instead of clipping at the LUT.
///  2. White balance (warmth / tint): the light the film is exposed to, so before the film.
///  2b. Reciprocity (`miraReciprocity`): the film's response to the exposure time (cast, contrast).
///  3. Dodge and burn, colour mixer, curves (unchanged).
///  4. Halation, in the exposure and in linear light: the highlights (`miraHighlights`) are blurred
///     by the film's radius and put back tinted (`miraHalationCombine`), so luminance is
///     redistributed, not added. The slider scales the film's own halation (0.5 is native).
///  5. Film LUT with strength blend (the Hald CLUTs are sRGB display referred).
///  6. Contrast, tone, texture, clarity, saturation, vibrance: printing and scanning, after the film.
///     Between the LUT and contrast: Paper (a print look cube, not for monochrome films) or the
///     scan profile, with push / pull contrast and base fog (`miraScan`), then toning of
///     monochrome films (`miraToning`). Push / pull also changes the
///     exposure gain (2^(0.33 N)), slide / Kodachrome latitude, and the grain strength.
///  7. Bloom.
///  8. Grain (`miraGrain`): band-limited smooth noise on the sRGB-encoded image, in frame-relative
///     coordinates (so a downscaled export and a preview agree), chroma and density dependent by film.
///  9. Vignette, mask overlay, border.
/// Dodge and burn runs in step 3, long before the grain: strokes are painted light on the negative
/// and carry the grain with them.
public struct Renderer: Sendable {
    public let library: FilmLibrary
    /// Rasterised dodge and burn masks, shared by every copy of this renderer.
    let maskCache = DodgeBurnMaskCache()

    public init(library: FilmLibrary) {
        self.library = library
    }

    // MARK: Context

    /// The one Core Image context for the whole process: previews, thumbnails, hover renders and
    /// export all share it, so its shaders, caches and Metal queue are warm. `CIContext` is thread safe.
    public static let sharedContext: CIContext = makeContext()

    /// Builds a new context (tests and benchmarks that need a specific configuration).
    public static func makeContext(cacheIntermediates: Bool = false) -> CIContext {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: NSNumber(value: CIFormat.RGBAh.rawValue),
            .cacheIntermediates: cacheIntermediates,
            .name: "Mira",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }

    // MARK: Graph

    /// `sourceHeadroom` is the largest linear value the source holds (1 for SDR; a RAW developed with
    /// extended range reports its measured peak). nil reads the headroom a developed source carries
    /// (`CIImage.miraHeadroom`, set by `ImageSource.developedSource`), else 1.
    ///
    /// `sourceExposureTime` is the photo's EXIF exposure time in seconds, for the reciprocity stage; nil reads the
    /// tag a loaded source carries (`CIImage.miraExposureTime`). `recipe.exposureTime` overrides both.
    public func apply(_ recipe: Recipe, to source: CIImage, sourceHeadroom: CGFloat? = nil,
                      sourceExposureTime: Double? = nil) -> CIImage {
        // 0. Crop, rotation, flips and straighten first, so every stage below (and the
        // resolution-independent `scale`) sees the cropped output.
        grade(recipe, cropped: CropGeometry.apply(recipe.crop, to: source), sourceSize: source.extent.size,
              sourceHeadroom: sourceHeadroom ?? source.miraHeadroom,
              sourceExposureTime: sourceExposureTime ?? source.miraExposureTime)
    }

    /// Everything after the crop: film, tone, colour, halation, bloom, grain, vignette and border.
    /// `input` is already cropped (its crop is `recipe.crop`, applied by the caller). All spatial
    /// parameters follow the size of `input`, so the look is the same at any resolution.
    ///
    /// `sourceSize` is the size of the uncropped, upright source the crop was applied to; dodge and
    /// burn strokes need it to find their place (nil is fine for an uncropped `input`). `maskRegion`
    /// limits the dodge and burn masks to the part of `input` (Core Image pixels) about to be
    /// rendered, which keeps a zoomed-in render of a huge picture cheap.
    ///
    /// `maskOverlay` paints the dodge and burn masks as a translucent red wash over the result (the
    /// editor's mask view); it is never part of an export.
    ///
    /// `sourceHeadroom` (default 1, SDR) is the largest linear value `input` holds. Above 1 the
    /// exposure stage maps the white point (gain x headroom) to 1 through the film's shoulder
    /// instead of clipping at the LUT (pipeline 2 only; see `miraFilmExposure`).
    ///
    /// `sourceExposureTime` (seconds, nil = unknown) feeds the reciprocity stage (pipeline 2, with a film):
    /// the effective time is `recipe.exposureTime ?? sourceExposureTime`; with none the stage is off.
    public func grade(_ recipe: Recipe, cropped input: CIImage, sourceSize: CGSize? = nil,
                      maskRegion: CGRect? = nil, maskOverlay: Bool = false,
                      sourceHeadroom: CGFloat = 1, sourceExposureTime: Double? = nil) -> CIImage {
        let extent = input.extent
        guard !extent.isInfinite, !extent.isEmpty else { return input }
        let scale = min(extent.width, extent.height) / 1000
        var image = input
        let filmScience = recipe.pipeline >= 2
        let film = recipe.filmID.flatMap { library.film(id: $0) }
        let character = film?.resolvedCharacter ?? .generic
        let diagonal = hypot(extent.width, extent.height)
        // Push / pull (pipeline 2): stops of push development, -2 ... 2.
        let push = filmScience ? clamp(recipe.push, -2, 2) : 0
        let family = film?.family
        // Reciprocity (pipeline 2, with a film): nil when off, no usable time, or no effect at that time.
        let reciprocityEffect = Reciprocity.effect(for: recipe, film: film, sourceExposureTime: sourceExposureTime)

        // 1. Exposure. Pipeline 2: a gain in linear light with the film's highlight latitude, then
        // white balance (the light the film is exposed to).
        if filmScience {
            let headroom = Double(min(max(sourceHeadroom, 1), 8))
            if abs(recipe.exposure) > eps || abs(push) > eps || headroom > 1 {
                // Pushing develops for more density (a gain of 2^(0.33 N) before the film); slide
                // and Kodachrome lose latitude (clip harder) when pushed.
                var latitude = character.latitude
                if film == nil { latitude = 0 }
                if push > 0, family == .slide || family == .kodachrome { latitude *= max(0, 1 - 0.3 * push) }
                image = GradeKernels.applyFilmExposure(gain: exp2(clamp(recipe.exposure, -2, 2) + 0.33 * push),
                                                       latitude: latitude, headroom: headroom, to: image)
            }
            image = whiteBalance(image, recipe)
            // 1a'. Reciprocity failure of the exposure time, in the same scene-referred linear light.
            if let reciprocityEffect {
                let darkening = recipe.reciprocity == .uncompensated ? -reciprocityEffect.lossStops : 0
                let gain = (r: exp2(darkening + reciprocityEffect.cast.r), g: exp2(darkening + reciprocityEffect.cast.g),
                            b: exp2(darkening + reciprocityEffect.cast.b))
                let contrast = reciprocityEffect.contrastGain
                if abs(gain.r - 1) > 1e-5 || abs(gain.g - 1) > 1e-5 || abs(gain.b - 1) > 1e-5 || abs(contrast - 1) > 1e-5 {
                    image = GradeKernels.applyReciprocity(gain: gain, contrast: abs(contrast - 1) > 1e-5 ? contrast : 1,
                                                          to: image)
                }
            }
        } else if abs(recipe.exposure) > eps {
            let f = CIFilter.exposureAdjust()
            f.inputImage = image
            f.ev = Float(clamp(recipe.exposure, -2, 2))
            image = f.outputImage ?? image
        }

        // 1a. Dodge and burn, right after exposure: painted light, before the colour and film stages,
        // so the film responds to it like a print made from a dodged and burned negative.
        if recipe.dodgeBurn.hasVisibleEffect,
           let source = sourceSize ?? (recipe.crop.isIdentity ? extent.size : nil) {
            image = applyDodgeBurn(recipe.dodgeBurn, to: image, crop: recipe.crop, sourceSize: source,
                                   region: maskRegion)
        }

        // 1b. Colour mixer, then curves: the user's own colour and tone corrections, applied
        // before the film look so the film sits on top of them. Skipped when they do nothing.
        if !recipe.colorMixer.isIdentity {
            image = GradeKernels.applyColorMixer(recipe.colorMixer, to: image)
        }
        if !recipe.curves.isIdentity {
            image = GradeKernels.applyCurves(recipe.curves, to: image)
        }

        // 1c. Pipeline 2 halation: in the exposure, before the film, in linear light.
        if filmScience {
            var amount = recipe.halationAmount * 2 * character.halationStrength * 0.5
            var haloCharacter = character
            if character.remJet {
                // Rem-jet backing absorbs most halation; with it removed the film bleeds red.
                if recipe.remJetRemoved {
                    amount *= 2.5
                    haloCharacter.halationTint = [1.0, 0.15, 0.03]
                } else {
                    amount *= 0.15
                }
            }
            amount = clamp(amount, 0, 0.9)
            if amount > 1e-4 {
                image = filmHalation(image, extent: extent, amount: amount, character: haloCharacter,
                                     radiusSlider: clamp(recipe.halationRadius, 0, 1), diagonal: diagonal)
            }
        }

        // 2. Film LUT, blended with the pre-LUT image by strength
        if let film, let lut = try? library.lut(for: film) {
            let strength = clamp(recipe.strength, 0, 1)
            if strength > eps {
                let graded = filmScience
                    ? (GradeKernels.applyLUT3D(lut, cacheKey: "film:\(film.id)", to: image) ?? legacyCube(lut, image))
                    : legacyCube(lut, image)
                if let graded {
                    if strength < 1 - eps {
                        let mix = CIFilter.dissolveTransition()
                        mix.inputImage = image
                        mix.targetImage = graded
                        mix.time = Float(strength)
                        image = (mix.outputImage ?? graded).cropped(to: extent)
                    } else {
                        image = graded
                    }
                }
            }
        }

        // 2b. Pipeline 2: print stock (replaces the scan), push / pull contrast and base fog, then B&W toning.
        if filmScience {
            // A black-and-white negative is printed on black-and-white paper (Toning covers that): a
            // colour print stock would tint it, so the paper is ignored for monochrome films.
            let paper: PaperProfile = film?.isMonochrome == true ? .none : recipe.paper
            if let paperID = ProceduralLooks.id(for: paper), let paperLUT = try? ProceduralLooks.lut(paperID) {
                image = applyPaper(paperLUT, id: paperID, to: image, strength: clamp(recipe.strength, 0, 1), extent: extent)
            }
            // With a paper set the scan profile is ignored; push / pull contrast and base fog still apply.
            var scan = ScanParameters.profile(paper == .none ? recipe.scanProfile : .neutral)
            scan.contrast += push * character.pushContrastPerStop
            if push > 0, let family, family == .colorNegative || family == .motionPicture || family == .blackAndWhite {
                scan.blackLift += 0.012 * push
            }
            if !scan.isIdentity {
                image = fromGamma(GradeKernels.applyScan(scan, to: toGamma(image))).cropped(to: extent)
            }
            if film?.isMonochrome == true, recipe.toning != .none {
                image = fromGamma(GradeKernels.applyToning(recipe.toning, amount: clamp(recipe.toningStrength, 0, 1),
                                                           to: toGamma(image))).cropped(to: extent)
            }
        }

        // 3. Contrast, then the tone stage (highlights, shadows, whites, blacks), then texture and
        // clarity, then saturation and vibrance (in sRGB-encoded space where it matters). With none
        // of the tone, texture or clarity values set, contrast and saturation share one pass exactly
        // as before.
        let toneActive = abs(recipe.highlights) > eps || abs(recipe.shadows) > eps
            || abs(recipe.whites) > eps || abs(recipe.blacks) > eps
        let detailActive = abs(recipe.texture) > eps || abs(recipe.clarity) > eps
        let separate = toneActive || detailActive
        if abs(recipe.contrast) > eps || (!separate && abs(recipe.saturation) > eps) {
            let encoded = toGamma(image)
            let f = CIFilter.colorControls()
            f.inputImage = encoded
            f.contrast = Float(1 + 0.5 * clamp(recipe.contrast, -1, 1))
            f.saturation = separate ? 1 : Float(1 + clamp(recipe.saturation, -1, 1))
            f.brightness = 0
            image = fromGamma(f.outputImage ?? encoded)
        }
        if toneActive {
            let local = abs(recipe.highlights) > eps || abs(recipe.shadows) > eps
            let base = local ? Self.softBlur(image, extent: extent, sigma: 30 * scale) : image
            image = GradeKernels.applyTone(highlights: recipe.highlights, shadows: recipe.shadows,
                                           whites: recipe.whites, blacks: recipe.blacks, to: image, base: base)
        }
        if abs(recipe.texture) > eps {
            let blurred = Self.softBlur(image, extent: extent, sigma: 2.5 * scale)
            image = GradeKernels.applyDetail(amount: clamp(recipe.texture, -1, 1) * 1.2, midtoneWeighted: false,
                                             to: image, blurred: blurred)
        }
        if abs(recipe.clarity) > eps {
            let blurred = Self.softBlur(image, extent: extent, sigma: 20 * scale)
            image = GradeKernels.applyDetail(amount: clamp(recipe.clarity, -1, 1) * 1.0, midtoneWeighted: true,
                                             to: image, blurred: blurred)
        }
        if separate && abs(recipe.saturation) > eps {
            let encoded = toGamma(image)
            let f = CIFilter.colorControls()
            f.inputImage = encoded
            f.saturation = Float(1 + clamp(recipe.saturation, -1, 1))
            image = fromGamma(f.outputImage ?? encoded)
        }
        if abs(recipe.vibrance) > eps {
            let encoded = toGamma(image)
            let f = CIFilter.vibrance()
            f.inputImage = encoded
            f.amount = Float(clamp(recipe.vibrance, -1, 1))
            image = fromGamma(f.outputImage ?? encoded)
        }

        // 4. Warmth / tint (pipeline 1: after the film; pipeline 2 did it before).
        if !filmScience {
            image = whiteBalance(image, recipe)
        }

        // 5. Halation (pipeline 1)
        if !filmScience, recipe.halationAmount > eps {
            image = halation(image, extent: extent, amount: clamp(recipe.halationAmount, 0, 1),
                             radius: clamp(recipe.halationRadius, 0, 1), scale: scale)
        }

        // 6. Bloom
        if recipe.bloomAmount > eps {
            let f = CIFilter.bloom()
            f.inputImage = image
            f.radius = Float(min(100, 25 * scale))
            f.intensity = Float(clamp(recipe.bloomAmount, 0, 1))
            image = (f.outputImage ?? image).cropped(to: extent)
        }

        // 7. Grain
        if filmScience {
            if recipe.grainAmount > eps {
                var grainCharacter = character
                grainCharacter.grainStrength *= push > 0 ? 1 + character.pushGrainPerStop * push : 1 + 0.15 * push
                image = filmGrain(image, extent: extent, character: grainCharacter,
                                  amount: clamp(recipe.grainAmount, 0, 1), sizeSlider: clamp(recipe.grainSize, 0, 1),
                                  diagonal: diagonal, shadowGain: reciprocityEffect?.shadowGrainGain ?? 1)
            }
        } else if recipe.grainAmount > eps {
            image = grain(image, extent: extent, amount: clamp(recipe.grainAmount, 0, 1),
                          size: clamp(recipe.grainSize, 0, 1), scale: scale)
        }

        // 8. Vignette
        if recipe.vignetteAmount > eps {
            let diag = diagonal
            let f = CIFilter.vignetteEffect()
            f.inputImage = image
            f.center = CGPoint(x: extent.midX, y: extent.midY)
            f.radius = Float(0.75 * diag / 2)
            f.intensity = Float(clamp(recipe.vignetteAmount, 0, 1))
            f.falloff = 0.5
            image = (f.outputImage ?? image).cropped(to: extent)
        }

        // 8b. Mask overlay (editor only).
        if maskOverlay, recipe.dodgeBurn.hasVisibleEffect,
           let source = sourceSize ?? (recipe.crop.isIdentity ? extent.size : nil) {
            image = dodgeBurnOverlay(recipe.dodgeBurn, over: image, extent: extent, crop: recipe.crop,
                                     sourceSize: source, region: maskRegion)
        }

        // 9. Border
        if recipe.borderEnabled {
            let pad = (clamp(recipe.borderWidth, 0, 0.3) * min(extent.width, extent.height)).rounded()
            if pad > 0 {
                let cream = CIColor(red: 0.96, green: 0.94, blue: 0.88, alpha: 1,
                                    colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
                let frame = extent.insetBy(dx: -pad, dy: -pad)
                let paper = CIImage(color: cream).cropped(to: frame)
                image = image.cropped(to: extent).composited(over: paper)
            }
        }
        return image
    }

    /// Warmth / tint. Positive warmth = warmer (more red), positive tint = more magenta.
    func whiteBalanceForMeter(_ image: CIImage, _ recipe: Recipe) -> CIImage { whiteBalance(image, recipe) }

    private func whiteBalance(_ image: CIImage, _ recipe: Recipe) -> CIImage {
        guard abs(recipe.warmth) > eps || abs(recipe.tint) > eps else { return image }
        let f = CIFilter.temperatureAndTint()
        f.inputImage = image
        f.neutral = CIVector(x: 6500, y: 0)
        f.targetNeutral = CIVector(
            x: 6500 - 1500 * clamp(recipe.warmth, -1, 1),
            y: -40 * clamp(recipe.tint, -1, 1))
        return f.outputImage ?? image
    }

    /// Pipeline 2 halation: blur the highlights at the film's radius, take them out of the image and put
    /// a (nearly) equal luminance back as a tinted glow. The glow is two Gaussians, 0.65 at sigma and 0.35 at
    /// sigma / 3: the tight one makes the fringe hug the edge of the light, the wide one is the soft tail.
    /// The source loses only `halationCompensation` of the scattered light (see `miraHalationCombine`).
    private func filmHalation(_ image: CIImage, extent: CGRect, amount: Double, character: FilmCharacter,
                              radiusSlider: Double, diagonal: CGFloat) -> CIImage {
        let sigma = character.halationRadius * diagonal * exp2((radiusSlider - 0.5) * 2)
        let h = GradeKernels.halationHighlights(of: image)
        let wide = Self.softBlur(h, extent: extent, sigma: sigma)
        let tight = Self.softBlur(h, extent: extent, sigma: sigma / 3)
        let mix = CIFilter.additionCompositing()
        mix.inputImage = tight.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.35, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.35, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.35, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        mix.backgroundImage = wide.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.65, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 0.65, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.65, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])
        let blurred = (mix.outputImage ?? wide).cropped(to: extent)
        return GradeKernels.applyHalation(amount: amount, tint: character.halationTint, to: image, blurred: blurred)
            .cropped(to: extent)
    }

    /// Pipeline 2 grain: smooth band-limited noise on the encoded image (see `miraGrain`).
    private func filmGrain(_ image: CIImage, extent: CGRect, character: FilmCharacter, amount: Double,
                           sizeSlider: Double, diagonal: CGFloat, shadowGain: Double = 1) -> CIImage {
        let size = character.grainSize * exp2((sizeSlider - 0.5) * 2)
        // A pixel that averages f x f grains sees 1/f of the variation (f = grain cells per pixel).
        let cellsPerPixel = 1 / (size * diagonal)
        let bandLimit = min(1, 1 / cellsPerPixel)
        let std = amount * 2 * character.grainStrength * 0.025 * bandLimit
        let encoded = toGamma(image)
        let grained = GradeKernels.applyGrain(std: std, cell: size, chroma: character.grainChroma,
                                              tonalCenter: character.grainTonalCenter, diagonal: diagonal,
                                              shadowGain: shadowGain, to: encoded)
        return fromGamma(grained).cropped(to: extent)
    }

    private func halation(_ image: CIImage, extent: CGRect, amount: Double, radius: Double, scale: CGFloat) -> CIImage {
        // Soft threshold on linear luma: (luma - 0.55) / 0.45, clamped to 0...1.
        let t = CIFilter.colorMatrix()
        t.inputImage = image
        let k: CGFloat = 1 / 0.45
        let luma = [0.2126 * k, 0.7152 * k, 0.0722 * k]
        t.rVector = CIVector(x: luma[0], y: luma[1], z: luma[2], w: 0)
        t.gVector = t.rVector
        t.bVector = t.rVector
        t.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let bias = -0.55 / 0.45
        t.biasVector = CIVector(x: bias, y: bias, z: bias, w: 1)
        let clampF = CIFilter.colorClamp()
        clampF.inputImage = t.outputImage
        clampF.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clampF.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)
        var mask = clampF.outputImage ?? image

        mask = Self.softBlur(mask, extent: extent, sigma: (8 + 40 * radius) * scale)

        // Tint warm red-orange, scaled by amount.
        let a = CGFloat(amount) * 0.9
        let tint = CIFilter.colorMatrix()
        tint.inputImage = mask
        tint.rVector = CIVector(x: a, y: 0, z: 0, w: 0)
        tint.gVector = CIVector(x: a * 0.38, y: 0, z: 0, w: 0)
        tint.bVector = CIVector(x: a * 0.08, y: 0, z: 0, w: 0)
        tint.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        tint.biasVector = CIVector(x: 0, y: 0, z: 0, w: 1)

        let screen = CIFilter.screenBlendMode()
        screen.inputImage = tint.outputImage
        screen.backgroundImage = image
        return (screen.outputImage ?? image).cropped(to: extent)
    }

    /// Gaussian blur that runs on a reduced copy when the radius is large: a wide blur has no
    /// detail left, so blurring at 1/4 (or 1/2) size and enlarging with bilinear filtering gives the
    /// same picture for a fraction of the work. Small radii blur at full size.
    static func softBlur(_ image: CIImage, extent: CGRect, sigma: CGFloat) -> CIImage {
        let factor: CGFloat = sigma >= blurReductionThreshold ? 4 : (sigma >= blurReductionThreshold / 2 ? 2 : 1)
        let blur = CIFilter.gaussianBlur()
        guard factor > 1 else {
            blur.inputImage = image.clampedToExtent()
            blur.radius = Float(sigma)
            return (blur.outputImage ?? image).cropped(to: extent)
        }
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let small = CGSize(width: max(1, (extent.width / factor).rounded(.up)),
                           height: max(1, (extent.height / factor).rounded(.up)))
        let down = CGAffineTransform(scaleX: small.width / extent.width, y: small.height / extent.height)
        let reduced = image.transformed(by: origin).clampedToExtent()
            .transformed(by: down, highQualityDownsample: true)
            .cropped(to: CGRect(origin: .zero, size: small))
        blur.inputImage = reduced.clampedToExtent()
        blur.radius = Float(sigma / factor)
        let blurred = (blur.outputImage ?? reduced).cropped(to: CGRect(origin: .zero, size: small))
        let up = CGAffineTransform(scaleX: extent.width / small.width, y: extent.height / small.height)
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        return blurred.transformed(by: up, highQualityDownsample: false).cropped(to: extent)
    }

    /// Blurs with at least this sigma (pixels) run at reduced size.
    static let blurReductionThreshold: CGFloat = 8

    private func grain(_ image: CIImage, extent: CGRect, amount: Double, size: Double, scale: CGFloat) -> CIImage {
        // Noise lives on a virtual grid whose cell is `scale * (1 + 2 * size)` image pixels,
        // so grain particles are proportional to the image size at any resolution.
        let cell = scale * CGFloat(1 + 2 * size)
        let cols = (extent.width / cell).rounded(.up) + 3
        let rows = (extent.height / cell).rounded(.up) + 3
        guard let random = CIFilter.randomGenerator().outputImage else { return image }

        // Fixed offset: the field is deterministic and identical between renders.
        let field = random
            .transformed(by: CGAffineTransform(translationX: 137, y: 291))
            .cropped(to: CGRect(x: 0, y: 0, width: cols, height: rows))
            .settingAlphaOne(in: CGRect(x: 0, y: 0, width: cols, height: rows))

        // One channel -> mono noise centred on 0.5 with spread proportional to amount.
        let k = CGFloat(amount)
        let mono = CIFilter.colorMatrix()
        mono.inputImage = field
        mono.rVector = CIVector(x: k, y: 0, z: 0, w: 0)
        mono.gVector = mono.rVector
        mono.bVector = mono.rVector
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        let b = 0.5 - 0.5 * k
        mono.biasVector = CIVector(x: b, y: b, z: b, w: 1)

        let place = CGAffineTransform(scaleX: cell, y: cell)
            .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY))
        guard let noise = mono.outputImage?.transformed(by: place).cropped(to: extent) else { return image }

        // Soft light in sRGB-encoded space: strongest in the midtones, fades to the extremes.
        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = noise
        blend.backgroundImage = toGamma(image)
        return fromGamma(blend.outputImage ?? image).cropped(to: extent)
    }

    // MARK: Helpers

    /// Pipeline 1's lookup: `CIColorCubeWithColorSpace` in sRGB (output quantised to about 8 bits; kept so
    /// saved legacy edits render exactly as before).
    private func legacyCube(_ lut: LUT, _ image: CIImage) -> CIImage? {
        let f = CIFilter.colorCubeWithColorSpace()
        f.inputImage = image
        f.cubeDimension = Float(lut.dimension)
        f.cubeData = lut.data
        f.colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        return f.outputImage
    }

    /// The Paper stage: the print look's cube (the same one the print cards use) applied in sRGB, blended
    /// with the unprinted image by film strength.
    private func applyPaper(_ lut: LUT, id: String, to image: CIImage, strength: Double, extent: CGRect) -> CIImage {
        guard strength > 1e-4 else { return image }
        // Pipeline 2 only: the float kernel (see `miraLUT3D`).
        guard let printed = GradeKernels.applyLUT3D(lut, cacheKey: "paper:\(id)", to: image)
                ?? legacyCube(lut, image) else { return image }
        guard strength < 1 - 1e-4 else { return printed.cropped(to: extent) }
        let mix = CIFilter.dissolveTransition()
        mix.inputImage = image
        mix.targetImage = printed
        mix.time = Float(strength)
        return (mix.outputImage ?? printed).cropped(to: extent)
    }

    private func toGamma(_ image: CIImage) -> CIImage {
        let f = CIFilter.linearToSRGBToneCurve()
        f.inputImage = image
        return f.outputImage ?? image
    }

    private func fromGamma(_ image: CIImage) -> CIImage {
        let f = CIFilter.sRGBToneCurveToLinear()
        f.inputImage = image
        return f.outputImage ?? image
    }

    private let eps = 1e-6

    private func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    // MARK: Rendering

    /// Renders to an 8-bit CGImage in `colorSpace` (default sRGB).
    public func render(
        _ recipe: Recipe, input: CIImage, context: CIContext, colorSpace: CGColorSpace? = nil
    ) -> CGImage? {
        Perf.interval("preview render") {
            let out = apply(recipe, to: input)
            let space = colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            return context.createCGImage(out, from: out.extent, format: .RGBA8, colorSpace: space)
        }
    }

    /// Lanczos downscale so the longest side is at most `maxPixelSize`. Never upscales.
    public func previewImage(from image: CIImage, maxPixelSize: CGFloat) -> CIImage {
        let e = image.extent
        let longest = max(e.width, e.height)
        guard longest > maxPixelSize, maxPixelSize > 0, !e.isInfinite else { return image }
        let f = CIFilter.lanczosScaleTransform()
        f.inputImage = image
        f.scale = Float(maxPixelSize / longest)
        f.aspectRatio = 1
        return f.outputImage ?? image
    }

    /// Same graph as `apply`; intended for small preview images.
    public func thumbnail(_ recipe: Recipe, input: CIImage) -> CIImage {
        apply(recipe, to: input)
    }

    // MARK: Export

    public func export(
        _ recipe: Recipe, inputURL: URL, outputURL: URL, type: UTType, quality: Double
    ) throws {
        guard let loaded = ImageSource.loadWithColorSpace(url: inputURL) else {
            throw RendererError.cannotLoad(inputURL)
        }
        try export(recipe, source: loaded.image, metadataFrom: inputURL, outputURL: outputURL,
                   type: type, quality: quality, colorSpace: loaded.colorSpace)
    }

    /// Renders an already loaded, upright `source` and writes it. Metadata is copied from
    /// `metadataFrom` when readable (orientation reset to 1, pixel dimensions and RAW-only
    /// dictionaries dropped). `colorSpace` nil picks sRGB or Display P3 from the source.
    public func export(
        _ recipe: Recipe, source input: CIImage, metadataFrom: URL?, outputURL: URL,
        type: UTType, quality: Double, colorSpace: CGColorSpace? = nil
    ) throws {
        let signpost = Perf.begin("export")
        defer { Perf.end("export", signpost) }
        let inputURL = metadataFrom
        let space = colorSpace ?? Self.outputColorSpace(for: input.colorSpace)
        let context = Self.sharedContext
        let out = apply(recipe, to: input)
        let format: CIFormat = type == .tiff ? .RGBA16 : .RGBA8
        guard let cg = context.createCGImage(out, from: out.extent, format: format, colorSpace: space) else {
            throw RendererError.renderFailed
        }

        // Keep source metadata; pixels are upright now, so orientation becomes 1.
        var props: [CFString: Any] = [:]
        if let inputURL, let src = CGImageSourceCreateWithURL(inputURL as CFURL, nil),
           let copy = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
            props = copy
        }
        props[kCGImagePropertyOrientation] = 1
        // RAW-only dictionaries and maker blobs that do not belong in a JPEG/HEIC/TIFF.
        for key in [kCGImagePropertyDNGDictionary, kCGImagePropertyRawDictionary, kCGImagePropertyCIFFDictionary] {
            props.removeValue(forKey: key)
        }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyProfileName,
                    kCGImagePropertyDepth, kCGImagePropertyHasAlpha, kCGImagePropertyColorModel] {
            props.removeValue(forKey: key)
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            props[kCGImagePropertyExifDictionary] = exif
        }
        if var iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] {
            iptc[kCGImagePropertyIPTCImageOrientation] = 1
            props[kCGImagePropertyIPTCDictionary] = iptc
        }
        if type != .tiff { props[kCGImageDestinationLossyCompressionQuality] = clamp(quality, 0, 1) }

        guard let dest = CGImageDestinationCreateWithURL(outputURL as CFURL, type.identifier as CFString, 1, nil) else {
            throw RendererError.cannotWrite(outputURL)
        }
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw RendererError.cannotWrite(outputURL) }
    }

    /// Display P3 for wide-gamut inputs, otherwise sRGB.
    static func outputColorSpace(for input: CGColorSpace?) -> CGColorSpace {
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let input, input.model == .rgb, let name = input.name as String? else { return srgb }
        let narrow: Set<String> = [
            CGColorSpace.sRGB as String, CGColorSpace.extendedSRGB as String,
            CGColorSpace.linearSRGB as String, CGColorSpace.extendedLinearSRGB as String,
            CGColorSpace.genericRGBLinear as String,
        ]
        if narrow.contains(name) { return srgb }
        return CGColorSpace(name: CGColorSpace.displayP3) ?? srgb
    }
}
