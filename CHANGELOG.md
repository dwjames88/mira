# Changelog

All notable changes to Mira. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased 1.1.0]

Roll 1: a camera for iPhone. Not yet verified on an iPhone (see Notes).

### Added
- **Camera (iOS).** A live finder rendered through MiraCore with the film you chose. Hold the finder to see the bare scene.
- **Film door.** Mirrors the editor's card flow (cards, then options) and adds GRAIN rows (finder off or live, amount, size).
- **Exposure and focus.** An EV dial in thirds, tap to focus and meter, AE/AF lock, white balance presets and a WB lock.
- **Film-aware meter.** A needle plus UNDER and OVER counts, measured against the stock's latitude, so slide and negative film read differently.
- **Capture.** ProRAW plus HEIC on phones that have ProRAW, HEIC elsewhere, at 12 MP.
- **Two-step save.** The original is saved first and the recipe attached after, with a retry queue. When Photos access is limited, you get the original plus a baked copy and a notice. If the app quits between capture and developed, the next launch attaches the recipe.
- **Native grain, halation and bloom** in the finder, with an AUTO quality ladder (full, grain off, 0.75x, 24 fps). Half-resolution texture is a manual override only.
- **Lenses** shown in 35 mm equivalents, with chips and pinch to zoom.
- **Hardware shutter.** Volume buttons, the Action button and Camera Control fire on release.
- **Feedback.** Haptics and the system shutter sound. A silent option exists only where the region allows it, and is off by default.
- **Rotation.** Readouts rotate; the chrome stays.
- **Privacy.** Camera permission only. Location is off by default and there is no microphone use.
- **Entry points.** A CAMERA button in the gallery and a "Load film" Home Screen quick action.

### Changed
- `FilmsPanel` is now shared between the editor and the camera.
- The latitude meter computes its percentiles with a selection instead of a full sort (same values, about 5x faster); the camera reads it from a 256 px frame at 4 Hz.
- MiraCore `Renderer` gains `withGrainSeed` and `withTextureScale` for the finder. Capture and export use the defaults and render as before.

### Tests
- New `MiraCamera` package: `swift test --package-path Packages/MiraCamera` runs 76 tests (camera state, exposure and readouts, lenses, capture format, white balance, finder quality ladder, finder touch, pending prints, two-step save with fakes). MiraCore adds finder tests (seed override, texture scale parity, finder vs capture parity) and an opt-in finder budget benchmark. iOS: camera layout snapshots (16 Pro, SE, landscape), camera door snapshots, camera model tests with the fake backend, a RAW+HEIC save round trip against the simulator's Photos library, and an opt-in simulator finder benchmark (MiraiOSTests 37).

### Notes
- Not yet verified on an iPhone. The first device check is the 30 fps finder gate on an iPhone 16 Pro; see [TESTING.md](TESTING.md).

## [Unreleased 1.0.2]

### Fixed
- **Opening a photo can no longer hang on "OPENING" (Mac and iPhone).** If Photos does not hand over the editable original within 8 s (or within 30 s of its last iCloud download progress, shown as "DOWNLOADING FROM ICLOUD · NN%"), the request is cancelled and retried once; if that also fails a card says "Photos didn't hand over this photo." with RETRY and BACK, and other photos open normally. A late or repeated answer from Photos is ignored and never replaces a newer open.

## [1.0.1] - 2026-11-05

A fix release after a run-through of the whole app on the Mac and on iPhone.

