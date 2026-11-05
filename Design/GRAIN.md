# Film grain: research for Mira

Public sources only (help pages, marketing text, papers, open code, datasheets). No app binaries or resources were inspected. Papers and datasheets kept in `sources/` (untrusted data, never executed). Items marked **[ASSUMPTION]** are my engineering inference, not from a source. Items marked **[NOT FOUND]** were searched for and not located.

---------------------------------------------------------------------

## 1. Photomator / Pixelmator Pro

- Photomator Grain: "adds granularity to a photo, emulating the look of an analog film". Two controls only: **Size** ("control the fineness of the grain") and **Intensity** ("adjust the sharpness of the grain particles"). No ranges, defaults, resolution or zoom statements. https://support.pixelmator.com/photomator-user-guide/color-adjustments/grain
- Pixelmator Pro Grain: **Size** slider, 0-100% by default, Option-drag or typing extends to 0-400%; **Intensity** 0-100% ("adjust the visibility of the grain particles"). Applies to a layer or, via a colour-adjustments layer, to several layers. Nothing about resolution, zoom or export. https://support.pixelmator.com/pixelmator-pro-user-guide/adjust-colors/add-film-grain-to-an-image
- Note the Photomator guide calls Intensity "sharpness" while the Pro guide calls it "visibility": wording differs between the two apps' docs.
- **[NOT FOUND]** Whether Photomator renders grain at full resolution on export, and how it previews when zoomed. No help page, blog post or release note says. (Searches: pixelmator.com support, Photomator grain + export/zoom.) Treat as undocumented; do not infer.
- Vocabulary takeaway: a generic two-slider overlay-style grain (size, intensity); no density/tonal dependence, clumping, per-stock behaviour or resolution-independence is claimed.

## 2. Ritual (Latent Studios), marketing text only

Verbatim from https://latentstudios.art/ritual/ :
- "Grain is silver on the negative: its size, its clumping and where it gathers across the tones, each film its own." (Darkroom section)
- "Push the grain until it roars: it stays silver, clumped by density, never noise laid on top."
- "Spot, Heal and Clone mend the negative itself, so every repair carries the grain of the film it sits on." and "Every touch sits on the negative, so it carries the film's grain and redevelops when the film changes."
- Each film is developed "with its own colour, its own grain and its own chemistry." The raw engine recovers "the grain of a slide".
- Captions: "The same detail with a finer grain"; "A portrait detail at full size on Portra 400, the grain raised"; panel labels "Grain" and "Grain - pushed".
- No numbers, no algorithm. Claimed properties to match in spirit: (1) per-film size/clumping/tonal distribution, (2) density-dependent clumping, (3) grain is part of the image formation (not an overlay), so retouching and film changes keep it consistent, (4) stays "silver" when pushed (structure, not amplified noise).

## 3. Dehancer and Filmbox

Dehancer (OFX plugin blog) https://blog.dehancer.com/articles/how-does-film-grain-work-in-dehancer-ofx-plugin/ :
- **Size**: "determines the size of silver halide granules"; higher = more photosensitive (grainier) emulsion.
- **Amount**: "Total amount of grain generated, corresponding to the negative optical density"; at high Amount grain becomes opaque and visible cluster formations appear ("the overall texture is formed by grain clusters, not individual granules").
- **Resolution**: 100 keeps source detail; lower softens (because detail cannot be finer than grain).
- **Distribution**: "Grain distribution between shadows, midtones and highlights."
- Emulsion treated as a thick layer: "Film emulsion has a certain thickness, i.e. it is not flat" (3D grain particles). The post says grain is heavier in highlights because they reach maximum negative density with most silver halide (i.e. density-driven).
- Grain size auto-corrects to the project's geometric frame size (same blog). "Roughness" and "clumping" are **not** named parameters in that post.
- Dehancer iOS/web pages only say "Organic texture for true analog character" / "Adjustable Halation, Bloom and Grain": https://www.dehancer.com/shop/ios , https://blog.dehancer.com/2024/03/01/dehancer-online-the-revolutionary-photo-editor-that-brings-retro-film-aesthetics-to-your-browser/

