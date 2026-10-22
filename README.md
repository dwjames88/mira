# Mira

*Software by FieldFrames.*

Mira is an original film-emulation app for macOS. It ships as a **Photos editing extension**, so you can apply a film look to any picture from inside Photos, plus a **host app** that browses your Photos library and also edits files from disk. There is no watermark, no paywall and no account.

Status: v0.2.0. See [CHANGELOG.md](CHANGELOG.md) for what changed. See [TESTING.md](TESTING.md) for what has and has not been verified, and [docs/ROADMAP.md](docs/ROADMAP.md) for what comes next.

## Install

1. Download `Mira-0.2.0.dmg` (or the `.zip`) from the release page and drag **Mira** to Applications.
2. Mira is signed with a free Personal Team development certificate. There is no Developer ID and it is not notarized, so on other Macs macOS blocks the first launch. Right-click Mira, choose Open, then Open again. Or try to open it once, then go to System Settings ▸ Privacy & Security and click "Open Anyway".
3. Development-signed builds may refuse to run at all on a Mac that is not registered to the signing team. If so, build from source: `scripts/install.sh` (needs Xcode, XcodeGen and your own team ID in `project.yml`).
4. Enable the extension in System Settings ▸ General ▸ Login Items & Extensions ▸ Photos Editing ▸ Mira, and grant Photos access on first launch.
5. The free-team signature expires after 7 days; after that the app and extension may stop loading until you rebuild.

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

- Sliders: Strength (film blend); Light: Exposure, Contrast, Highlights, Shadows, Whites, Blacks; Presence: Texture, Clarity, Vibrance, Saturation; Color: Temperature, Tint; then Grain and Grain Size, Halation and Halation Radius, Bloom, Vignette, and an optional paper Border with width. Double-click a slider label to reset it. Edits that use Highlights, Shadows, Whites, Blacks, Texture, Clarity or Vibrance are saved as adjustment format version 2; older builds do not open them, and recipes that leave them at 0 are still written as version 1.
- **Crop.** Non-destructive crop, 90-degree rotation, flips and straighten (-45 to 45 degrees, auto-fitted so there are no empty corners), with aspect presets. It is part of the recipe (`Recipe.crop`, decoded with defaults, so older recipes still open), applied first in the renderer so grain, halation, vignette and border follow the cropped frame, and exports use the cropped size. Press 3 or choose the CROP tab (View ▸ Crop); Done keeps the crop and goes back to the previous tab, Cancel puts back the crop you had, and leaving the tab commits. The pure maths is `CropGeometry` in MiraCore. The crop rect is normalised (top-left origin, y down) in the oriented-and-straightened canvas: rotate90, then flips, then straighten about the centre.
- Live preview, hover preview (hovering a film card shows it on the canvas with the current sliders and a "PREVIEW · FILM" label, without changing the recipe; the extension does the same), a film strip with live thumbnails filtered by family, and press-and-hold Compare to see the original.
- **Re-editable edits.** The full recipe is saved as Photos adjustment data (format identifier `com.fieldframes.mira`, version `1`), so reopening an edited photo in Mira restores every slider, and Revert to Original works as usual. Recipes decode with defaults for missing keys, so future versions stay compatible. The app and the extension use one codec (`MiraAdjustment` in MiraCore), so an edit made in either reopens in the other. Photos edited before the rename (identifier `com.dwjames.emulsion`, version `1`) are still recognised and reopen with their recipe; new saves always write `com.fieldframes.mira`. `MiraAdjustment.legacyFormatIdentifiers` lists the old ones.
- **Photos library in the app.** The host app browses the library in the manner of Photomator: a sidebar (All Photos, Favourites, your albums, and the non-empty smart albums including RAW) and a thumbnail grid with RAW and EDITED badges. Double-click or press Return to open a picture. Saving is non-destructive and goes through PhotoKit: a full-size JPEG (quality 0.95, orientation baked in, Display P3 for RAW) plus the adjustment data. The original is never modified, Photos shows the edit, and Revert to Original in Photos works. The in-app Revert uses `revertAssetContentToOriginal`. A picture edited by another app opens from its original, with a note that saving replaces those edits. This needs Photos permission (`NSPhotoLibraryUsageDescription` and the `com.apple.security.personal-information.photos-library` entitlement); the app asks at launch.
- **RAW.** Camera RAW files are decoded with `CIRAWFilter` (default decode), honouring Photos' `fullSizeImageOrientation`, and exported in Display P3.
- **Files from disk.** Open or drag in a photo, or launch with `open -a Mira photo.jpg` or Finder's Open With (the app registers as a Viewer for common image types, with Alternate rank). The file is never overwritten. The recipe autosaves to a sidecar, `<filename>.mira.json`, next to the image when its folder is writable. Under the App Sandbox, which only grants access to the chosen file, that is rarely the case, so the sidecar goes to `~/Library/Containers/com.fieldframes.mira/Data/Library/Application Support/Mira/Sidecars/<sha256 of path>.mira.json`. The editor footer shows which is in use. A legacy `<filename>.emulsion.json` (and the old fallback copy) is still read when no `.mira.json` exists; the next save writes the new file and removes the legacy one. Revert deletes the sidecar(s), new and legacy. Export writes a new file as JPEG, HEIC or TIFF (16-bit) with source metadata kept.
- **Field Frames design.** The app and extension share the Field Frames look (ink ground, warm paper text, lichen accent, Cormorant Garamond and IBM Plex Mono, grain, a character-cell grid, square corners). The window toolbar carries only the wordmark; commands live in the menu bar and the editor strip (tabs FILMS, PRESETS, DEVELOP, CROP). See [Design/THEME.md](Design/THEME.md).
- **Presets.** Save the film and every develop setting as one preset with a nickname, named "<film> - <nickname>" (for example "Portra 400 - Last Summer"; a look with no film is "Original - <nickname>"). Open the PRESETS tab (key 4, next to FILMS) for a card strip like the film strip: thumbnails of the current photo with each preset's look, hover previews it on the canvas without touching the recipe, click applies it. Applying sets the film and all develop values but keeps the photo's own crop (a preset never stores a crop), and you can keep adjusting afterwards. Right-click a card for Rename…, Duplicate and Delete…. SAVE PRESET… in the tab (also in the Photos extension) or Preset ▸ Save as Preset… (⇧⌘S) opens a sheet with the film as a fixed prefix, a nickname field and a live preview of the final name. If a preset's film is no longer installed the card is marked FILM MISSING and applying it applies the develop settings only, with a notice. A preset is one `Recipe` (so new develop controls are included automatically); code is `Preset` and `PresetStore` in MiraCore and `EditorModel+Presets`, `PresetsPanel`, `SavePresetSheet` in MiraUI.
- **Shared storage (App Group).** Presets live in one JSON file, `Presets.json` (`{"version":1,"presets":[...]}`), at `<App Group container>/Library/Application Support/Mira/` for the group `VF945J28YU.com.fieldframes.mira`, which both the app and the Photos extension declare (`com.apple.security.application-groups` in `project.yml` and both entitlements files; a team-ID-prefixed group needs no registration on macOS). Without the group the file falls back to the process's own `Application Support/Mira`. Each process reloads when the file's modification date changes (when the tab opens, the app becomes active, and every two seconds while the tab is showing), writes are atomic, and an unreadable file is copied to `Presets.json.bak` before the store starts empty. Settings, films and sidecars are unchanged.
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
3. Contrast (on sRGB-encoded values), then one Metal kernel for Highlights, Shadows, Whites and Blacks (masks follow a blurred luminance so highlights and shadows act locally; whites and blacks are monotonic end-point curves; luminance is changed by scaling RGB so hue holds), then Texture (small radius) and Clarity (large radius, midtone-weighted) as local contrast on luminance, then Saturation and Vibrance. Radii scale with the image, so preview and export match. With none of the new values set, contrast and saturation share one pass as before
4. Warmth and tint (linear light)
5. Halation (thresholded, blurred, warm-tinted highlights screened back on)
6. Bloom
7. Grain (deterministic noise, soft-light blended in sRGB-encoded space)
8. Vignette
9. Border (cream paper frame outside the image extent)