### Fixed
- **Shadow speckles.** Lifting shadows, blacks, whites, texture, clarity or a luminance curve could turn near-black pixels into saturated orange, red or green specks (seen in dark rock with a film and grain). The luminance change scaled the whole colour by new/old luminance, which explodes where the luminance is tiny. The chroma gain of a lift is now bounded where the luminance is tiny or a channel is negative; ordinary dark colours keep the same lift as before.
- **Black squares on RAW (iPhone).** A single non-finite pixel could spread through the tone stage's blur into a black block (Highlights 0.46 on a ProRAW). Sources and blur inputs are now sanitised (NaN to 0, infinity to the source headroom), and the tone and detail stages fall back to the pixel itself if their blurred base is not finite and keep their output inside half-float range. Not reproduced off the device; fixed by construction.
- **iPhone preview vs export on RAW with a film.** The iPhone preview proxy was 8-bit and clipped everything above white while still claiming the RAW's headroom, so whites came out dim and hazy, unlike the export. The proxy is now half-float extended linear and keeps the scene range; the preview context uses the same working space and format as the Mac.
- **Look changed between FILMS and DEVELOP (iPhone).** The preview proxy was sized to the photo on screen and only ever grew, and the grade was rendered into each drawable size, so the same recipe looked different per step and depended on the order of steps. The proxy now has a fixed size from the screen and zoom level, and the grade renders once per change. Applying a film redevelops a RAW at once (no wait), and the film strip refreshes when the develop changes, so cards and photo agree. iPhone film cards now show the film's native grain, halation and bloom, as on the Mac.
- **Presets on iPhone** no longer reset the photo's own RAW settings (white balance, noise reduction) when applied; applying one preset after another replaces every preset field.
- **iPhone library:** RAW badge on every RAW type (ARW, CR3, NEF…, not only DNG); album covers refresh when an album's pictures or key photo change; the RAW filter in Hidden and Recently Deleted; a slower earlier open can no longer replace a newer one; edits made while a save runs keep the photo marked unsaved; "1 PHOTO" singular; a failed full RAW develop says so.
- **Updater (Mac):** cancelling an install and starting another no longer lets the cancelled one reset the new one or delete its download.
- Mac build warnings (4 to 0); `mira-sheet` no longer flags monochrome instant stocks as colour films without chroma.

### Changed (iPhone editor)
- The step bar (Crop, Films, Develop, Dodge & Burn) is four icons above the photo.
- Tapping a film card opens its full options panel (ISO, Variations, push, scan or paper, toning, exposure time and reciprocity, Import, Save Preset, Strength) in place of the strip; FILMS at the top returns to the strip with the film still applied. Chip rows scroll to the selection and labels stay on one line.
- Curves, Color Mix and the other panels sit under the photo instead of covering it; the photo shrinks to fit. A chevron hides the panel to see the whole photo, per step.

### Tests
- RAW Develop slider sweep (every slider, with and without a film, three RAW files) for NaN, infinity and black tiles; injected NaN/infinity; shadow speckle across every film family; preview proxy vs export; iOS step consistency (FILMS vs DEVELOP, preset A then B, RAW draft vs full) and layout snapshots at iPhone 16 Pro and iPhone SE sizes; iOS UI tests (`scripts/ios-uitests.sh`); live v1.0.0 release fixture for the updater.

### Notes
- The Mac build is signed with an Apple Development certificate and is not notarized. On first launch macOS may refuse to open it: right-click Mira and choose Open.
- The in-app updater (0.3.0 and later) installs 1.0.1. The sandboxed updater cannot clear the quarantine flag on the downloaded app, so macOS may ask once more on the first launch after the update; right-click Mira and choose Open. 0.2.0 has no updater; install 1.0.1 by hand.
- iOS has no self-updater. Build it from source (supported; see the README), or use the attached development-signed ipa, which installs only on devices registered to the publisher's team.

## [1.0.0] - 2026-11-05

The first release with the film-science pipeline, on the Mac, in the Photos extension and on iPhone and iPad. It rolls up everything from the unreleased 0.5.0 below.