Filmbox (Video Village, motion-picture oriented) https://videovillage.com/filmbox/ :
- "Filmbox reproduces the tonal distribution of grain across the density of each channel of the negative emulsion." Tonal Distribution control with "nine zones with false-color feedback" (Pro).
- Per-stock grain (98 stocks in Pro), gauge-dependent ("Smaller film means stronger texture"; 8/16/35/65 mm, VistaVision).
- Grain controls: Global (intensity, colour, mixing stocks), Spatial ("softness, roughness, streaks"), Granules ("light and dark granule brightness"). Grain "sampled from real scans" with structural and temporal qualities modelled as part of development.
- The user guide PDF was too large to fetch (10 MB limit): https://videovillage.com/images/filmbox/features/Filmbox%20Looks%20User%20Guide.pdf . A search summary said grain is "mapped according to the density of the emulated negative"; I could not verify that wording directly.

Shared vocabulary: size (of silver halide / granules), amount (tied to density), clumping/clusters, tonal or density distribution per channel, roughness/softness (spatial), gauge/format (smaller frame = stronger grain), per-stock, resolution coupling.

---------------------------------------------------------------------

## 4. Literature (core)

### 4.1 Papers and code
- Newson, Delon, Galerne, "A Stochastic Film Grain Model for Resolution-Independent Rendering", Computer Graphics Forum 36(8):684-699, 2017. DOI 10.1111/cgf.13159 https://diglib.eg.org/handle/10.1111/cgf13159 . Author PDF (kept): https://hal.archives-ouvertes.fr/hal-01520260/file/Film_grain_synthesis_computer_graphics_forum.pdf ; earlier preprint https://hal.science/hal-01358392 (both in `sources/`).
- Newson, Faraj, Delon, Galerne, "Realistic Film Grain Rendering", IPOL 7 (2017) 165-183. https://www.ipol.im/pub/art/2017/192/ (PDF `sources/ipol_2017_192_article_lr.pdf`; C++ code GPL-3.0, online demo). GPU port: https://github.com/alasdairnewson/film_grain_rendering_gpu (README gives parameters; no GPU technique or timings).
- Related: Newson, Galerne, Delon, "Analysis of a Physically Realistic Film Grain Model, and a Gaussian Film Grain Synthesis Algorithm" (SSVM 2017) https://hal.archives-ouvertes.fr/hal-01494123 (abstract not retrievable; Anubis block; listed only by title in search).

### 4.2 The model (IPOL article, sections 3-4)
- Silver grains are opaque, so a developed negative is binary: 0 under a grain, 1 elsewhere. Model: **inhomogeneous Boolean model** Z = union of discs, centres from a Poisson process, radii i.i.d. with mean mu_r, std sigma_r. Radius law: constant or **log-normal** (CGF/preprint section 5.2, citing Livens-era results).
- Coverage probability of a homogeneous model: P(Z(y)=1) = 1 - exp(-lambda * E[pi r^2]).
- Match local grey level u in [0,1) (normalised by u_max + eps) by choosing
  **lambda(y) = (1 / E[pi r^2]) * ln(1 / (1 - u(y)))**, with **E[pi r^2] = pi (mu_r^2 + sigma_r^2)** so expected covered fraction = u. For each input pixel: Q ~ Poisson(lambda * pixel area), centres uniform in the pixel, radii ~ D(mu_r, sigma_r).
- Log-normal radius with target mean mu_r and std sigma_r: underlying normal has **s^2 = ln((mu_r^2 + sigma_r^2)/mu_r^2)** and **m = ln(mu_r) - (mu_r^2 + sigma_r^2)/(2 mu_r^2)** as printed in the preprint (eq. 6; the PDF text extraction is garbled, standard identity is m = ln(mu_r) - s^2/2).
- **Filtering / output**: v(p) = (phi * Z)(p) with phi a Gaussian of std sigma, standing for enlargement + vision (scan blur). Monte Carlo estimate on output grid with zoom s: **v(y) = (1/N) sum_k Z((y - xi_k)/s)**, xi_k ~ N(0, sigma^2 I), same offsets reused for all pixels; sigma is in **output** pixels (default 0.8). Relative MC error ~ 1/(2 sqrt N) as per the paper (N = 800 gives 1.77%, N ~ 100 gives 5%).
- **Resolution independence**: Z is defined on the continuous plane in input-pixel units (one input pixel = unit square); any output grid (any zoom, any sub-window) samples the same realisation Z via the hashed Poisson process. Radii mu_r are in input pixels.
- **Algorithms** (both in IPOL):
  - Grain-wise: for each input pixel draw Q grains and splat each onto N binary images shifted by xi_k, then average. Memory O(N x output). Complexity C0 = m n N * 4 ln2 / (pi (mu_r^2 + sigma_r^2)) at u = 1/2.
  - Pixel-wise: partition plane into cells of size delta = 1/ceil(1/mu_r); for each output pixel and each of N offsets, regenerate grains of all cells within the maximum radius r_m (the 99.9% radius quantile) via a per-cell hashed PRNG, stop at the first covering grain. Complexity C1 = m n N (2 floor(p_{1-a}/mu_r)+1)^2 mu_r^2 ln2 / (pi (mu_r^2+sigma_r^2)) (with delta = mu_r). Pixel-wise wins when sigma_r < mu_r-ish and is fully parallel; lambda per grey level is pre-tabulated (256 entries) to avoid logs.