**Colour management.** The shared `CIContext` works in extended linear sRGB with half-float intermediates (Metal-backed when available). The film LUTs are authored on sRGB-encoded values, so each cube is applied with `CIColorCubeWithColorSpace` and its colour space set to sRGB: Core Image converts into encoded sRGB, looks up, and converts back, with no manual curve handling. Contrast, saturation and grain are wrapped in explicit linear-to-sRGB and sRGB-to-linear tone curves so they behave perceptually. Export renders in Display P3 when the source is wide-gamut and sRGB otherwise; TIFF is 16-bit, JPEG and HEIC are 8-bit.

**LUTs.** `FilmLibrary` reads `films.json` and loads each HaldCLUT PNG lazily, caching the result in memory. Cubes larger than 64 are trilinearly resampled to 64³ (`.cube` parsing is also implemented). The resampled 64³ cube is also written to a disk cache in `Library/Caches/<bundle id>/LUTs` (16-bit, keyed on file size, modification time and format version), so a large PNG is decoded once per install. Loading all 31 films cold takes about 0.3 to 0.5 s with parallel loading (4 to 8 workers), against about 2 s before; warm it takes about 19 ms. The app prewarms the library at launch and builds thumbnails in parallel. `mira-sheet --time-luts --films Films` prints these timings. The PNGs on disk are untouched.

**Source loading and adjustments.** `ImageSource` loads photos upright and decodes camera RAW with `CIRAWFilter` (default decode), applying Photos' `fullSizeImageOrientation` when it is given; RAW exports in Display P3. `MiraAdjustment` is the single place that encodes and decodes a `Recipe` as Photos adjustment data, shared by the app and the extension. `SidecarStore` reads and writes the sidecar for files opened from disk; the JSON holds `formatIdentifier`, `formatVersion`, `recipe`, and `sourcePath`, `bookmark` and `modified` for reference.