### Highlights
- Editor steps reordered: Crop, Films, Develop, Dodge & Burn (keys 1–4).
- **Silver grain.** Grain is now modelled as film grain, not noise: a density-domain field defined in micrometres on the 36 x 24 mm frame, sized and scaled from each stock's published RMS granularity (Tri-X and HP5 gritty, Portra and Ektar fine, Velvia nearly invisible, instant soft), mostly luminance, clean in the blacks, with the same structure in the preview, at 100 % and in any export size. See Design/GRAIN.md.
- **Native texture on film choice.** Choosing a film sets Grain, Halation and Bloom to that film's own level (50 %); bloom is now per film too. Presets keep their stored values.
- **Exposure time that you can see.** Reciprocity strength (0–200 %) and a numeric readout (loss in stops, cast, contrast, shadow grain); editing any film setting moves an older edit onto the current film model.
- **Opens the RAW.** For Photos assets with a RAW original the editor develops the RAW: the embedded preview appears at once, an editable draft follows, full quality replaces it in the background, and reopening is instant.
- **Faster library.** Leaving the editor no longer rebuilds the grid or re-requests thumbnails (0 requests for unchanged photos); only an edited photo's thumbnail refreshes; scroll position is kept. On iOS too.
- **Film science.** A pipeline built in the order of the light: exposure with film latitude, white balance, halation, per-film grain, the film's colour, then the print.
- **264 looks.** The 260 films of the RawTherapee Film Simulation Collection (Pat David et al., CC BY-SA 4.0) plus 4 Mira originals (500T Tungsten, 250D Daylight, Cinema Print, Color Paper), grouped into 7 families (Color Negative, Slide, Kodachrome, Black and White, Motion Picture, Instant, Print) as one card per stock, with ISO and Variations chips in the FILMS panel (51 stocks).
- **RAW development and headroom.** A RAW group in DEVELOP (white balance, boost, highlight recovery, local tone map, noise reduction, sharpness, lens correction), and scene-referred headroom so RAW and HDR highlights roll off through the film's shoulder instead of clipping.
- **Reciprocity and exposure time.** An exposure time slider (EXIF time by default) and a Reciprocity mode (Off, Compensated, Uncompensated).
- **Push and pull** from -2 to +2 stops in thirds, with a **Latitude** readout under the histogram.
- **Scan and paper.** Neutral, Frontier-like and Noritsu-like scans, plus Cinema Print and Color Paper print stocks after the film.
- **Toning** for black-and-white films.
- **Library filter.** An ALL/RAW filter with a count, on the Mac and on iOS.
- **iOS** gets the film categories and the film options (push/pull, scan, toning, paper, exposure time, reciprocity).
- **Smaller and faster.** The film cubes are packed (LZMA, 48/56/64 cubes chosen per film by measured error): the app is about 284 MB instead of about 720 MB. Thumbnails are lazy and cached on disk.
- **Contact-sheet tool.** `mira-sheet --contact-sheet` renders a films x states grid for judging looks.

### Notes
- The Mac build is signed with an Apple Development certificate and is not notarized. On first launch macOS may refuse to open it: right-click Mira and choose Open.
- The in-app updater (0.3.0 and later) installs 1.0.0. 0.2.0 has no updater; install 1.0.0 by hand.
- iOS has no self-updater. Build it from source (supported; see the README), or use the attached development-signed ipa, which installs only on devices registered to the publisher's team.
- Building from source no longer needs the film PNGs: `scripts/fetch-film-sources.sh` downloads them, and only to rebuild the packed cubes. Your own team and bundle id prefix go in `Local.xcconfig`. A build with another prefix does not self-update, by design.

## [0.5.0] - 2026-11-05 (internal, not released)

Film science: a pipeline built in the order of the light, a smaller film payload, scene-referred RAW, Mira original looks, exposure time and reciprocity. Design notes and the numbers behind them are in [Design/FILM-SCIENCE.md](Design/FILM-SCIENCE.md).

