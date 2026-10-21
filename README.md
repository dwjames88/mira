# Emulsion

Emulsion is an original film-emulation app for macOS. It ships as a **Photos editing extension**, so you can apply a film look to any picture from inside Photos, plus a small **host app** for working on files outside the Photos library. There is no watermark, no paywall and no account.

Status: v0.1. See [TESTING.md](TESTING.md) for what has and has not been verified, and [docs/ROADMAP.md](docs/ROADMAP.md) for what comes next.

## Features

- 31 bundled film looks from the RawTherapee Film Simulation Collection by Pat David, Pavlov Dmitry and Michael Ezra (CC BY-SA 4.0), grouped by family:

| Family | Brand | Films (ISO) |
|--------|-------|-------------|
| Colour negative | Agfa | Ultra Color 100 (100), Vista 200 (200) |
| | Fujifilm | Pro 400H (400), Superia 200 (200), Superia 400 (400), Superia Reala 100 (100) |
| | Kodak | Ektar 100 (100), Portra 160 (160), Portra 400 (400), Portra 800 (800) |
| Slide | Agfa | Precisa 100 (100) |
| | Fujifilm | Astia 100F (100), Provia 100F (100), Velvia 50 (50) |
| | Kodak | Ektachrome 100 VS (100), Kodachrome 64 (64) |
| | Lomography | X-Pro Slide 200 (200) |
| Black and white | Fujifilm | Neopan Acros 100 (100) |
| | Ilford | Delta 100 (100), FP4 Plus 125 (125), HP5 Plus 400 (400), Pan F Plus 50 (50) |
| | Kodak | T-Max 100 (100), T-Max 400 (400), Tri-X 400 (400) |
| Instant | Fujifilm | FP-100C (100) |
| | Polaroid | 669 (80), 690 (80), PX-680 (600), PX-70 (80), Time Zero Expired (80) |

- Sliders: Strength (film blend), Exposure, Contrast, Saturation, Warmth, Tint, Grain and Grain Size, Halation and Halation Radius, Bloom, Vignette, and an optional paper Border with width. Double-click a slider label to reset it.
- Live preview, a film strip with live thumbnails filtered by family, and press-and-hold Compare to see the original.
- **Re-editable edits.** The full recipe is saved as Photos adjustment data (format identifier `com.dwjames.emulsion`, version `1`), so reopening an edited photo in Emulsion restores every slider, and Revert to Original works as usual. Recipes decode with defaults for missing keys, so future versions stay compatible.
- Host app: open or drag in a photo, edit, and export JPEG, HEIC or TIFF (16-bit) with source metadata kept.
- Resolution independent: grain, halation and bloom scale with the image, so a preview and a full-size export look the same.

## Repository layout

```
App/                     Host app (SwiftUI): window, open/drop, export sheet, films browser
PhotosExtension/         Photos editing extension (PHContentEditingController)
Packages/EmulsionCore/   Pipeline: Recipe, Film, FilmLibrary, LUT, Renderer; tests; emulsion-sheet CLI
Packages/EmulsionUI/     Shared SwiftUI editor (EditorView, EditorModel, FilmsBrowserView)
Films/                   films.json, HaldCLUT/*.png, ATTRIBUTION.md, LICENSE-LUTS
Fixtures/                sample.jpg (CC0) and SOURCE.md
scripts/                 run.sh, install.sh, contact-sheet.sh
docs/                    ROADMAP.md
project.yml              XcodeGen spec (the .xcodeproj is generated and git-ignored)
```

## Architecture

**EmulsionCore** is UI-free and builds the look as a pure Core Image filter graph. `Renderer.apply(_:to:)` runs these stages in order, skipping any that are at their neutral value:

1. Exposure (linear light)
2. Film LUT, blended with the pre-LUT image by Strength
3. Contrast and saturation (on sRGB-encoded values)
4. Warmth and tint (linear light)
5. Halation (thresholded, blurred, warm-tinted highlights screened back on)
6. Bloom
7. Grain (deterministic noise, soft-light blended in sRGB-encoded space)
8. Vignette
9. Border (cream paper frame outside the image extent)

**Colour management.** The shared `CIContext` works in extended linear sRGB with half-float intermediates (Metal-backed when available). The film LUTs are authored on sRGB-encoded values, so each cube is applied with `CIColorCubeWithColorSpace` and its colour space set to sRGB: Core Image converts into encoded sRGB, looks up, and converts back, with no manual curve handling. Contrast, saturation and grain are wrapped in explicit linear-to-sRGB and sRGB-to-linear tone curves so they behave perceptually. Export renders in Display P3 when the source is wide-gamut and sRGB otherwise; TIFF is 16-bit, JPEG and HEIC are 8-bit.

**LUTs.** `FilmLibrary` reads `films.json` and loads each HaldCLUT PNG lazily, caching the result. Cubes larger than 64 are trilinearly resampled to 64³ in memory (`.cube` parsing is also implemented). The PNGs on disk are untouched.

**EmulsionUI** holds `EditorModel` (source, recipe, rendering) and `EditorView` (preview, film strip, inspector). Previews render from a copy scaled to about 1600 px on the long side, thumbnails from 160 px, both off the main actor and debounced. Orientation is applied once, when the file is loaded.

**App** wraps `EditorView` in a window with Open, Films and Export, drag and drop, and a films browser with the licence credit.

**PhotosExtension** hosts the same `EditorView`. On start it decodes any existing adjustment data into the recipe and loads `fullSizeImageURL`; on Save it encodes the recipe as adjustment data and renders the full-size image to the type Photos prefers (JPEG, HEIC or TIFF), falling back to JPEG. Cancel asks for confirmation only if the recipe has changed.

The Films folder is bundled in both the app and the extension, since the extension is sandboxed and cannot read the host's bundle.

## Requirements

- macOS 26 or later
- Xcode 27 (Swift 6, strict concurrency)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), used only during development to generate `Emulsion.xcodeproj` from `project.yml`
- An Apple Development signing identity (the project is set up for a Personal Team; change `DEVELOPMENT_TEAM` in `project.yml` to your own)

## Build, run and install

```sh
scripts/run.sh               # xcodegen, Debug build into build/DerivedData, opens the app
scripts/install.sh           # Release build, installs to /Applications, registers the Photos extension
scripts/contact-sheet.sh     # renders build/contact-sheet.png and build/contact-sheet-effects.png
```

`scripts/contact-sheet.sh` takes an optional input path (default `Fixtures/sample.jpg`). After installing, follow [TESTING.md](TESTING.md) to enable the extension in Photos.

## Tests

```sh
swift test --package-path Packages/EmulsionCore
```

## Licensing

- **Code:** All rights reserved, licence TBD. No licence file exists for the source yet.
- **Film LUTs:** the files in `Films/HaldCLUT/` are from the RawTherapee Film Simulation Collection (2015-09-20) by Pat David, with Pavlov Dmitry and Michael Ezra credited in the archive, and are licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Full attribution, the source URL and the mapping from each file to its original name are in [Films/ATTRIBUTION.md](Films/ATTRIBUTION.md). The PNG files are redistributed unmodified, byte for byte, only renamed; Emulsion resamples them to 64³ at load time in memory only. Derivative works of the LUTs must be shared under the same licence.
- **Trademarks:** film stock names are used for information only. Emulsion is not affiliated with, or endorsed by, any film maker or the trademark owners.
- **Sample photo:** `Fixtures/sample.jpg` is "Outdoor portrait" by Anthony Ginsbrook (Unsplash), CC0 1.0, downscaled to 2400x1600. See [Fixtures/SOURCE.md](Fixtures/SOURCE.md).