**Preview pipeline.** `PreviewEngine` (MiraCore) renders interactive previews at the size of the canvas. The slider-independent part, crop, rotation, straighten and the downscale to canvas size, is done once per (source, crop, size) and kept as a half-float bitmap; a slider change only runs the grading graph on that bitmap (`Renderer.grade`). The crop is cut from the best level of a power-of-two pyramid of the full-size source, so a tight crop stays sharp and a whole-picture preview reads a small level. Frames render into IOSurface-backed pixel buffers tagged sRGB. `PreviewSizing` decides the render size (canvas pixels, never upscaled, capped at 3072 px, 1600 px until the view reports its size) and `RenderGate` coalesces requests: one render in flight, the latest request waits and replaces older ones. Halation blurs of 8 px or more run on a 1/4 (or 1/2) size copy. Zoomed views (`ZoomGeometry` in MiraCore holds the click, step and pan rules) render only the visible region of the full-resolution crop at the zoom scale through `PreviewEngine.renderZoomed`: the grade runs on a lazy scaled copy of the crop and Core Image renders just the region of interest (about 8 ms at 100%, 1500x1000, 24 MP). One shared `CIContext` (`Renderer.sharedContext`) serves previews, thumbnails, hover renders and export.

**Performance harness.** `mira-sheet --bench --films Films` times preview frames at canvas resolution, opening a 24 MP JPEG, the 32-thumbnail film strip (cold, warm and hot LUT cache) and a full-resolution export, for the old pipeline and the current one, plus film switching, histogram and launch timings. `Packages/MiraUI` has an opt-in UI timing test (`MIRA_PERF=1`); numbers and method are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md). It writes a synthetic 6000 x 4000 JPEG to `build/bench/` (never committed). Preview render, thumbnail batch, source load, export, asset open and grid thumbnail requests are `os_signpost` intervals (subsystem `com.fieldframes.mira`, category `perf`) for Instruments.

**MiraUI** holds `EditorModel` (source, recipe, tab, zoom, rendering) and `EditorView` (sub-toolbar with the FILMS / DEVELOP / CROP tabs, preview, and the film strip and right panel each tab brings; `EditorKeyMap` is the table of single-key shortcuts). `EditorView` reports the canvas size in pixels to the model; `FrameCanvas` hands each frame's IOSurface to a layer. Large files open from a quick ImageIO reduced decode and are decoded in full in the background (`isSourceFull`, `fullSource()`); orientation is applied once, when the file is loaded. Film-strip thumbnails (256 px) come from one small base made from the full-size source with the current crop applied, are rendered a few at a time, and are cached per crop. Hovering a film card renders it over the preview after a short debounce (60 ms) without touching the recipe.

**App** has two modes. The library mode (`LibraryStore`, `LibraryView`) shows the Photos library through a `PHCachingImageManager` grid whose thumbnail size follows the cell size times the backing scale. Opening a Photos picture shows the cached grid thumbnail at once, then a larger one, then the full-size photo once the editing input has loaded. The editor mode wraps `EditorView` with `← LIBRARY`, the status and SAVE in the editor strip (the rest is in the File and Edit menus), plus a footer under the canvas showing the sidecar or Photos status, notes and progress. `AssetEditSession` loads an asset's editing input and saves or reverts through PhotoKit. Files from disk open through the Open panel, drag and drop, or the launch arguments, and a films browser carries the licence credit. In-app switching away from a Photos edit with unsaved changes asks whether to save or discard.

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

- **Code:** [PolyForm Noncommercial License 1.0.0](LICENSE). Free for noncommercial use; see the file for the exact terms.
- **Film LUTs:** the files in `Films/HaldCLUT/` are from the RawTherapee Film Simulation Collection (2015-09-20) by Pat David, with Pavlov Dmitry and Michael Ezra credited in the archive, and are licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Full attribution, the source URL and the mapping from each file to its original name are in [Films/ATTRIBUTION.md](Films/ATTRIBUTION.md). The PNG files are redistributed unmodified, byte for byte, only renamed; Mira resamples them to 64³ at load time in memory only. Derivative works of the LUTs must be shared under the same licence.
- **Trademarks:** film stock names are used for information only. Mira is not affiliated with, or endorsed by, any film maker or the trademark owners.
- **Fonts:** Cormorant Garamond and IBM Plex Mono are bundled in `Packages/MiraUI/Sources/MiraUI/Resources/Fonts/` under the SIL Open Font License 1.1. The licence texts are alongside (`OFL-CormorantGaramond.txt`, `OFL-IBMPlexMono.txt`).
- **Sample photo:** `Fixtures/sample.jpg` is "Outdoor portrait" by Anthony Ginsbrook (Unsplash), CC0 1.0, downscaled to 2400x1600. See [Fixtures/SOURCE.md](Fixtures/SOURCE.md).

## Renamed from Emulsion

Mira was called Emulsion until v0.2. The bundle ids changed (`com.fieldframes.mira`, `com.fieldframes.mira.photos`), so macOS asks for Photos access again and the extension must be re-enabled in System Settings. Existing edits and sidecars keep working: see Re-editable edits and Files from disk above. The self-test album keeps its old name, "Emulsion Test".