### Added
- 264 film looks (from 31): the full RawTherapee Film Simulation Collection (Pat David et al., CC BY-SA 4.0), 260 looks, plus 4 Mira originals, shown as 86 stock cards (Color Negative 26, Slide 15, Kodachrome 3, Black & White 22, Instant 16, Motion Picture 2, Print 2). The 178 push/pull, tone and alternate variants are chosen with a Variant picker in the FILMS panel. All seven family tabs are populated.
- Mira original looks, generated in code (`ProceduralLooks`, no LUT file, no affiliation with Kodak or Fujifilm): 500T Tungsten and 250D Daylight (Motion Picture) and Cinema Print and Color Paper (Print).
- Paper: a print stock after the film. Cinema Print and Color Paper chips in the FILMS panel replace the Scan profile (choosing one sets Scan to Neutral); push contrast and black lift still apply. Hidden on the Print cards themselves and on monochrome films (a black-and-white negative is printed on black-and-white paper; Toning covers that), where the renderer also ignores a paper carried by a preset.
- Exposure time and reciprocity failure: an EXPOSURE TIME slider (log scale, EXIF time by default, double-click the label to return to it) and a Reciprocity mode (Off, Compensated, Uncompensated) in the FILMS panel. Datasheet data for 41 stocks from Ilford, Kodak, Fuji, Agfa and Polaroid (with source URLs in `films.json`) and family defaults for the rest: loss of speed, colour cast from the inverse of the recommended filter, contrast, and shadow grain. A readout says what the time does to the film and when it is beyond the datasheet. Exposure time is read from EXIF for files and RAW and is part of the recipe (`Recipe.exposureTime`, `Recipe.reciprocity`).
- Film science (pipeline 2): exposure with film latitude, white balance before the film, halation in the exposure (rem-jet for motion-picture stocks), per-film grain (density dependent, chroma for colour films, frame-relative and band-limited so previews match exports), per-film character from family and ISO. Grain and Halation sliders read 50% as the film's own amount.
- FILMS panel: Push/Pull (±2 stops in thirds), Scan (Neutral, Frontier-like, Noritsu-like), Toning for monochrome films, a rem-jet toggle for motion-picture stocks, and a Latitude readout under the histogram and in FILMS.
- RAW development: a RAW group in DEVELOP (white balance as shot or kelvin/tint, boost, highlight recovery, local tone map, noise reduction, sharpness, lens correction) through `CIRAWFilter`, with draft previews and full-quality export. An ALL / RAW toggle beside Filter in the Mac library.
- Scene-referred headroom for RAW and HDR sources: the measured peak of an extended-range decode is mapped to white through the film's shoulder (knee at 0.6) before the LUT, instead of clipping.
- Real RAW fixtures for tests (`Fixtures/raw`): an Apple iPhone XS DNG (CC0, raw.pixls.us) is committed; a Sony ILCE-7M3 ARW and an iPhone 12 Pro DNG are listed with URLs and SHA-256 for download (kept out of the repository to keep its history small). `RawIntegrationTests` skip any file that is absent.
- `mira-sheet --contact-sheet`: a headless films x states grid for judging looks (states include `halation-max`, `paper-cinema`, `paper-color`, `toning-selenium`; `--exposure-time` and `--reciprocity`), with 1:1 highlight and midtone crops for grain and halation.

### Changed
- Film payload: the Hald PNGs moved to `FilmSources/HaldCLUT/` (361 MB, kept for provenance, not bundled); the app and the Photos extension now bundle `Films/Packed/<id>.mlut`, LZMA-compressed 16-bit cubes whose dimension is chosen per film by measured error on real image colours (pixels of the sample JPEG and the iPhone DNG fixture plus a neutral ramp and an HSV sweep): 48³ or 56³ when within 4/255 (max) and 1.5/255 (99.9th percentile) of the 64³ original, else the exact 64³ (124, 45 and 91 films). Films is 126 MB per copy (125.6 MB of cubes) instead of 361 MB, and the app is 284 MB instead of about 720 MB. `mira-sheet --pack-films FilmSources Films` regenerates them and prints a summary. Packed films skip the LUT disk cache.
- The LUT stage of pipeline 2 uses a float tetrahedral Core Image kernel (`miraLUT3D`) instead of `CIColorCube`, which quantized an identity cube to about 257 levels; it now gives at least 3,000 levels on a 4,000-step ramp, within 1/255 of the old result on real colours, about 30% more time on that stage. Pipeline 1 is unchanged.
- Halation retuned: clipped point lights no longer get a grey hole (only 20% of the scattered light is taken out of the source, as on film where the core sits on the shoulder), threshold `smoothstep(0.7, 1.0)`, radius 0.006 of the diagonal plus a tighter component so the fringe hugs the light.
- Film strip thumbnails are lazy and cached on disk: only the cards on screen and six on each side are rendered, and tiles are kept as JPEGs in a 200 MB least-recently-used cache. Measured with 82 stocks and Original (release, medians of 3, on a heavily loaded machine): the first 8 thumbnails take 177 ms before, 138 ms on a cold cache and 73 ms on a warm one; the initial window of 15 tiles 154 ms cold (the old code rendered every card, 1789 ms); the whole strip 166 ms warm with no renders. See [docs/PERFORMANCE.md](docs/PERFORMANCE.md).
- Choosing a film opts a recipe into pipeline 2 and saves Photos adjustment data as format version 4, which older builds refuse; versions 1 to 3 still read. Legacy recipes (no `pipeline` key) render exactly as before.
- Presets keep only boost, tone map and highlight recovery from the RAW settings, not white balance or per-camera values.
- Kodak Elite Color 200 and 400 are classed as color negative, not slide; Kodachrome stocks have their own family.
- The in-memory LUT cache is an LRU of 64 cubes; the launch prewarm loads stock cards only.

