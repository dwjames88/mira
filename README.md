# Mira

*Software by FieldFrames.*

Mira is an original film-emulation app for macOS. It ships as a **Photos editing extension**, so you can apply a film look to any picture from inside Photos, plus a **host app** that browses your Photos library and also edits files from disk. There is no watermark, no paywall and no account.

Status: v0.2. See [TESTING.md](TESTING.md) for what has and has not been verified, and [docs/ROADMAP.md](docs/ROADMAP.md) for what comes next.

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
- **Crop.** Non-destructive crop, 90-degree rotation, flips and straighten (-45 to 45 degrees, auto-fitted so there are no empty corners), with aspect presets. It is part of the recipe (`Recipe.crop`, decoded with defaults, so older recipes still open), applied first in the renderer so grain, halation, vignette and border follow the cropped frame, and exports use the cropped size. Press C or use CROP in the toolbar or on the canvas; Return is Done, Esc is Cancel. The pure maths is `CropGeometry` in MiraCore. The crop rect is normalised (top-left origin, y down) in the oriented-and-straightened canvas: rotate90, then flips, then straighten about the centre.
- Live preview, hover preview (hovering a film card shows it on the canvas with the current sliders and a "PREVIEW · FILM" label, without changing the recipe; the extension does the same), a film strip with live thumbnails filtered by family, and press-and-hold Compare to see the original.
- **Re-editable edits.** The full recipe is saved as Photos adjustment data (format identifier `com.fieldframes.mira`, version `1`), so reopening an edited photo in Mira restores every slider, and Revert to Original works as usual. Recipes decode with defaults for missing keys, so future versions stay compatible. The app and the extension use one codec (`MiraAdjustment` in MiraCore), so an edit made in either reopens in the other. Photos edited before the rename (identifier `com.dwjames.emulsion`, version `1`) are still recognised and reopen with their recipe; new saves always write `com.fieldframes.mira`. `MiraAdjustment.legacyFormatIdentifiers` lists the old ones.
- **Photos library in the app.** The host app browses the library in the manner of Photomator: a sidebar (All Photos, Favourites, your albums, and the non-empty smart albums including RAW) and a thumbnail grid with RAW and EDITED badges. Double-click or press Return to open a picture. Saving is non-destructive and goes through PhotoKit: a full-size JPEG (quality 0.95, orientation baked in, Display P3 for RAW) plus the adjustment data. The original is never modified, Photos shows the edit, and Revert to Original in Photos works. The in-app Revert uses `revertAssetContentToOriginal`. A picture edited by another app opens from its original, with a note that saving replaces those edits. This needs Photos permission (`NSPhotoLibraryUsageDescription` and the `com.apple.security.personal-information.photos-library` entitlement); the app asks at launch.
- **RAW.** Camera RAW files are decoded with `CIRAWFilter` (default decode), honouring Photos' `fullSizeImageOrientation`, and exported in Display P3.
- **Files from disk.** Open or drag in a photo, or launch with `open -a Mira photo.jpg` or Finder's Open With (the app registers as a Viewer for common image types, with Alternate rank). The file is never overwritten. The recipe autosaves to a sidecar, `<filename>.mira.json`, next to the image when its folder is writable. Under the App Sandbox, which only grants access to the chosen file, that is rarely the case, so the sidecar goes to `~/Library/Containers/com.fieldframes.mira/Data/Library/Application Support/Mira/Sidecars/<sha256 of path>.mira.json`. The editor footer shows which is in use. A legacy `<filename>.emulsion.json` (and the old fallback copy) is still read when no `.mira.json` exists; the next save writes the new file and removes the legacy one. Revert deletes the sidecar(s), new and legacy. Export writes a new file as JPEG, HEIC or TIFF (16-bit) with source metadata kept.
- **Field Frames design.** The app and extension share the Field Frames look (ink ground, warm paper text, lichen accent, Cormorant Garamond and IBM Plex Mono, grain, a character-cell grid, square corners). The app's toolbar is mono text without Liquid Glass. See [Design/THEME.md](Design/THEME.md).
- Resolution independent: grain, halation and bloom scale with the image, so a preview and a full-size export look the same.

## Repository layout

