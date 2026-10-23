# Changelog

All notable changes to Mira. Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.4.0] - 2026-10-23

### Added
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