## [0.4.0] - 2026-10-23

### Added
- Share: a share button in the editor strip (left of SAVE) and File ▸ Share… (⌥⌘S) open the system share sheet (AirDrop, Messages, Mail, Photos, Notes) with the current look rendered at full size as "<name> - Mira.jpg" (or HEIC/TIFF, following the last File ▸ Export format and quality). The render goes through the same code as Export, off the main thread, with a spinner on the button and a "Preparing to share" overlay when it takes longer than about 300 ms. Temporary files are removed on the next share and at launch. App only; the Photos extension has no Share.
- File ▸ Export now remembers its last format and quality.
- Dodge & Burn. A DODGE & BURN group in the DEVELOP tab with a PAINT switch that opens a brush tool on the canvas. Paint light on (dodge), take it off (burn) or erase earlier strokes, with Size, Feather, Flow and Strength sliders, a tone Range (shadows, midtones, highlights), Protect Tones (dodge never clips highlights, burn never crushes to black) and an optional Luminosity Range (low, high, softness) that limits a stroke to a band of tones. The brush ring shows the brush on screen with the feather as an inner ring; tablet pressure is used when the pen reports it. Each stroke is one edit and is listed with its mode, an eye (hide), its strength and a delete button; selecting a row edits that stroke's settings; CLEAR ALL removes them all. MASK OVERLAY (key O) washes the painted area red.
- Keys in the tool: `[` and `]` change the brush size (zoom moves to ⌘= and ⌘-), hold ⌥ at the start of a stroke to flip dodge and burn, O toggles the mask overlay, Esc leaves the tool.
- Strokes are saved with the photo: part of the recipe (`Recipe.dodgeBurn`), in sidecars and in Photos adjustment data, which is written as format version 3 only when a photo has strokes (versions 1 and 2 and older data still open). Strokes are stored relative to the uncropped source, so they stay on the picture when you change the crop, rotation or straighten.
- Presets and `.mirapreset` files do not carry strokes, and applying a preset keeps the photo's strokes. The Save Preset sheet says so.
- New benchmark rows and a UI timing test for painting; see [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## [0.3.1] - 2026-10-22

### Added
- Preset sharing: each preset is one `.mirapreset` file (JSON, "<Film> - <nickname>.mirapreset", no photo data and no crop). Right-click a preset card for Share… (the system share sheet: AirDrop, Messages, Mail) or Export… (a save panel); Preset ▸ Export All Presets… writes one file per preset into a folder.
- Preset import: Preset ▸ Import Presets… (⇧⌘I), drag `.mirapreset` files onto the FILMS strip or the window, or double-click one in Finder (Mira opens and imports, with or without a photo open). A preset with the same "<Film> - <nickname>" as a saved one asks Replace, Keep Both (adds " 2", " 3"…) or Skip, with Apply to all for several files. A notice reports the result and lists unreadable files by name. A preset for a film you do not have shows FILM MISSING.
- The `com.fieldframes.mira.preset` file type (`.mirapreset`, "Mira Preset") is declared by the app, which is its default opener.

### Changed
- Presets moved into the FILMS tab: the strip under the canvas shows a PRESETS group of your preset cards first, then the FILMS group, in one row (presets are shown whatever the family filter says; a single SAVE A PRESET slot stands in until there are any). The FILMS panel names the preset the look matches and has SAVE PRESET….
- The separate PRESETS tab and its key 4 are gone; tabs are FILMS, DEVELOP, CROP (keys 1 to 3).
- Share, Export and Import are in the app only: the Photos extension is sandboxed without file access, so it keeps the preset cards and SAVE PRESET… and shows no share or import controls.

## [0.3.0] - 2026-10-22

### Added
- Presets: save the film and all develop settings as one preset named "<film> - <nickname>" (for example "Portra 400 - Last Summer"). New PRESETS tab (key 4) with thumbnail cards, hover preview and click to apply (the photo's crop is kept), a Save Preset sheet, Rename, Duplicate and Delete, a FILM MISSING mark and notice when a preset's film is not installed, and Preset ▸ Save as Preset… (⇧⌘S).
- App Group `VF945J28YU.com.fieldframes.mira` on the app and the Photos extension: presets are one shared `Presets.json`, so a preset saved in either shows up in the other.
- Updates: Mira checks GitHub for a newer release in the background at launch (at most once a day; Settings > "Check for updates automatically"), and Mira > Check for Updates... always checks. A newer release opens a Field Frames notice with the release notes and Download & Install, Later and Skip This Version. The download is checked against GitHub's SHA-256, unpacked, and verified (bundle id, version, signature, team) before it replaces the app; a sandbox folder grant is asked for once. Adds the network client, bookmarks and Downloads entitlements to the app. `scripts/release.sh` now checks the release layout the updater expects and prints the `gh release create` command.
- Develop controls: Highlights, Shadows, Whites, Blacks, Texture, Clarity and Vibrance. The DEVELOP tab is now Light (Exposure, Contrast, Highlights, Shadows, Whites, Blacks), Presence (Texture, Clarity, Vibrance, Saturation) and Color (Temperature, Tint), followed by Effects (formerly Texture) and Frame.
- Adjustment data format version 2, written only when one of the new controls is used; version 1 and legacy Emulsion data still open.

### Performance
- Film strip no longer re-evaluates on every slider tick (SwiftUI cost per tick 4.0 to 2.3 ms) and thumbnails are published in batches (strip refill after a crop 150 to 250 ms down to about 60 ms).
- Core Image kernels are warmed in the background at launch (first preview frame 24 to 36 ms down to 12 to 15 ms) and LUTs prewarm with more workers on first launch.
- New measurements in `mira-sheet --bench` and an opt-in UI timing test; see [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

## [0.2.0] - 2026-10-21

### Added
- Photos library browser in the host app: Photos-order sidebar with collapsible sections, folders, shared albums and media types; thumbnail grid with RAW and EDITED badges; library filter backed by a background EXIF metadata index.
- Non-destructive edits through PhotoKit with in-app Revert to Original, using one shared adjustment codec (`MiraAdjustment`) in the app and the extension, so an edit made in either reopens in the other.
- RAW decoding with `CIRAWFilter`, exported in Display P3.
- Files from disk: sidecar recipes (`<filename>.mira.json`), open at launch (`open -a`, Finder Open With, drag and drop).
- Field Frames design (ink ground, Cormorant Garamond and IBM Plex Mono, square corners), appearance toggle (System / Light / Dark), About window with the film list, and Settings.
- Develop workflow: FILMS, DEVELOP and CROP tabs, commands in the menu bar, single-key shortcuts.
- Crop: non-destructive crop, 90-degree rotation, flips and straighten, with aspect presets.
- Histogram, curves editor and color mixer.
- Hover preview of a film on the canvas, in the app and the extension.
- Zoom: click for 200%, scroll to pan, pinch to zoom, `[` and `]` to step; full screen; hold-to-compare key.
- Performance harness (`mira-sheet --bench`) and `os_signpost` intervals.

### Changed
- Renamed Emulsion to Mira (new bundle ids). Photos edited with Emulsion and `.emulsion.json` sidecars are still read.
- Previews render at canvas resolution from a cached base and IOSurface frames: median preview frame 12 ms to about 5 ms (24 MP source, 1500x1000 canvas, M1 Pro).
- LUT disk cache and parallel loading: cold load of all 31 films about 2 s to about 0.56 s.
- Grid thumbnails may use the network so iCloud-only photos are not blank.
- User-facing text uses US English.

### Fixed
- PhotoKit actor-isolation crash.
- Hover preview did not redraw the canvas.
- Photos extension did not fill the Photos editing window.
- Scroll-wheel pan over the zoomed canvas.

## [0.1.0] - 2026-10-20

### Added
- First build: 31 film looks from the RawTherapee Film Simulation Collection (CC BY-SA 4.0).
- Photos editing extension and host app for files.
- Film, exposure, contrast, saturation, warmth, tint, grain, halation, bloom, vignette and border controls.
- Recipe stored as Photos adjustment data; export to JPEG, HEIC and TIFF.