```
App/                     Host app (SwiftUI): window, Photos library browser, open/drop, export sheet, films browser; SelfTest/ sample
PhotosExtension/         Photos editing extension (PHContentEditingController)
Packages/MiraCore/   Pipeline: Recipe, Film, FilmLibrary, LUT, Renderer, MiraAdjustment, ImageSource, SidecarStore; tests; mira-sheet CLI
Packages/MiraUI/     Shared SwiftUI editor (EditorView, EditorModel, FilmsBrowserView) and FieldFramesTheme with bundled fonts
Films/                   films.json, HaldCLUT/*.png, ATTRIBUTION.md, LICENSE-LUTS
Fixtures/                sample.jpg (CC0) and SOURCE.md
scripts/                 run.sh, install.sh, contact-sheet.sh
Design/                  THEME.md (Field Frames theme)
docs/                    ROADMAP.md
project.yml              XcodeGen spec (the .xcodeproj is generated and git-ignored)
```

## Architecture

**MiraCore** is UI-free and builds the look as a pure Core Image filter graph. `Renderer.apply(_:to:)` runs these stages in order, skipping any that are at their neutral value:

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

**LUTs.** `FilmLibrary` reads `films.json` and loads each HaldCLUT PNG lazily, caching the result in memory. Cubes larger than 64 are trilinearly resampled to 64³ (`.cube` parsing is also implemented). The resampled 64³ cube is also written to a disk cache in `Library/Caches/<bundle id>/LUTs` (16-bit, keyed on file size, modification time and format version), so a large PNG is decoded once per install. Loading all 31 films cold takes about 0.56 s with parallel loading, against about 2 s before; warm it takes about 19 ms. The app prewarms the library at launch and builds thumbnails in parallel. `mira-sheet --time-luts --films Films` prints these timings. The PNGs on disk are untouched.

**Source loading and adjustments.** `ImageSource` loads photos upright and decodes camera RAW with `CIRAWFilter` (default decode), applying Photos' `fullSizeImageOrientation` when it is given; RAW exports in Display P3. `MiraAdjustment` is the single place that encodes and decodes a `Recipe` as Photos adjustment data, shared by the app and the extension. `SidecarStore` reads and writes the sidecar for files opened from disk; the JSON holds `formatIdentifier`, `formatVersion`, `recipe`, and `sourcePath`, `bookmark` and `modified` for reference.

**Preview pipeline.** `PreviewEngine` (MiraCore) renders interactive previews at the size of the canvas. The slider-independent part, crop, rotation, straighten and the downscale to canvas size, is done once per (source, crop, size) and kept as a half-float bitmap; a slider change only runs the grading graph on that bitmap (`Renderer.grade`). The crop is cut from the best level of a power-of-two pyramid of the full-size source, so a tight crop stays sharp and a whole-picture preview reads a small level. Frames render into IOSurface-backed pixel buffers tagged sRGB. `PreviewSizing` decides the render size (canvas pixels, never upscaled, capped at 3072 px, 1600 px until the view reports its size) and `RenderGate` coalesces requests: one render in flight, the latest request waits and replaces older ones. Halation blurs of 8 px or more run on a 1/4 (or 1/2) size copy. One shared `CIContext` (`Renderer.sharedContext`) serves previews, thumbnails, hover renders and export.

**Performance harness.** `mira-sheet --bench --films Films` times preview frames at canvas resolution, opening a 24 MP JPEG, the 32-thumbnail film strip (cold, warm and hot LUT cache) and a full-resolution export, for the old pipeline and the current one. It writes a synthetic 6000 x 4000 JPEG to `build/bench/` (never committed). Preview render, thumbnail batch, source load, export, asset open and grid thumbnail requests are `os_signpost` intervals (subsystem `com.fieldframes.mira`, category `perf`) for Instruments.

**MiraUI** holds `EditorModel` (source, recipe, rendering) and `EditorView` (preview, film strip, inspector). `EditorView` reports the canvas size in pixels to the model; `FrameCanvas` hands each frame's IOSurface to a layer. Large files open from a quick ImageIO reduced decode and are decoded in full in the background (`isSourceFull`, `fullSource()`); orientation is applied once, when the file is loaded. Film-strip thumbnails (256 px) come from one small base made from the full-size source with the current crop applied, are rendered a few at a time, and are cached per crop. Hovering a film card renders it over the preview after a short debounce (60 ms) without touching the recipe.

