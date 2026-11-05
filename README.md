# Mira

*Software by FieldFrames.*

Mira is an original film-emulation app for macOS. It ships as a **Photos editing extension**, so you can apply a film look to any picture from inside Photos, plus a **host app** that browses your Photos library and also edits files from disk. There is no watermark, no paywall and no account.

Status: v1.0.0. See [CHANGELOG.md](CHANGELOG.md) for what changed. See [TESTING.md](TESTING.md) for what has and has not been verified, and [docs/ROADMAP.md](docs/ROADMAP.md) for what comes next.

## Install

1. Download `Mira-1.0.0.dmg` (or the `.zip`) from the release page and drag **Mira** to Applications.
2. Mira is signed with a free Personal Team development certificate. There is no Developer ID and it is not notarized, so on other Macs macOS blocks the first launch. Right-click Mira, choose Open, then Open again. Or try to open it once, then go to System Settings ▸ Privacy & Security and click "Open Anyway".
3. Development-signed builds may refuse to run at all on a Mac that is not registered to the signing team. If so, build from source (see Build and run the Mac app: Xcode, XcodeGen and your own team ID in `Local.xcconfig`) and run `scripts/install.sh`.
4. Enable the extension in System Settings ▸ General ▸ Login Items & Extensions ▸ Photos Editing ▸ Mira, and grant Photos access on first launch.
5. The free-team signature expires after 7 days; after that the app and extension may stop loading until you rebuild.

## Features

- 264 bundled film looks, shown as 86 stock cards: 260 from the RawTherapee Film Simulation Collection by Pat David and contributors (CC BY-SA 4.0) and 4 Mira originals generated in code (500T Tungsten, 250D Daylight, Cinema Print, Color Paper; no affiliation with Kodak or Fujifilm). The other 178 looks are push/pull and tone variants of a stock (for example Pro 160C −1 or Portra 400 NC) and are chosen with the Variant picker in the FILMS panel. Families (stocks, variants): Color Negative 26 (46), Slide 15 (3), Kodachrome 3 (1), Black & White 22 (18), Instant 16 (110), Motion Picture 2 (0), Print 2 (0); all seven family tabs are populated. The Motion Picture and Print stocks are Mira originals because no freely licensed data exists for them (the print and picturefx folders of the cyangraphics/NatronGitHub clut repository and G'MIC's Fuji X-Trans III set carry no redistribution licence, and the Pat David material there duplicates the RawTherapee set). Stocks only:

| Family | Brand | Stocks (ISO) |
|--------|-------|--------------|
| Color Negative (C-41): 26 stocks, 46 variants | Agfa | Ultra Color 100 (100), Vista 200 (200) |
|  | Fujifilm | Pro 160C (160), Pro 400H (400), Pro 800Z (800), Superia 100 (100), Superia 1600 (1600), Superia 200 (200), Superia 400 (400), Superia 800 (800), Superia HG 1600 (1600), Superia Reala 100 (100), Superia X-Tra 800 (800) |
|  | Kodak | Ektar 100 (100), Elite 100 XPRO (100), Elite Color 200 (200), Elite Color 400 (400), Portra 160 (160), Portra 160 NC (160), Portra 160 VC (160), Portra 400 (400), Portra 400 NC (400), Portra 400 UC (400), Portra 400 VC (400), Portra 800 (800) |
|  | Lomography | Redscale 100 (100) |
| Slide (E-6): 15 stocks, 3 variants | Agfa | Precisa 100 (100) |
|  | Fujifilm | Astia 100F (100), Provia 100F (100), Provia 400F (400), Provia 400X (400), Sensia 100 (100), Superia 200 XPRO (200), Velvia 100 (100), Velvia 50 (50) |
|  | Kodak | E100GX (100), Ektachrome 100 VS (100), Elite Chrome 200 (200), Elite Chrome 400 (400), Elite ExtraColor 100 (100) |
|  | Lomography | X-Pro Slide 200 (200) |
| Kodachrome (K-14): 3 stocks, 1 variants | Kodak | Kodachrome 200 (200), Kodachrome 25 (25), Kodachrome 64 (64) |
| Black & White: 22 stocks, 18 variants | Agfa | APX 100 (100), APX 25 (25) |
|  | Fujifilm | Neopan 1600 (1600), Neopan Acros 100 (100) |
|  | Ilford | Delta 100 (100), Delta 3200 (3200), Delta 400 (400), FP4 Plus 125 (125), HP5 Plus 400 (400), HPS 800 (800), Pan F Plus 50 (50), XP2 400 (400) |
|  | Kodak | BW 400 CN (400), HIE (HS Infra) (400), T-Max 100 (100), T-Max 3200 (3200), T-Max 400 (400), Tri-X 400 (400) |
|  | Rollei | IR 400 (400), Ortho 25 (25), Retro 100 Tonal (100), Retro 80s (80) |
| Instant: 16 stocks, 110 variants | Fujifilm | FP-100C (100), FP-100C Negative (100), FP-3000B (3000), FP-3000B Negative (3000) |
|  | Polaroid | 664 (100), 665 (80), 665 Negative (80), 667 (3000), 669 (80), 672 (3000), 690 (80), PX-100UV+ (100), PX-680 (600), PX-70 (80), Polachrome (40), Time Zero Expired (80) |
| Motion Picture (ECN-2): 2 stocks | Mira | 500T Tungsten (500), 250D Daylight (250) |
| Print: 2 stocks | Mira | Cinema Print, Color Paper (print stocks, no ISO) |