- **Typical parameters**: the CGF preprint advises mu_r = 0.1 input pixel, sigma_r = 0 or 0.02 (more graininess), sigma = 0.8 output pixel, N = 800, zoom s usually 1-4; the IPOL figures vary mu_r from 0.025 to 0.1 with sigma_r = 0, mu_r/4, mu_r/2 etc. and the empirical algorithm-choice study covers mu_r in 0.03-0.3 and sigma_r/mu_r in 0.1-0.9. Radii are in input pixels.
- **Cost (preprint Table 1, 2016 hardware, constant grey 128, r = 0.05, N = 800)**: pixel-wise CPU-parallel (40 cores) 81 s for 2048x2048; pixel-wise on one Tesla T10 GPU (CUDA) 7.2 s for 2048x2048 (0.48 s for 512x512; scales linearly in pixel count). Extrapolating linearly to 24 MP: tens of seconds on that GPU with N = 800, i.e. not interactive; N ~ 100 gives 8x. The authors themselves call the algorithm "still not real-time in many situations" and suggest approximating the texture with Gaussian textures as future work. (Preprint, conclusion, https://hal.science/hal-01358392 .)
- Limitations stated by the authors: purely 2D (no emulsion thickness; suggests 2D projection of a 3D hard-core model), no clumping beyond overlap, grain shape matters little.

### 4.3 GPU/real-time approximations and what they trade
- **Pre-rendered / example-based** (older products): "a single grain image is saved for each film type" (DxO FilmPack, TrueGrain), random-phase textures (G'MIC), Heeger-Bergen; additive; fixed resolution, no density dependence, repeats (IPOL section 2.1).
- **AV1 film grain synthesis** (Norkin and Birkbeck, DCC 2018): autoregressive process (lag 0-3) generates a 64x64 luma / 32x32 chroma grain template; applied block-wise (32x32 luma blocks with pseudo-random offsets, optional 2-sample overlap); intensity dependence by a **piecewise-linear scaling function** Y' = Y + f(Y) * G_L (LUT); chroma has correlation to luma grain. Cheap and mandatory in conformant decoders, but additive noise in the coded domain, tiled template (repeats), no physical resolution-independence, can lower PSNR. https://norkin.org/research/film_grain/ ; paper https://norkin.org/pdf/DCC_2018_AV1_film_grain.pdf ; overview https://arxiv.org/pdf/2008.06091
- **Zhang, Wang, Tian, Pappas, "Film Grain Rendering and Parameter Estimation", ACM TOG 2023** (DOI 10.1145/3592127): renders from statistics derived analytically from the Boolean model (no Monte Carlo); claims real-time film grain simulation and parameter-estimation formulas; a search summary reported "six orders of magnitude" faster than Newson et al. I could not retrieve the full text, so the exact technique (and whether it is a Gaussian-field approximation) is **unverified**. https://history.siggraph.org/?p=132288 ; https://unpaywall.org/10.1145%2F3592127
- **Newson Gaussian-texture variant** (SSVM 2017, above): second-order (mean + covariance) statistics of the Boolean model matched with a Gaussian field. Exactly the trade made in section 6 below (cheap, stationary, loses binary look and skew).
- Trade-off summary: exact Boolean MC = physically correct at any zoom but 10^2-10^3 samples per pixel; Gaussian/AR fields = O(1) per pixel, correct mean and covariance only; templates = cheapest, no resolution independence.

---------------------------------------------------------------------

## 5. Photographic science

### 5.1 Grain, granularity, Selwyn
- **Granularity (RMS)** = standard deviation of optical density D, measured with a microdensitometer through a **48 um circular aperture** at a net diffuse density of 1.0, often quoted x1000. Kodak: "Read at a net diffuse density of 1.0, using a 48-micrometre aperture, 12x magnification." https://cdn.shopify.com/s/files/1/0339/5113/files/f4017_trix_320400.pdf (Tri-X) ; https://en.wikipedia.org/wiki/Film_grain
- **Selwyn's law**: for apertures not too small, **sigma_D * sqrt(A) ~ constant**; Selwyn granularity G = sigma * sqrt(2A). https://en.wikipedia.org/wiki/Film_grain ; Selwyn 1935 as cited in IPOL section 2.1. (Reports exist that the law is inexact in some studies; third-hand, treat with caution.)
- Grain (subjective **graininess**) differs from granularity (objective density noise) (CGF preprint section 5.2).
- **My derivation (Boolean model, small-grain limit, [ASSUMPTION: standard compound-Poisson algebra, not from a cited source])**: with coverage p = 1 - 10^(-D), lambda * E[a] = ln(10) D, a = grain area, density noise through aperture A:
  **sigma_D^2 * A = log10(e) * D * E[a^2] / E[a]**  (0.4343 D a_eff, a_eff := E[a^2]/E[a]).
  For a Gaussian read-out kernel of std sigma, the equivalent aperture is A_eq = 4 pi sigma^2; the 48 um circle (A = 1810 um^2) is equivalent to **sigma_eq = 12.0 um**.
  Log-normal radii (CV k): a_eff = pi mu_r^2 (1+k^2)^5.
- Sensitivity: granularity falls with sqrt of aperture area; so a smaller output/print magnification or a larger scan footprint reduces measured density noise. Kodak's own Print Grain Index rises with enlargement (see 5.3).

### 5.2 Granularity numbers from datasheets (all at D = 1.0, 48 um aperture unless noted)
| Stock | Diffuse RMS granularity (x1000) | Source |
|---|---|---|
| Kodak Tri-X 400 (HC-110 B) | 17 ("fine"); Tri-X 320 = 16 | https://cdn.shopify.com/s/files/1/0339/5113/files/f4017_trix_320400.pdf (`sources/kodak_trix_f4017.pdf`) |
| Kodak T-Max 100 (D-76) | 8 | Kodak F-4016 (Jan 2002) https://125px.com/docs/unsorted/kodak/f4016.pdf (`sources/kodak_tmax_f4016.pdf`) |
| Kodak T-Max 400 (D-76) | 10 | same |
| Fuji Velvia 50 | 9 (third-party: Wikipedia infobox; no Fuji datasheet reachable) | https://en.wikipedia.org/wiki/Velvia ; Fuji sheet URL returned 403 |
| Fuji Provia 100F | 8 (third-party / DigitalTruth reproduction of Fuji sheet; 403 for me) | https://www.digitaltruth.com/products/fuji_tech/Provia100f.pdf ; search summary only |
| Ilford HP5 Plus, Delta 100, Delta 400 | **[NOT FOUND]**: Ilford's 2018 sheets say only "fine grain"/"finest grain" developer notes, no RMS number | https://125px.com/docs/film/ilford/HP5-Plus_201811.pdf , .../Delta-100_201811.pdf , .../Delta-400_201811.pdf |
| Kodak Portra / Ektar | **No RMS**: Kodak replaced it with **Print Grain Index (PGI)**, "cannot be compared to rms granularity"; 4 PGI units = 1 JND, 25 = visual threshold, viewing 14 in | https://www.freestylephoto.com/static/pdf/product_pdf/kodak/e4050_Kodak_Portra_400.pdf (`sources/kodak_e4050_portra400.pdf`) |
- Portra 400, 35 mm negative, PGI by enlargement: **37 (4.4x, 4x6), 59 (8.8x, 8x10), 89 (17.8x, 16x20)**; 6x6 cm: 25 / 37 / 59 at 2.6x / 4.4x / 8.8x (same E-4050 sheet). So perceived graininess depends on frame size via magnification.
- Other colour PGIs (third-party table, flagged as unreliable by the author): Portra 160 NC 32 (VC 34), Portra 400 <40, Portra 800 48 (older 50), Ektar 100 <25; the same table pairs RMS 4.0 / 4.5 / 5.0 with PGI 28 / 41 / 53 on a "not linear" basis and says slide RMS is about 2.5x print-film RMS. https://cacreeks.com/films.htm . PetaPixel: Portra 160 PGI 28 (4x6), Ektar 100 <=25. https://petapixel.com/2026/10/16/kodak-portra-160-might-be-the-best-fine-grain-color-negative-film/
- Kodak data in the Tri-X sheet is for "old versions" but said valid for new ones.

### 5.3 Physical sizes
- Silver halide crystals: one reference lists 0.2-2.0 um, another 0.5-3 um for colour negative, larger = faster film (web pages summarised in a search; no primary source). Tabular grains (T-grain, Delta, T-Max, Portra): flat crystals, aspect ratio >= 2, equivalent circle diameter often <5 um; lie flat so less scatter, more resolution. https://en.wikipedia.org/wiki/Tabular-grain_film
- **Colour film: dye clouds** (not crystals) form the visible grain; clouds are larger: a film-grain presentation gives **10-15 um** (secondary source), one cyan-cloud micrograph reference 1.5-15 um. A cloud may be formed by many crystals; grain in each layer is "tens to hundreds of dye clouds". Cloud diameter defined as equivalent-circle diameter of projected area. (Search summary: https://soma.sbcc.edu/users/davega/FILMPRO_170_CINEMATOGRAPHY_I/FILMPRO_170_04_Reference_Notes/FilmGrainGain/2007-04-vitale-filmgrain_resolution.pdf ; patent definition https://image-ppubs.uspto.gov/dirsearch-public/print/downloadPdf/6696230 .) I did not open these PDFs.
- Scale check from section 5.1 formula: Tri-X sigma_D = 0.017 -> a_eff = 1.2 um^2 (effective opaque-grain radius 0.6 um), T-Max 100 -> 0.27 um^2 (0.29 um). Consistent in order of magnitude with the quoted crystal sizes; this is an optical effective area, not a measured crystal size.

### 5.4 Density dependence and tonal location
- Grain is a density phenomenon: variance of D grows with the amount of silver/dye. Boolean small-grain limit: sigma_D^2 proportional to D (first order); real curves are measured at one density only in public datasheets (D = 1.0). **[NOT FOUND]** public RMS-vs-density curves.
- Negative: clear base (very low density) has no grain; dense negative = scene highlights. After printing, clear negative = print black, so deep print shadows are clean; visible grain peaks in mid and light-mid tones (print curve slope times density noise). User brief wording is "clean in clear base"; confirm your pipeline: clear base is scene shadow = print shadow. [ASSUMPTION: this is the standard H&D reading, not tied to a URL.] Dehancer's blog likewise states grain is heavier where negative density is highest (URL in section 3).
- Slides (reversal): positive image, dense = shadows. Grain scales with that density, so shadows/midtones show grain and clear highlights stay clean [ASSUMPTION, same physics].
- Colour film: three dye layers (cyan/magenta/yellow) with independent crystals per layer; **no public source on inter-layer correlation**. Luminance dominance of the appearance is a perceptual effect (eye less sensitive to chroma noise; blue layer contributes little to luminance), so any correlation should be treated as an artistic knob [ASSUMPTION].
- Scanning/printing blur: the optical enlarger and scanner MTF act as a low-pass; IPOL models this as one Gaussian of std sigma ("photo enlargement, human vision", section 3.2), default 0.8 output pixel. Kodak's PGI uses a standardised 14 in viewing distance and states larger prints viewed from further away look less grainy.

---------------------------------------------------------------------

## 6. Recommendation for Mira

### 6.1 Decision in one paragraph
A literal GPU Boolean-model evaluator is too expensive for 24 MP interactive use (IPOL numbers above) and, at the scales that matter, unnecessary: a 36 mm frame sampled at 6 um pitch (24 MP) with a realistic scan blur of ~5 um has hundreds of grains/clouds per footprint, where the Boolean model is Gaussian by the central limit theorem and fully described by mean, variance (Selwyn) and covariance. So ship a **density-domain Gaussian-field synthesiser in frame micrometres with analytic footprint integration** (exactly matches the Boolean model's first two moments at every pixel size), keep the **hashed-cell Boolean pixel-wise algorithm** only as an offline reference/validator and as an optional "crystal" mode when the footprint is below ~1.5 um (unused with default scan blur). All items (a)-(f) of the brief follow.

### 6.2 Coordinates and determinism (a, f)
- Map the **uncropped** photo to the film frame: long side = 36000 um (short side by aspect; use 24000 um for 3:2; allow 56 mm formats for 6x6/645 profiles). x_um = (u_orig / W_orig_long) * 36000 where u_orig is the position in the original, pre-crop, pre-rotation image. Crop, rotate and zoom then only change the *sampling*, not the grain.
- Per-pixel footprint pitch p_um = (frame um per output pixel). In Core Image, pass p_um and the affine from destination pixel to frame um (inverse of the render transform) as kernel uniforms; do not use destination pixel indices as noise coordinates.
- Seed = hash(photo identity) mixed with the layer index; integer lattice hash (e.g. PCG3D/PCG4D, Jarzynski and Olano, "Hash Functions for GPU Rendering", JCGT 9(3), 2020 https://jcgt.org/published/0009/03/02/ ; I could not fetch it, recalled from memory, verify). Same photo + same settings = same grain at every zoom/crop/export.

### 6.3 Model (density domain)
Per layer c (R,G,B or one B&W layer), with film density D_c from Mira's film pipeline *before* the H&D / print curve:

```
sigma_scan   scan/enlarger Gaussian std in frame um           (family default, below)
sigma_pix    = 0.289 * p_um                                   (box pixel aperture)
sigma_f^2    = sigma_scan^2 + sigma_pix^2                     (footprint)
s            grain/cloud correlation std in frame um          (per stock)
tau^2        = s^2 + sigma_f^2                                (noise kernel std)
sigma_eq     = 12.0 um   (Gaussian equivalent of Kodak 48 um aperture)

sigma_D(c)   = G(slider) * sigma48_c * g_c(D_c) * sqrt( (s^2 + sigma_eq^2) / tau^2 )
D_c'         = max(D_c + sigma_D(c) * n_c(x),  Dmin_c)
```
- `sigma48` is the datasheet RMS granularity (x1e-3) at D = 1.0; `g(D)` is the density shape, g(1) = 1. First-order Boolean theory gives g = sqrt((D - Dmin)/(1 - Dmin)); plateau above a family-specific D_peak and clamp at Dmin (no grain in clear base). Public data contain no g(D) curve, so fit the roll-off by running the reference Boolean simulation (section 6.6) with the grain parameters of each stock.
- Check: amplitude formula comes from shot noise of Gaussian-profile clouds: Var = V0 s^2/(s^2 + sigma_f^2) with V0 fixed by sigma48 at sigma_f = sigma_eq (derivation: Var(phi*g) of Poisson shot noise = lambda h^2 pi s^4/(s^2+sigma^2), mean D = lambda h 2 pi s^2). Reduces to Selwyn (sigma_D ~ 1/sigma_f) when sigma_f >> s.
- Worked example (Tri-X sigma48 = 0.017, s = 3 um, sigma_scan = 5 um): 24 MP, p = 6 um -> sigma_D = 0.035, tau = 6.1 um; 12 MP -> 0.031; 1500 px export (p = 24 um) -> 0.023 with tau = 9.1 um. Exporting smaller therefore *reduces* per-pixel grain by the physically correct amount; the preview at any zoom uses the same expression with that zoom's p_um.
- Output: the density noise is added to the negative (or slide) density; the existing tone curve / print step then turns it into the visible, tone-dependent grain automatically (steeper mid-gamma gives more grain, toe/shoulder compress it).

### 6.4 Evaluating n_c(x): sparse lattice Gaussian noise (production kernel)
n_c is unit-variance, zero-mean, with covariance rho(r) = exp(-r^2 / (4 tau^2)) (what Gaussian-kernel-filtered white noise produces), sampled at the pixel centre in frame um:
```
l0  = 1.5 * tau0           tau0^2 = s^2 + sigma_scan^2   (fixed lattice spacing; keeps realisation identical at all zooms)
for lattice node q within 2.25*tau of x (4x4 taps when tau ~ tau0):
    w   = exp(-|x - q*l0|^2 / (2 tau^2))                 // separable: two 1-D exps
    xi  = hash4(seed, q) -> 4 independent unit-variance values (sum of 3 uniforms or uniform +-sqrt3 is enough; CLT across taps)
    n_c += w * xi.c              (and n_0 += w * xi.w   for the common/luminance part)
n_c /= sqrt(pi) * tau / l0       (unit variance; modulation of variance between nodes is ~1e-2 at spacing 1.5 tau)
```
- Footprint integration is analytic: the pixel box + scan blur are folded into tau (wider Gaussian), so one evaluation per pixel, no Monte Carlo, no aliasing at any zoom. At large tau (downsampled exports) tap count grows as (2.25 tau / l0)^2; cap at 6x6 and then cross-fade to a per-pixel hashed Gaussian with the same sigma_D (it is white at that scale anyway).
- Layer decorrelation (d): n_c' = sqrt(rho_f) * n_0 + sqrt(1 - rho_f) * n_c (rho_f from the table), the four noise fields share the same taps and weights (one hash4 call per tap).
- Skew / positivity: density cannot go below Dmin; near Dmin use the clamp (the sigma ~ sqrt(D - Dmin) shape already shrinks the noise there). Optional cheap skew for low D (Poisson-like): n' = n + k_s * (n^2 - 1) with k_s ~ 0.1, tune by eye; not required.
- **Cost estimate [ASSUMPTION, not measured]**: ~16 taps x (hash4 + 4 FMAs + 1 weight) ~ 600-700 ALU ops per pixel -> 24 MP ~ 15-17 GFLOP; at 30-50% of an M1-class GPU (2.6 TFLOPS peak) ~ 10-20 ms; ~3-4x slower on an older phone GPU. Run in fp32 for coordinate math (frame coordinates up to 36000 um / l0 ~ 10^3 lattice units, fine), fp16 for weights. Preview only evaluates the visible region (Core Image ROI), so interactive preview is cheaper than export. Compare: Newson pixel-wise needs ~800 MC samples x ~(3x3 cells x several grains) per pixel.

### 6.5 Optional Boolean mode (zoom into the "crystal" scale, and reference)
Enable only when sigma_f < ~1.5 * mu_r (i.e. scan blur turned off and pitch below ~1 um): pixel-wise Newson algorithm with cell size delta >= r_max (the 99.9% log-normal quantile, about 3.1 x mu_r for CV 0.35), 3x3 cells, Q ~ Poisson(lambda * delta^2) from one uniform via inverse CDF (cap Q at ~12), grain centres/radius via hash (log-normal via Box-Muller), r = min(r, r_max), N = 8-32 jittered samples per pixel inside the Gaussian footprint with a fixed shared offset set (IPOL trick), early-out on first covering grain. Cost ~ N x 9 cells x ~3-6 grains = 200-1700 disc tests per pixel: acceptable only for zoomed-in preview of a small region, not 24 MP export. Coverage -> density: D = Dmin - log10(1 - v) with clamp 1 - v >= 10^-3.

Physical grain radius for B&W/slide stocks from the Selwyn relation (log-normal CV k = 0.35, so a_eff = pi mu_r^2 * 1.78): mu_r = sqrt(a_eff / (pi * 1.78)), a_eff = sigma48^2 * 1810 um^2 / 0.4343.

### 6.6 Validation
Render a uniform patch at D = 1 with the reference Boolean MC (radius from the table) and with the field kernel; compare sigma_D at several apertures (Selwyn: sigma_D * sqrt(A) constant), and the autocorrelation. Calibrate g(D) and the skew correction from that comparison; calibrate the absolute amplitude per family against a few real scans by eye (one multiplier per family).

### 6.7 Per-stock parameter table
sigma48 = RMS at D = 1.0, 48 um, in density units (RMS x 1e-3). "mu_r / a_eff" only for opaque-silver families (Boolean reference). s, sigma_scan, rho_f are **[ASSUMPTION]** starting values (calibrate); dye clouds are 10-15 um in diameter per the secondary source (5.3), s is the Gaussian std of a soft cloud, so s ~ 3-5 um for colour is a deliberate choice.

| Stock | family | sigma48 | basis | a_eff um^2 / mu_r um | s um | rho_f (layer corr.) | D_peak |
|---|---|---|---|---|---|---|---|
| Tri-X 400 | B&W neg | 0.017 | Kodak F-4017 | 1.20 / 0.46 | 3.0 | 1 (single layer) | ~1.2 |
| T-Max 100 | B&W neg (T-grain) | 0.008 | Kodak F-4016 | 0.27 / 0.22 | 2.0 | 1 | ~1.2 |
| T-Max 400 | B&W neg (T-grain) | 0.010 | Kodak F-4016 | 0.42 / 0.27 | 2.3 | 1 | ~1.2 |
| HP5 Plus | B&W neg | ~0.014 | **estimate**, Ilford publishes no RMS | 0.82 / 0.38 | 2.7 | 1 | ~1.2 |
| Delta 100 | B&W neg (core-shell tabular) | ~0.009 | **estimate** | 0.34 / 0.25 | 2.0 | 1 | ~1.2 |
| Delta 400 | B&W neg | ~0.012 | **estimate** | 0.60 / 0.33 | 2.4 | 1 | ~1.2 |
| Kodak Ektar 100 | colour neg | 0.0039 | PGI <25 mapped (below) | n/a (soft clouds) | 3.5 | 0.55 | ~1.5 |
| Kodak Portra 160 | colour neg | 0.0040 | PGI 28 | n/a | 3.7 | 0.55 | ~1.5 |
| Kodak Portra 400 | colour neg | 0.0044 | PGI 37 (35 mm, 4.4x) | n/a | 4.0 | 0.55 | ~1.5 |
| Kodak Portra 800 | colour neg | 0.0049 | PGI 48 | n/a | 4.5 | 0.55 | ~1.5 |
| Fuji Velvia 50 | slide | 0.009 | Wikipedia | 0.34 / 0.25 (optical) | 3.0 | 0.5 | ~2.0 (shadows) |
| Fuji Provia 100F | slide | 0.008 | DigitalTruth/Fuji | 0.27 / 0.22 | 2.8 | 0.5 | ~2.0 |
| Instant (Polaroid/Instax-type) | instant | 0.010 | **[NOT FOUND] no source retrieved**; pure design value | n/a | 7-8 (diffusion mottle) | 0.4 | n/a |

Colour-negative sigma48 mapping used: take the third-party pairing RMS 4.0 / 4.5 / 5.0 = PGI 28 / 41 / 53 (https://cacreeks.com/films.htm) -> ln(sigma) = ln(0.0040) + 0.0098 * (PGI - 28), i.e. about +12% per +12 PGI. This is a *relative* scale; Kodak says PGI cannot be compared to RMS, and colour-negative RMS (4-5) sits on a different scale from B&W RMS (8-17), so treat colour sigma48 as a tunable absolute with correct ratios between stocks, to be calibrated against real scans.

Family defaults (assumptions): sigma_scan = 5 um (50% MTF near 37 lp/mm; a good film scanner), D_min base+fog ~0.2-0.3 negatives. Layer decorrelation: physically each layer's crystals are independent; rho_f is an *appearance* parameter (luminance-dominant) mixing a shared noise field with per-layer fields, none of the above is sourced.

Density shape and tonal location by family (all through the density domain, no extra masks needed):
- Negative (colour/B&W): noise added to the negative density; clear base D = Dmin gets none; print curve then yields the tone dependence. Rising sigma ~ sqrt(D - Dmin) up to D_peak, plateau above.
- Slide: noise added to the positive's density; maximum in shadows/dense midtones, none in clear highlights; plateau at high D.
- B&W: one layer, rho_f = 1, neutral grain, g(D) as above; push/pull mapped by raising sigma48 (below) and s (grain clumps).
- Instant: larger s, lower sigma at small scales, weaker density dependence (diffusion mottle rather than crystal count). Design assumption only.

### 6.8 Mapping Mira's existing slider (0.5 = film's native)
Let t = slider in [0,1].
- Amplitude gain `G(t) = (2t)^1.3` -> G(0) = 0, G(0.5) = 1 (native, exactly the datasheet sigma48 behaviour with the stock's own s), G(1) = 2.46 (about +8 dB; for scale, Kodak's Portra 400 sheet shows +22 PGI per doubling of enlargement, 37 to 59 for 4.4x to 8.8x, so the top of the slider is intended to feel like a stronger-than-native, push-like look).
- Size gain (push-like, optional) `s' = s * (2t)^0.25`, so above native grain also gets slightly clumpier, below native finer (s' >= 0.7 s at t = 0.1). Keep tau0 = sqrt(s^2 + sigma_scan^2) as the *native* value to fix the lattice spacing l0 for all t, and widen the kernel on top of it, so moving the slider changes amplitude/size but not the realisation.
- t = 0 must be an exact no-op (skip the kernel).
- Nothing in the formula depends on output size: export at any size uses its own p_um; "native" means native for a 36x24 mm frame at that pixel pitch, which is what Dehancer's blog also does by auto-correcting grain size for frame size (section 3).

### 6.9 Known gaps and risks
- Photomator export/zoom behaviour, Ilford RMS, official Fuji data sheets, Portra RMS, RMS-vs-density curves, inter-layer grain correlation and instant-film grain data: not obtained from public sources. Numbers in the table marked estimate/assumption must be calibrated by eye against real scans.
- Gaussian-field limit loses the binary/clumped look at the individual-crystal scale, skew at low density and strongly non-Gaussian tails; fine under realistic scan blur, visible only if sigma_scan is set near zero.
- Zhang et al. 2023 and the SSVM Gaussian-texture paper were identified but their full text was not read; verify before citing technique details.