**App** has two modes. The library mode (`LibraryStore`, `LibraryView`) shows the Photos library through a `PHCachingImageManager` grid whose thumbnail size follows the cell size times the backing scale. Opening a Photos picture shows the cached grid thumbnail at once, then a larger one, then the full-size photo once the editing input has loaded. The editor mode wraps `EditorView` with Library, Open, Films, Export, Save and Revert in the toolbar, plus a footer showing the sidecar or Photos status, notes and progress. `AssetEditSession` loads an asset's editing input and saves or reverts through PhotoKit. Files from disk open through the Open panel, drag and drop, or the launch arguments, and a films browser carries the licence credit. In-app switching away from a Photos edit with unsaved changes asks whether to save or discard.

**PhotosExtension** hosts the same `EditorView`. On start it decodes any existing adjustment data into the recipe and loads `fullSizeImageURL`; on Save it encodes the recipe as adjustment data and renders the full-size image to the type Photos prefers (JPEG, HEIC or TIFF), falling back to JPEG. Cancel asks for confirmation only if the recipe has changed.

The Films folder is bundled in both the app and the extension, since the extension is sandboxed and cannot read the host's bundle.

## Requirements

- macOS 26 or later
- Xcode 27 (Swift 6, strict concurrency)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen), used only during development to generate `Mira.xcodeproj` from `project.yml`
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
swift test --package-path Packages/MiraCore   # 36 tests
swift test --package-path Packages/MiraUI     # 12 tests
```

MiraUI also writes headless snapshots to `build/snapshots`. The test list is in [TESTING.md](TESTING.md).

### Photos self-test

```sh
open -a /Applications/Mira.app --args --selftest-photos
```

Imports `App/SelfTest/sample.jpg` into an album called "Emulsion Test" (it never touches existing photos), saves Velvia with grain through the same `AssetEditSession` code the app uses, checks `hasAdjustments` and the recipe round trip, reverts and checks again. It logs `SELFTEST ...` lines under subsystem `com.fieldframes.mira`, category `selftest`:

```sh
log show --last 10m --info --predicate 'subsystem == "com.fieldframes.mira"' | grep SELFTEST
```

The test asset stays in the library; delete it by hand. `--selftest-sidecar` runs the sidecar equivalent.

## Licensing

- **Code:** All rights reserved, licence TBD. No licence file exists for the source yet.
- **Film LUTs:** the files in `Films/HaldCLUT/` are from the RawTherapee Film Simulation Collection (2015-09-20) by Pat David, with Pavlov Dmitry and Michael Ezra credited in the archive, and are licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Full attribution, the source URL and the mapping from each file to its original name are in [Films/ATTRIBUTION.md](Films/ATTRIBUTION.md). The PNG files are redistributed unmodified, byte for byte, only renamed; Mira resamples them to 64³ at load time in memory only. Derivative works of the LUTs must be shared under the same licence.
- **Trademarks:** film stock names are used for information only. Mira is not affiliated with, or endorsed by, any film maker or the trademark owners.
- **Fonts:** Cormorant Garamond and IBM Plex Mono are bundled in `Packages/MiraUI/Sources/MiraUI/Resources/Fonts/` under the SIL Open Font License 1.1. The licence texts are alongside (`OFL-CormorantGaramond.txt`, `OFL-IBMPlexMono.txt`).
- **Sample photo:** `Fixtures/sample.jpg` is "Outdoor portrait" by Anthony Ginsbrook (Unsplash), CC0 1.0, downscaled to 2400x1600. See [Fixtures/SOURCE.md](Fixtures/SOURCE.md).

## Renamed from Emulsion

Mira was called Emulsion until v0.2. The bundle ids changed (`com.fieldframes.mira`, `com.fieldframes.mira.photos`), so macOS asks for Photos access again and the extension must be re-enabled in System Settings. Existing edits and sidecars keep working: see Re-editable edits and Files from disk above. The self-test album keeps its old name, "Emulsion Test".