- **Film science (pipeline 2).** Choosing a film opts a recipe into `Recipe.pipeline` 2, where the order follows the light: crop, exposure (with the film's latitude, so highlights roll off like a negative's shoulder, the push/pull gain, and for RAW and HDR sources a scene-referred headroom shoulder), white balance, reciprocity (the exposure time), dodge & burn, mixer, curves, halation (highlights are blurred at two radii and put back tinted, with partial compensation so clipped lights keep their cores; rem-jet for motion-picture stocks), film LUT (a float tetrahedral kernel on the sRGB-encoded cube), Paper or scan profile with push contrast and black lift, B&W toning, contrast / tone / presence, bloom, grain, vignette and border. Each film has a character derived from its family and ISO (`FilmCharacter`), with overrides in `films.json`. Grain is per film, density dependent, chromatic for colour films, and measured relative to the frame diagonal and band-limited so previews match exports. The Grain and Halation sliders read 50% as the film's own amount. FILMS panel: Variant picker; Push/Pull from −2 to +2 stops in thirds; Exposure time and Reciprocity; Scan (Neutral, Frontier-like, Noritsu-like, our own transforms, not the vendors'); Paper (None, Cinema Print, Color Paper; replaces Scan, hidden on print cards and on monochrome films, which are toned instead); Toning for monochrome films; a rem-jet toggle that appears only on motion-picture stocks (the two Mira motion-picture looks). A Latitude readout under the histogram and in FILMS shows how many stops of the scene the film holds. Recipes saved without a `pipeline` key (legacy) render exactly as before. Recipes with pipeline 2 are saved as Photos adjustment format version 4, which older builds refuse; versions 1 to 3 still read. Stage by stage, with every number and the reasoning behind it, in [Design/FILM-SCIENCE.md](Design/FILM-SCIENCE.md).
- **Exposure time and reciprocity.** Long exposures make film lose speed, shift colour, gain contrast and get grainier in the shadows. The EXPOSURE TIME slider (log scale, snapping to standard shutter speeds) starts at the photo's EXIF time and double-click on its label returns to it; Reciprocity is Off, Compensated (the default: brightness kept, the cast, contrast and shadow grain of the datasheet remain) or Uncompensated (also darker by the lost stops). 41 stocks carry manufacturer datasheet data (Ilford's `t^p` rule, Kodak, Fuji, Agfa and Polaroid tables, each with its source URL in `films.json`); every other film uses its family's default, and the panel says when the time is beyond the datasheet. At 1/125 s every film is an exact no-op. The research, the model and its limits are in section 4 of [Design/FILM-SCIENCE.md](Design/FILM-SCIENCE.md).
- **RAW development.** For RAW sources `RawDevelop` and `SourceDevelop` (MiraCore) drive `CIRAWFilter`, and the DEVELOP tab shows a RAW group: white balance (as shot, or kelvin and tint), Boost (Auto means 0 when a film is chosen, so the film supplies the curve), Highlight Recovery (extended dynamic range; Auto means maximum with a film), local tone map, noise reduction, sharpness and lens correction. The camera's baseline exposure is respected. Previews use a draft decode and re-develop after a short debounce; export develops at full quality. Presets keep only boost, tone map and highlight recovery, not white balance or per-camera settings. In the Mac library an ALL / RAW toggle next to Filter limits the grid to RAW files.
- Sliders: Strength (film blend); Light: Exposure, Contrast, Highlights, Shadows, Whites, Blacks; Presence: Texture, Clarity, Vibrance, Saturation; Color: Temperature, Tint; then Grain and Grain Size, Halation and Halation Radius, Bloom, Vignette, and an optional paper Border with width. Double-click a slider label to reset it. Edits that use Highlights, Shadows, Whites, Blacks, Texture, Clarity or Vibrance are saved as adjustment format version 2, and edits with Dodge & Burn strokes as version 3; older builds do not open them, and recipes that use neither are still written as version 1.
- **Crop.** Non-destructive crop, 90-degree rotation, flips and straighten (-45 to 45 degrees, auto-fitted so there are no empty corners), with aspect presets. It is part of the recipe (`Recipe.crop`, decoded with defaults, so older recipes still open), applied first in the renderer so grain, halation, vignette and border follow the cropped frame, and exports use the cropped size. Press 1 or choose the CROP step (View ▸ Crop); Done keeps the crop and goes back to the previous tab, Cancel puts back the crop you had, and leaving the tab commits. The pure maths is `CropGeometry` in MiraCore. The crop rect is normalised (top-left origin, y down) in the oriented-and-straightened canvas: rotate90, then flips, then straighten about the centre.
- **Dodge & Burn.** The fourth step, DODGE & BURN (key 4; the editor steps are 1 CROP, 2 FILMS, 3 DEVELOP, 4 DODGE & BURN). The brush tool is open while the step shows (entering it opens the tool; leaving it, or starting a crop, closes it; the step keys still work): drag on the photo (fitted or zoomed) to paint. DODGE lightens, BURN darkens, ERASE removes what earlier strokes put under the brush. Sliders: Size (percent of the photo's short side), Feather (0 hard edge, 100 falls off from the centre), Flow (how much each dab adds), Strength (the most a stroke can do, up to about two stops); Range (SHADOWS, MIDTONES, HIGHLIGHTS) weights the change by tone; PROTECT TONES softly limits it so dodge never clips and burn never crushes to black; LUMINOSITY RANGE (low, high, softness) limits a stroke to a band of tones. The cursor is the brush ring (outline is the size, the dashed inner ring is where the feather starts, a plus, minus or cross shows dodge, burn or erase). Tablet pressure scales each dab when the pen reports it; a mouse or trackpad paints at full pressure. The STROKES list shows each stroke (mode, range, strength), an eye to hide it, a delete button; click a row to edit that stroke's settings instead of the brush's; CLEAR ALL removes every stroke. MASK OVERLAY washes the painted area red (never part of an export). Each finished stroke is one edit, so UNSAVED and saving work as for any slider. Keys while the tool is open: `[` and `]` smaller and bigger brush, ⌘= and ⌘- zoom (the menu's `[` `]` items are shadowed by the brush keys; pinch, scroll and Space-drag still work), hold ⌥ as a stroke starts to flip dodge and burn for that stroke, O mask overlay, Esc leaves the step (back to DEVELOP). Strokes belong to the photo, like the crop: they are stored normalised to the uncropped upright source (brush size relative to its short side) in `Recipe.dodgeBurn`, so they stay put when the crop, rotation or straighten changes; presets and `.mirapreset` files never carry them and applying a preset keeps them; sidecars and Photos adjustment data do (format version 3, written only when strokes exist). In the renderer the strokes become masks (`DodgeBurnMask`) and one Core Image kernel (`miraDodgeBurn` in `Grade.ci.metal`) applies an exposure-like gain to linear light, weighted by mask, tone range and luminosity band, as a luma ratio so hue is kept; it runs right after Exposure, before the mixer, curves and film, so the film responds to it. The same views work in the Photos extension.
- Live preview, hover preview (hovering a film card shows it on the canvas with the current sliders and a "PREVIEW · FILM" label, without changing the recipe; the extension does the same), a film strip with live thumbnails filtered by family, and press-and-hold Compare to see the original.
- **Re-editable edits.** The full recipe is saved as Photos adjustment data (format identifier `com.fieldframes.mira`, version `1`), so reopening an edited photo in Mira restores every slider, and Revert to Original works as usual. Recipes decode with defaults for missing keys, so future versions stay compatible. The app and the extension use one codec (`MiraAdjustment` in MiraCore), so an edit made in either reopens in the other. Photos edited before the rename (identifier `com.dwjames.emulsion`, version `1`) are still recognised and reopen with their recipe; new saves always write `com.fieldframes.mira`. `MiraAdjustment.legacyFormatIdentifiers` lists the old ones.
- **Photos library in the app.** The host app browses the library in the manner of Photomator: a sidebar (All Photos, Favourites, your albums, and the non-empty smart albums including RAW) and a thumbnail grid with RAW and EDITED badges. Double-click or press Return to open a picture. Saving is non-destructive and goes through PhotoKit: a full-size JPEG (quality 0.95, orientation baked in, Display P3 for RAW) plus the adjustment data. The original is never modified, Photos shows the edit, and Revert to Original in Photos works. The in-app Revert uses `revertAssetContentToOriginal`. A picture edited by another app opens from its original, with a note that saving replaces those edits. This needs Photos permission (`NSPhotoLibraryUsageDescription` and the `com.apple.security.personal-information.photos-library` entitlement); the app asks at launch.
- **RAW.** Camera RAW files are decoded with `CIRAWFilter` (default decode; with a film, extended range, whose measured peak becomes the scene-referred headroom of the exposure stage), honouring Photos' `fullSizeImageOrientation`, and exported in Display P3.
- **Files from disk.** Open or drag in a photo, or launch with `open -a Mira photo.jpg` or Finder's Open With (the app registers as a Viewer for common image types, with Alternate rank). The file is never overwritten. The recipe autosaves to a sidecar, `<filename>.mira.json`, next to the image when its folder is writable. Under the App Sandbox, which only grants access to the chosen file, that is rarely the case, so the sidecar goes to `~/Library/Containers/com.fieldframes.mira/Data/Library/Application Support/Mira/Sidecars/<sha256 of path>.mira.json`. The editor footer shows which is in use. A legacy `<filename>.emulsion.json` (and the old fallback copy) is still read when no `.mira.json` exists; the next save writes the new file and removes the legacy one. Revert deletes the sidecar(s), new and legacy. Export writes a new file as JPEG, HEIC or TIFF (16-bit) with source metadata kept.
- **Field Frames design.** The app and extension share the Field Frames look (ink ground, warm paper text, lichen accent, Cormorant Garamond and IBM Plex Mono, grain, a character-cell grid, square corners). The window toolbar carries only the wordmark; commands live in the menu bar and the editor strip (steps CROP, FILMS, DEVELOP, DODGE & BURN). See [Design/THEME.md](Design/THEME.md).
- **Presets.** Save the film and every develop setting as one preset with a nickname, named "<film> - <nickname>" (for example "Portra 400 - Last Summer"; a look with no film is "Original - <nickname>"). Presets live in the FILMS tab, in the same card strip as the films: a PRESETS group first (shown whatever the family filter is), then FILMS. Thumbnails show the current photo with each preset's look, hover previews it on the canvas without touching the recipe, click applies it. A preset stores the film (including its variant id), push/pull, scan or paper, toning, the exposure time and reciprocity settings, grain, halation and bloom, and every Develop control; it never stores the crop or the dodge & burn strokes, which belong to the photo. Of the RAW settings it keeps boost, tone map and highlight recovery; RAW white balance, noise reduction, sharpening and lens correction are per shot and stay with the photo (the one exception). Applying sets the film and all those values but leaves the photo's own crop and strokes untouched, and you can keep adjusting afterwards. The FILMS panel names the preset the look matches. Right-click a card for Share…, Export… (app only), Rename…, Duplicate and Delete…. SAVE PRESET… in the strip and panel (also in the Photos extension) or Preset ▸ Save as Preset… (⇧⌘S) opens a sheet with the film as a fixed prefix, a nickname field and a live preview of the final name. If a preset's film is no longer installed the card is marked FILM MISSING and applying it applies the develop settings only, with a notice. A preset is one `Recipe` (so new develop controls are included automatically); code is `Preset`, `PresetStore`, `PresetFile` and `PresetImport` in MiraCore and `EditorModel+Presets`, `PresetStrip`, `PresetTransfer`, `SavePresetSheet` in MiraUI.
- **Share.** The Share button (`square.and.arrow.up`) sits left of SAVE in the editor strip, and File ▸ Share… (⌥⌘S) does the same. It renders the current look at full resolution from the decoded full-size source, off the main actor, through `Renderer.export` (so metadata, orientation 1 and the colour-space rule match File ▸ Export), into a per-launch temporary folder as `<original name> - Mira.jpg` (or .heic/.tiff, whichever format and quality File ▸ Export last used; default JPEG 0.92), then opens the system share sheet on that file (AirDrop, Messages, Mail, Photos, Notes). From the button the sheet hangs from it; from the menu it hangs from the window centre. The button shows a spinner and ignores clicks while rendering; after about 300 ms a "Preparing to share" overlay appears; errors use the usual alert. The previous share file is deleted on the next share and stale folders on launch. Disabled with no photo, while loading, exporting or cropping. App only (the Photos extension has no file access and no button); the Library grid does not share yet. Code: `ShareRender` (MiraCore), `EditorHostBar.Share` (MiraUI), `AppState+Share` (app).
- **Sharing presets.** A preset exports as one `<Film> - <nickname>.mirapreset` file (JSON with sorted keys: `format` `com.fieldframes.mira.preset`, `schemaVersion` 1, `appVersion`, `exported`, and the preset's nickname, film id and name, creation date and develop recipe; no photo data, no crop). Share… on a card opens the system share sheet (AirDrop, Messages, Mail); Export… saves the file; Preset ▸ Export All Presets… writes one file per preset into a folder. To import, use Preset ▸ Import Presets… (⇧⌘I), drag `.mirapreset` files onto the strip or window, or double-click one in Finder (Mira is the default opener and imports even with no photo open). A preset whose "<Film> - <nickname>" already exists asks Replace, Keep Both (nickname gets " 2", " 3"…) or Skip, with Apply to all for several files; files that are not Mira presets, or were made by a newer Mira, are reported by name and the rest still import. Imported presets go through the shared App Group file, so they appear in the Photos extension too. Sharing and import are app-only (the extension has no file access).
- **Shared storage (App Group).** Presets live in one JSON file, `Presets.json` (`{"version":1,"presets":[...]}`), at `<App Group container>/Library/Application Support/Mira/` for the group `VF945J28YU.com.fieldframes.mira`, which both the app and the Photos extension declare (`com.apple.security.application-groups` in `project.yml` and both entitlements files; a team-ID-prefixed group needs no registration on macOS). Without the group the file falls back to the process's own `Application Support/Mira`. Each process reloads when the file's modification date changes (when the tab opens, the app becomes active, and every two seconds while the tab is showing), writes are atomic, and an unreadable file is copied to `Presets.json.bak` before the store starts empty. Settings, films and sidecars are unchanged.
- Resolution independent: grain, halation and bloom scale with the image, so a preview and a full-size export look the same.

## Repository layout

```
App/                     Host app (SwiftUI): window, Photos library browser, open/drop, export sheet, films browser; SelfTest/ sample
PhotosExtension/         Photos editing extension (PHContentEditingController)
Packages/MiraCore/   Pipeline: Recipe, Film, FilmLibrary, LUT, Renderer, MiraAdjustment, ImageSource, SidecarStore; MiraUpdates (updater logic); tests; mira-sheet CLI
Packages/MiraUI/     Shared SwiftUI editor (EditorView, EditorModel, FilmsBrowserView) and FieldFramesTheme with bundled fonts
Films/                   Bundled (126 MB per copy): films.json, Packed/*.mlut (260 cubes, 48^3, 56^3 or 64^3), ATTRIBUTION.md, LICENSE-LUTS
FilmSources/             Not in git (git-ignored): HaldCLUT/*.png originals (361 MB, provenance only, not bundled), fetched by scripts/fetch-film-sources.sh and listed in FilmSources.sha256; scripts/pack-films.sh rebuilds Films/Packed
Config/                  Base.xcconfig: team and bundle id prefix defaults; an untracked Local.xcconfig (see Local.xcconfig.example) overrides them
iOSApp/                  iPhone and iPad app (SwiftUI, shares MiraCore and MiraUI)
Fixtures/                sample.jpg (CC0), SOURCE.md, raw/ (iPhone XS DNG committed; Sony ARW and iPhone 12 Pro DNG listed for download)
scripts/                 run.sh, install.sh, release.sh, contact-sheet.sh, fetch-film-sources.sh, pack-films.sh
Design/                  THEME.md (Field Frames theme), FILM-SCIENCE.md (pipeline, parameters, reciprocity, packed payload, adding a film)
docs/                    ROADMAP.md
project.yml              XcodeGen spec (the .xcodeproj is generated and git-ignored)
```

## Architecture

**MiraCore** is UI-free and builds the look as a pure Core Image filter graph. `Renderer.apply(_:to:)` runs these stages in order, skipping any that are at their neutral value:

Pipeline 2 (every recipe that has chosen a film; see `Renderer.swift` and `FilmCharacter.swift`):

1. Crop
2. Exposure with film latitude, push/pull gain and, for RAW/HDR sources, the scene-referred headroom shoulder (linear light)
3. White balance (linear light)
4. Reciprocity: gain, cast and contrast for the exposure time (linear light)
5. Dodge & burn, colour mixer, curves
6. Halation (linear light, two-radius glow, partial compensation; rem-jet for motion-picture stocks)
7. Film LUT (float tetrahedral kernel), blended with the pre-LUT image by Strength
8. Paper (a print look; not for monochrome films) or the scan profile (`ScanParameters`: Neutral, Frontier-like, Noritsu-like), with push contrast and black lift
9. B&W toning (monochrome films)
10. Contrast, Highlights / Shadows / Whites / Blacks, Texture, Clarity, Saturation, Vibrance
11. Bloom
12. Grain (per film, density dependent, chroma for colour films, frame-diagonal-relative and band-limited, extra shadow grain from reciprocity)
13. Vignette, then border

Pipeline 1 (recipes without a `pipeline` key, saved before film science) runs the old order unchanged: exposure, film LUT, contrast and tone (a Metal kernel for Highlights, Shadows, Whites and Blacks with masks following a blurred luminance, whites and blacks as monotonic end-point curves, luminance changed by scaling RGB so hue holds; Texture and Clarity as local contrast with radii that scale with the image), saturation and vibrance, warmth and tint, halation, bloom, grain, vignette, border.

**Colour management.** The shared `CIContext` works in extended linear sRGB with half-float intermediates (Metal-backed when available). The film LUTs are authored on sRGB-encoded values, so each cube is applied in encoded sRGB and converted back. Pipeline 2 does this in a float tetrahedral kernel (`miraLUT3D`; Core Image's colour cube quantizes its output to about 8 bits); pipeline 1 keeps `CIColorCubeWithColorSpace` with its colour space set to sRGB. Contrast, saturation and grain are wrapped in explicit linear-to-sRGB and sRGB-to-linear tone curves so they behave perceptually. Export renders in Display P3 when the source is wide-gamut and sRGB otherwise; TIFF is 16-bit, JPEG and HEIC are 8-bit.

**LUTs.** `FilmLibrary` reads `films.json` and loads each film's packed `.mlut` cube (48³, 56³ or 64³ chosen per film, LZMA, about 9 to 65 ms to decode; `.png` Hald and `.cube` files also load) lazily, caching the result in memory in an LRU of 64 cubes. Cubes larger than 64 are trilinearly resampled to 64³ (`.cube` parsing is also implemented). Cubes loaded from PNG or `.cube` files are also written to a disk cache in `Library/Caches/<bundle id>/LUTs` (16-bit, keyed on file size, modification time and format version), so a large PNG is decoded once per install. Loading all 260 looks cold takes about 0.3 to 0.5 s with parallel loading (4 to 8 workers), against about 2 s before; warm it takes about 19 ms. The app prewarms the stock cards (not variants) at launch and builds thumbnails in parallel. `mira-sheet --time-luts --films Films` prints these timings. Packed films never use the disk cache.

**Source loading and adjustments.** `ImageSource` loads photos upright and decodes camera RAW with `CIRAWFilter` (default decode), applying Photos' `fullSizeImageOrientation` when it is given; RAW exports in Display P3. `MiraAdjustment` is the single place that encodes and decodes a `Recipe` as Photos adjustment data, shared by the app and the extension. `SidecarStore` reads and writes the sidecar for files opened from disk; the JSON holds `formatIdentifier`, `formatVersion`, `recipe`, and `sourcePath`, `bookmark` and `modified` for reference.

**Preview pipeline.** `PreviewEngine` (MiraCore) renders interactive previews at the size of the canvas. The slider-independent part, crop, rotation, straighten and the downscale to canvas size, is done once per (source, crop, size) and kept as a half-float bitmap; a slider change only runs the grading graph on that bitmap (`Renderer.grade`). The crop is cut from the best level of a power-of-two pyramid of the full-size source, so a tight crop stays sharp and a whole-picture preview reads a small level. Frames render into IOSurface-backed pixel buffers tagged sRGB. `PreviewSizing` decides the render size (canvas pixels, never upscaled, capped at 3072 px, 1600 px until the view reports its size) and `RenderGate` coalesces requests: one render in flight, the latest request waits and replaces older ones. Halation blurs of 8 px or more run on a 1/4 (or 1/2) size copy. Zoomed views (`ZoomGeometry` in MiraCore holds the click, step and pan rules) render only the visible region of the full-resolution crop at the zoom scale through `PreviewEngine.renderZoomed`: the grade runs on a lazy scaled copy of the crop and Core Image renders just the region of interest (about 8 ms at 100%, 1500x1000, 24 MP). One shared `CIContext` (`Renderer.sharedContext`) serves previews, thumbnails, hover renders and export.

**Contact sheets.** `mira-sheet --contact-sheet --films Films --input <image or RAW> --out <dir> [--films-list id,id,...] [--states a,b,...] [--width 900] [--crop-only] [--exposure-time <seconds>] [--reciprocity off|compensated|uncompensated]` renders a headless films x states grid for judging and tuning the looks. Defaults: `kodak-portra-400, kodak-ektar-100, fuji-velvia-50, kodak-kodachrome-64, kodak-tri-x-400, polaroid-px-680` (unknown ids are skipped with a warning) and the states `film` (pipeline 2, all else neutral), `grain` (grainAmount 0.5), `halation` (halationAmount 0.5), `push-frontier` (push +1, Frontier-like scan); also available: `original`, `halation-max`, `paper-cinema`, `paper-color`, `toning-selenium`. Each render is at full source resolution; tiles are Lanczos-downscaled to `--width`. Output: one `<film-id>.png` row per film, `contact-sheet.png` (the whole grid), and `crops.png`, 300 x 300 1:1 crops (the brightest compact highlight in the central 60% of the frame, and a midtone region, picked from the source so every film shows the same pixels) of each film in the `grain`, `halation` and `halation-max` (halationAmount 1.0) states; judge grain and halation there, not on the downscaled tiles. `--crop-only` writes only `crops.png`. Output is deterministic (same bytes on repeated runs once the LUT disk cache is warm) and per-film timings are printed. The logic lives in `MiraCore/ContactSheet.swift`.

**Performance harness.** `mira-sheet --bench --films Films` times preview frames at canvas resolution, opening a 24 MP JPEG, the 32-thumbnail film strip (cold, warm and hot LUT cache) and a full-resolution export, for the old pipeline and the current one, plus film switching, histogram and launch timings. `Packages/MiraUI` has an opt-in UI timing test (`MIRA_PERF=1`); numbers and method are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md). It writes a synthetic 6000 x 4000 JPEG to `build/bench/` (never committed). Preview render, thumbnail batch, source load, export, asset open and grid thumbnail requests are `os_signpost` intervals (subsystem `com.fieldframes.mira`, category `perf`) for Instruments.

**MiraUI** holds `EditorModel` (source, recipe, tab, zoom, rendering) and `EditorView` (sub-toolbar with the CROP / FILMS / DEVELOP / DODGE & BURN steps, preview, and the film strip and right panel each tab brings; `EditorKeyMap` is the table of single-key shortcuts). `EditorView` reports the canvas size in pixels to the model; `FrameCanvas` hands each frame's IOSurface to a layer. Large files open from a quick ImageIO reduced decode and are decoded in full in the background (`isSourceFull`, `fullSource()`); orientation is applied once, when the file is loaded. Film-strip thumbnails (256 px) come from one small base made from the full-size source with the current crop applied, are rendered a few at a time, and are cached per crop. Hovering a film card renders it over the preview after a short debounce (60 ms) without touching the recipe.

**App** has two modes. The library mode (`LibraryStore`, `LibraryView`) shows the Photos library through a `PHCachingImageManager` grid whose thumbnail size follows the cell size times the backing scale. Opening a Photos picture shows the cached grid thumbnail at once, then a larger one, then the full-size photo once the editing input has loaded. The editor mode wraps `EditorView` with `← LIBRARY`, the status and SAVE in the editor strip (the rest is in the File and Edit menus), plus a footer under the canvas showing the sidecar or Photos status, notes and progress. `AssetEditSession` loads an asset's editing input and saves or reverts through PhotoKit. Files from disk open through the Open panel, drag and drop, or the launch arguments, and a films browser carries the licence credit. In-app switching away from a Photos edit with unsaved changes asks whether to save or discard.

**PhotosExtension** hosts the same `EditorView`. On start it decodes any existing adjustment data into the recipe and loads `fullSizeImageURL`; on Save it encodes the recipe as adjustment data and renders the full-size image to the type Photos prefers (JPEG, HEIC or TIFF), falling back to JPEG. Cancel asks for confirmation only if the recipe has changed.

The Films folder is bundled in both the app and the extension, since the extension is sandboxed and cannot read the host's bundle.

## Updates

Mira checks for a newer release in the background and can install it itself.

- **Check.** At launch, off the main thread and without delaying it, Mira asks `https://api.github.com/repos/dwjames88/mira/releases/latest` (public repo, no token) for the latest release and compares its tag (`v0.2.1`) with the app's `CFBundleShortVersionString` using semantic versioning. Automatic checks run at most once every 24 hours, can be switched off in Settings ("Check for updates automatically", on by default), and say nothing unless there is something newer: offline, 404, 401/403 (rate limit) and malformed answers are only logged (`os.Logger`, subsystem `com.fieldframes.mira`, category `updates`). **Mira > Check for Updates...** ignores the throttle and the switch and always answers, including "Mira 0.2.0 is the latest version" and errors.
- **The notice.** A small non-modal Field Frames window shows the version and the release notes (the release body, without the first-install boilerplate), with **Download & Install**, **Later** and **Skip This Version**. A skipped version is not offered again by automatic checks (a newer one is); a manual check still shows it.
- **Install.** Mira downloads `Mira-<version>.zip` (the `.dmg` only if there is no zip, and then only as a manual hand-off) with progress, checks its size and the SHA-256 GitHub publishes for the asset, unpacks it with `ditto`, and then verifies with the Security framework that the app is `com.fieldframes.mira`, is the release's version and is validly signed (strict, nested code included) by team `VF945J28YU` (`anchor apple generic and identifier "com.fieldframes.mira" and certificate leaf[subject.OU] = "VF945J28YU"`). Anything that fails is deleted. The verified app is copied next to the running one, verified again, and swapped in atomically (`replaceItemAt`); the old copy goes to the Trash. Then Mira relaunches the new one.
- **Release contract** (`scripts/release.sh` enforces it): tag `v<version>`, assets `Mira-<version>.zip` (one top-level `Mira.app`) and `Mira-<version>.dmg`, release body = the `## [<version>]` section of `CHANGELOG.md`. The script prints the `gh release create` command; it does not publish.

### Under the App Sandbox

Mira stays sandboxed. The updater adds `com.apple.security.network.client` (to the app only, not the Photos extension), `com.apple.security.files.bookmarks.app-scope` and `com.apple.security.files.downloads.read-write`. What was tested, in a sandboxed, development-signed helper (temp directories only):

| Step | Sandboxed result |
|---|---|
| GitHub API, 86 MB download | works with `network.client` |
| `/usr/bin/ditto -x -k` unpack | works |
| Security-framework signature verification | works |
| Write outside the container | denied, as expected |
| Swap inside a folder the app may write | works (`replaceItemAt`, old copy trashed) |
| Remove `com.apple.quarantine` (`removexattr`, `xattr -d`, `ditto --noqtn`) | **not permitted**: every file a sandboxed app writes is quarantined and cannot be cleaned |

So the first install asks once, with an open panel preset to the folder holding Mira (normally `/Applications`): "Allow Mira to update itself in this folder". The choice is kept as a security-scoped bookmark. If you decline, or the folder is not writable for your account, Mira does not guess: it saves the verified zip to `~/Downloads`, reveals it in Finder and tells you to drag Mira to Applications.

Because the swapped-in app is quarantined and this build is development-signed (not notarized), macOS asks you to approve the new version the first time it opens, exactly as for a manual download: right-click Mira in Applications, choose Open, then Open (or System Settings > Privacy & Security > Open Anyway). Mira therefore installs, then offers **Relaunch Now** with that note instead of quitting on its own. A build that is notarized would not need the approval. An unsandboxed debug build clears the quarantine itself and relaunches directly.

The logic lives in `Packages/MiraCore/Sources/MiraUpdates` (versions, release JSON, throttle and skip, download, verifier, swap; linked by the app only), the window in `Packages/MiraUI/Sources/MiraUI/UpdateNoticeView.swift`, and the controller in `App/Sources/Updates/`. `MIRA_LIVE_UPDATE=1 swift test --package-path Packages/MiraCore --filter LiveUpdateTests` runs the whole check, download, verify and swap against the real release in temp directories.

## Camera (iOS)

The iOS app has a camera. It shows a live finder with your chosen film applied through MiraCore, so what you see is the look you get. Hold the finder to see the bare scene. It has an EV dial, tap focus and meter, AE/AF lock, white balance presets and a film-aware meter. It saves ProRAW plus HEIC where the phone has ProRAW, and HEIC elsewhere, at 12 MP. The saved photo carries the film recipe, so it opens in the editor with the same look.

Where the code lives:

- `Packages/MiraCamera/Sources/MiraCameraKit`: the pure layer (state, exposure, lenses, white balance, save and retry, finder quality, pending prints). It is tested with `swift test --package-path Packages/MiraCamera`.
- `Packages/MiraCamera/Sources/MiraCamera`: the platform layer (AVFoundation capture, the Metal finder, PhotoKit).
- `iOSApp/Sources/Camera`: the app pieces (the screen and the film and WB doors). The film door reuses `FilmsPanel` from the editor.

**Simulator.** The simulator has no camera. Set `MIRA_CAMERA_FAKE=1` for a fake frame source. `MIRA_SNAPSHOT=1 MIRA_SNAPSHOT_TAB=camera` renders the camera screen for a snapshot.

**Privacy.** The camera asks for camera permission only. Location is opt-in and off by default. There is no microphone use and no network.

**Finder quality.** If the phone runs hot or the finder falls behind, AUTO steps down a ladder: half-resolution texture, then grain off, then 0.75x, then 24 fps. You can pin a level in camera settings. See [docs/PERFORMANCE.md](docs/PERFORMANCE.md) for the Mac proxy numbers.

## Build and run the Mac app

Prerequisites: macOS 26 or later, Xcode 27 (built with Xcode 27.0, build 27A5209h; Swift 6, strict concurrency) and [XcodeGen](https://github.com/yonaskolb/XcodeGen), which generates `Mira.xcodeproj` from `project.yml` (the project file is git-ignored).

```sh
brew install xcodegen
git clone https://github.com/dwjames88/mira.git && cd mira
cp Local.xcconfig.example Local.xcconfig     # then put your own team ID in it (see Signing below)
xcodegen generate
open Mira.xcodeproj                          # scheme "Mira": builds the app and the Photos extension
```

Press Run in Xcode, or from the command line `scripts/run.sh` (Debug build into `build/DerivedData`, opens the app) and `scripts/install.sh` (Release build, installs to `/Applications`, registers the Photos extension). `scripts/contact-sheet.sh [image]` renders `build/contact-sheet.png`. To enable the Photos extension (System Settings, Login Items & Extensions, Photos Editing, Mira) follow [TESTING.md](TESTING.md#enable-in-photos-macos-2627).

**Signing.** `Config/Base.xcconfig` (tracked) holds the publisher's defaults, `DEVELOPMENT_TEAM = VF945J28YU` and `MIRA_BUNDLE_PREFIX = com.fieldframes`, then includes an optional, untracked `Local.xcconfig` at the repository root. Copy `Local.xcconfig.example` to `Local.xcconfig` and set your own `DEVELOPMENT_TEAM` (a free Personal Team works). If your team cannot register `com.fieldframes.*`, also set `MIRA_BUNDLE_PREFIX` (for example `com.example`): the bundle ids become `<prefix>.mira`, `<prefix>.mira.photos` and `<prefix>.mira.ios`. With no `Local.xcconfig` the project builds exactly as published. Run `xcodegen generate` again after changing it, or check the result with `xcodebuild -project Mira.xcodeproj -target Mira -configuration Release -showBuildSettings | grep -E 'PRODUCT_BUNDLE_IDENTIFIER|DEVELOPMENT_TEAM'`.

**App Group.** The app and the Photos extension share presets through the App Group `<team>.<prefix>.mira` (`VF945J28YU.com.fieldframes.mira` for the publisher). It is built from the same two settings, written to the entitlements, and read at run time from the `MiraAppGroup` Info.plist key, so nothing else needs editing. With a free Personal Team Xcode registers the group for you on the first build.

**Updater.** The in-app updater only installs releases whose app is `com.fieldframes.mira` signed by team `VF945J28YU`; that is the publisher's identity and is deliberately not configurable. A copy you build with another prefix or team does not self-update, which is correct: update it by pulling and rebuilding.

## Build and run the iOS app

Prerequisites: the same Xcode 27 and XcodeGen, and the iOS 18 or later SDK (the app targets iOS 18.0; the simulator runtimes used here are 26.x). Set up `Local.xcconfig` as above, then:

```sh
xcodegen generate
open Mira.xcodeproj                          # scheme "MiraiOS"
```

Choose an iPhone or iPad simulator and Run, or a connected device (needs your team in `Local.xcconfig`, a trusted developer profile on the device, and Developer Mode on). From the command line:

```sh
xcodebuild -project Mira.xcodeproj -scheme MiraiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project Mira.xcodeproj -scheme MiraiOS -destination 'generic/platform=iOS' -configuration Release build   # signed for devices
```

The iOS app has no Photos extension and no self-updater. It uses the same packed films and the same MiraCore and MiraUI packages as the Mac app. The editor has the same four steps in the same order (CROP, FILMS, DEVELOP, DODGE & BURN); painting is Mac-only for now, so the iOS DODGE & BURN step lists the photo's existing strokes read-only. Free-team installs expire after 7 days.

## Rebuilding the film LUTs

The apps bundle the packed cubes in `Films/Packed`, so you never need the original PNGs to build or run. `FilmSources/` (360 MB of Hald PNGs) is not in git. To regenerate the cubes, or to run the tests that compare them with their PNGs:

```sh
scripts/fetch-film-sources.sh   # downloads HaldCLUT.zip (about 420 MB), checks its SHA-256, copies each film's PNG to FilmSources/HaldCLUT/<id>.png and checks every file against FilmSources.sha256
scripts/pack-films.sh           # swift run mira-sheet --pack-films FilmSources Films: rewrites Films/Packed (deterministic)
```

`MIRA_FILM_SOURCES_DIR` changes where the PNGs go and `MIRA_HALDCLUT_ZIP` points at a local copy of the archive (still checked). The source, licence and the file behind every look are in [Films/ATTRIBUTION.md](Films/ATTRIBUTION.md).

## Tests

```sh
swift test --package-path Packages/MiraCore   # 398 tests (MiraCore 358 + MiraUpdates 40); 3 skip without FilmSources/ (see below)
swift test --package-path Packages/MiraUI     # 153 tests (opt-in perf tests skip without MIRA_PERF=1)
swift test --package-path Packages/MiraCamera # 75 tests (camera pure layer, simulator-free)
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
- **Film LUTs:** the PNG files fetched into `FilmSources/HaldCLUT/` (not in git; see Rebuilding the film LUTs) are from the RawTherapee Film Simulation Collection (2015-09-20) by Pat David, with Pavlov Dmitry and Michael Ezra credited in the archive, and are licensed under [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/). Full attribution, the source URL and the mapping from each file to its original name are in [Films/ATTRIBUTION.md](Films/ATTRIBUTION.md). The PNG files in `FilmSources/` are unmodified, byte for byte, only renamed; the app bundles each look as a packed cube, resampled to 48³ or 56³ where the error stays small (an adaptation under the same licence). Derivative works of the LUTs must be shared under the same licence.
- **Trademarks:** film stock names are used for information only. Mira is not affiliated with, or endorsed by, any film maker or the trademark owners.
- **Fonts:** Cormorant Garamond and IBM Plex Mono are bundled in `Packages/MiraUI/Sources/MiraUI/Resources/Fonts/` under the SIL Open Font License 1.1. The licence texts are alongside (`OFL-CormorantGaramond.txt`, `OFL-IBMPlexMono.txt`).
- **Sample photo:** `Fixtures/sample.jpg` is "Outdoor portrait" by Anthony Ginsbrook (Unsplash), CC0 1.0, downscaled to 2400x1600. See [Fixtures/SOURCE.md](Fixtures/SOURCE.md).

## Renamed from Emulsion

Mira was called Emulsion until v0.2. The bundle ids changed (`com.fieldframes.mira`, `com.fieldframes.mira.photos`), so macOS asks for Photos access again and the extension must be re-enabled in System Settings. Existing edits and sidecars keep working: see Re-editable edits and Files from disk above. The self-test album keeps its old name, "Emulsion Test".
