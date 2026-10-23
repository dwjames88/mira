# Testing Mira

Mira is software by FieldFrames (renamed from Emulsion). Because the bundle ids changed, macOS asks for Photos access again on first launch, and the extension must be re-enabled in System Settings (Extensions ▸ Photos Editing, or the ⓘ button in Photos ▸ Edit ▸ ⋯ ▸ Extensions) even if Emulsion's was on. Photos edited by Emulsion and sidecars named `<filename>.emulsion.json` are still read.

## Install

```sh
scripts/install.sh
```

This regenerates the project with xcodegen, builds Release into `build/DerivedData`, copies `Mira.app` to `/Applications`, verifies its signature, removes the build products' own extension registrations so only the `/Applications` copy is known, refreshes Launch Services (`lsregister -f`), registers the extension with `pluginkit -a` (retrying while registration settles), and elects it with `pluginkit -e use -i com.fieldframes.mira.photos`. It finishes by listing Photos editing extensions and fails if Mira is not among them.

## Enable in Photos (macOS 26/27)

1. Open System Settings ▸ General ▸ Login Items & Extensions.
2. Scroll to the Extensions section and choose "By Category" (or by app).
3. Under Photos Editing, click the ⓘ button and turn on Mira.

Alternative: in Photos open a photo ▸ Edit ▸ click the ⋯ (More) or Extensions button in the toolbar ▸ More… This opens the same pane.

Then:

1. Open a photo in Photos ▸ Edit ▸ ⋯ ▸ Mira.
2. Pick a film, adjust the sliders, and click Save Changes.
3. To verify re-editability, choose Edit again ▸ ⋯ ▸ Mira and confirm the film and sliders are restored.
4. Revert to Original should return the untouched photo.

Check registration from the shell:

```sh
pluginkit -m -p com.apple.photo-editing -v | grep mira
```

## Troubleshooting

- **Extension missing from Photos or the list:** re-run `scripts/install.sh`; then `pluginkit -e use -i com.fieldframes.mira.photos`; quit and reopen Photos; and, if needed, `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Mira.app`.
- **Extension fails to load or does nothing:** open Console, filter on `MiraPhotos`, and reproduce.
- **Stopped working after a few days:** the project uses Personal Team development signing. Free-team provisioning profiles last 7 days, so re-run `scripts/install.sh` to re-sign if the extension stops loading.

## Photos access

The first launch of the app asks for access to your Photos library (`NSPhotoLibraryUsageDescription`). Choose Allow Access to All Photos. To change the decision later, open System Settings ▸ Privacy & Security ▸ Photos and set Mira to Full Access, Limited Access or off. If access is denied the library shows a waiting message; files from disk still work.

## Host app

```sh
scripts/run.sh
```

Check: the app opens; Open (or drag a photo onto the window) loads it; the film strip shows thumbnails and the family picker filters them; selecting a film updates the preview; holding C or the HOLD TO COMPARE button shows the original; the Films window (Shift-Command-L) lists all 31 films and the credit; File ▸ Export… (⌘E) offers JPEG, HEIC and TIFF, and the written files open correctly with orientation and colour intact.

### Library browser

1. The sidebar lists All Photos, Favourites, your albums and the non-empty smart albums (RAW, Recently Added, Screenshots, Selfies, Portrait, Panoramas, Live Photos); counts match Photos.
2. The grid scrolls smoothly on a large library, thumbnails sharpen as cells appear, and the arrow keys move the selection.
3. RAW pictures carry a RAW badge; pictures with adjustments carry EDITED.
4. Double-click, or Return on the selection, opens the picture in the editor; ← LIBRARY in the editor strip (or File ▸ Back to Library, ⌘←) returns to the grid.
5. Changes made in Photos while the app is open (a new favourite, a new picture) appear after a moment.
6. With Limited Access, only the chosen pictures appear and the header says LIMITED ACCESS.

### Photos round trip

1. Open a picture from the library, pick a film, adjust, and choose SAVE in the editor strip (or File ▸ Save to Photos, ⌘S). The footer reports the result and the EDITED badge appears.
2. In Photos the picture shows the edit. Edit ▸ ⋯ ▸ Mira reopens it with the film and every slider restored.
3. Save a change from the extension, then open the same picture in the app: the app restores the extension's recipe. The codec is shared, so it works both ways.
4. In Photos, choose Revert to Original: the picture returns to the untouched original, and the app shows no EDITED badge.
5. In the app, open an edited picture and choose Revert: the picture reverts in Photos and the original is untouched.
6. Switching to another picture or back to the library with unsaved changes asks Save to Photos, Discard Changes or Cancel.
7. A picture edited by another app opens from its original with the note that saving replaces those edits.

### Sidecar (files from disk)

1. Open a JPEG from a folder in your home directory (Open panel). Change a slider; the footer reads SIDECAR · APP SUPPORT (folder not writable) under the sandbox, and a file named `<sha256 of path>.mira.json` appears in `~/Library/Containers/com.fieldframes.mira/Data/Library/Application Support/Mira/Sidecars/`.
2. Quit, reopen the same file: the recipe is restored. The original file's modification date is unchanged.
3. Revert deletes the sidecar; the footer returns to the "written on first edit" line.
4. Export writes a new file and leaves the original alone.
5. `--selftest-sidecar` exercises the same store (see below).

### Opening files at launch

```sh
open -a /Applications/Mira.app Fixtures/sample.jpg
```

The app opens that file in the editor. Finder ▸ Open With ▸ Mira does the same for JPEG, HEIC, PNG, TIFF and RAW files.

### Hover preview

Move the pointer over the film cards. After a short pause the canvas shows that film with the current sliders and a "PREVIEW · FILM" label; moving to another card follows; moving off returns to the applied look. Nothing changes in the recipe (the UNSAVED mark does not appear, and clicking is what applies a film). Repeat in the Photos extension.

### Presets

1. Open a photo in the app, pick a film (say Portra 400), move a few sliders, choose Preset ▸ Save as Preset… (⇧⌘S) (or FILMS tab ▸ SAVE PRESET…). The sheet shows the film as a fixed prefix; type "Last Summer": the preview reads "Portra 400 - Last Summer", Save is disabled while the field is empty, Return saves, Esc cancels.
2. In the FILMS tab the strip under the canvas starts with a PRESETS group (before any preset exists it shows one SAVE A PRESET slot), then the FILMS group; the family tabs filter only the films. A card with a thumbnail, "Portra 400 - Last Summer" and the film caption appears and is marked as applied. Hover it over a different look: the canvas previews it with a PREVIEW chip; the UNSAVED mark does not change. Change film and sliders, click the card: film and sliders return, the crop stays.
3. Right-click the card: Rename… (nickname only), Duplicate (adds "… copy"), Delete… (asks first). Rename to an empty name is refused.
4. In Photos, open any picture and choose Edit ▸ Mira: the FILMS strip lists the same preset (the extension reads the shared App Group file; it also picks up a preset saved in the app a moment ago). Save one there and check it shows in the app after it becomes active.
5. Delete a film's entry from a copy of `Films/films.json` (or edit `Presets.json` so a preset names an unknown `filmID`): the card shows FILM MISSING and applying it applies the develop settings with a notice.
6. `codesign -d --entitlements - Mira.app` and `.../PlugIns/MiraPhotos.appex` both list `com.apple.security.application-groups` with `VF945J28YU.com.fieldframes.mira`.

### Dodge & burn

1. Open a photo, press 2, scroll to DODGE & BURN and switch PAINT on. The cursor becomes a ring; drag across a dark face: it lightens (DODGE, MIDTONES). Release: UNSAVED appears and one row is added to STROKES. `[` and `]` change the ring, the Size slider follows. Hold ⌥, start a stroke: it burns instead (the ring's centre mark changes while ⌥ is held); the brush stays on DODGE.
2. Press O: a red wash shows exactly where the strokes are; O again hides it. Click a stroke row: the sliders now edit that stroke (header reads STROKE 02); change Strength and the picture follows. Eye hides it, the cross deletes it, CLEAR ALL empties the list. Esc leaves the tool; 1 or 3 does too.
3. Zoom with ⌘= to 200% (then ⌘-); pinch and Space-drag also work; paint zoomed in and fit again: the strokes are where you painted them. Crop the photo, rotate it a quarter turn and straighten it: the strokes stay on the same part of the picture.
4. With PROTECT TONES on, dodge a bright sky with HIGHLIGHTS: it brightens without clipping to flat white; turn it off and it does. Switch on LUMINOSITY RANGE and move Low/High: only that band of tones changes.
5. Save to Photos, close the picture and reopen it in the app and in Photos ▸ Edit ▸ Mira: every stroke is back and editable. Save a preset on that photo, apply it to another: the film and sliders come over, the strokes do not; applying it back on the first keeps its strokes. The Save Preset sheet carries the note about strokes.
6. Tablet pressure: with a Wacom or similar pen, press lightly then firmly in one stroke: the line builds from faint to strong (Flow low makes it easy to see). With a mouse or trackpad pressure is constant.
7. Photos extension: Edit ▸ Mira, DEVELOP, PAINT; paint, Done, reopen: strokes persist (format version 3). Check with an older build that a version 3 edit is refused rather than shown without strokes.
8. Painting stays smooth on a 24 MP photo at full window size; see docs/PERFORMANCE.md for the numbers.

### Sharing presets

1. Right-click a preset card ▸ Share…: the system share sheet opens anchored to the card. Send it by AirDrop to another Mac (or Mail it to yourself): the attachment is named "Portra 400 - Last Summer.mirapreset".
2. Right-click ▸ Export…: a save panel with the same default name; save to the Desktop and open the file in a text editor: JSON with `"format" : "com.fieldframes.mira.preset"`, `"schemaVersion" : 1`, the recipe and no `crop` settings other than the identity, no image data.
3. Preset ▸ Export All Presets…: choose a folder; one `.mirapreset` per preset appears (same-named presets get " 2" in the file name). With no presets a notice says so.
4. On the other Mac (or after deleting the preset): double-click the `.mirapreset` in Finder. Mira opens (also with no photo open), the preset is stored and a notice reads "Imported 1 preset." The FILMS strip shows it; in Photos ▸ Edit ▸ Mira it is listed too.
5. Preset ▸ Import Presets… (⇧⌘I): select several files at once. Drag a `.mirapreset` file onto the FILMS strip, and onto the library window: both import. Dragging a photo still opens the photo.
6. Import the same file again: a "Preset Already Exists" dialog offers Replace, Keep Both and Skip (Esc skips). Keep Both saves "Portra 400 - Last Summer 2"; import it again for "… 3". With several duplicate files tick Apply to all and the answer is used for the rest.
7. Import a text file renamed to `.mirapreset`, and a file with `"schemaVersion": 2`: the notice lists each by file name ("not a Mira preset file", "made by a newer version of Mira"); valid files in the same batch still import.
8. Import a preset for a film you do not have: its card shows FILM MISSING and applying it applies the develop settings only.
9. In the Photos extension there is no Share…, Export… or Import… (it has no file access); presets still show, apply and save.
10. `plutil -p Mira.app/Contents/Info.plist` lists `UTExportedTypeDeclarations` (`com.fieldframes.mira.preset`, extension `mirapreset`) and a Mira Preset document type; Finder shows "Mira Preset" as the kind of a `.mirapreset`.

### Sharing a photo

1. Open a photo, click the share icon left of SAVE (or File ▸ Share…, ⌥⌘S): the icon becomes a spinner, then the system share sheet opens anchored to the button (from the menu: window centre).
2. Choose AirDrop to another Mac or iPhone, Mail (compose a message to yourself), Messages, Notes and Photos in turn: the attachment is "<name> - Mira.jpg", full resolution, with the look applied, upright (orientation 1) and the camera EXIF kept. Compare it with File ▸ Export of the same photo: same pixels and format.
3. File ▸ Export… with HEIC once, then Share: the file is now "<name> - Mira.heic" (Share uses the last Export format and quality).
4. With a large photo (24 MP) the button spins and a "Preparing to share" overlay shows if it takes longer than about 300 ms; clicking the button again meanwhile does nothing. Share is greyed out with no photo open (library view and empty window), while the crop tab is open, and while saving or loading.
5. Share twice: only the latest file remains in `$TMPDIR/MiraShareImage-*`; after quitting and relaunching those folders are gone.
6. The Photos extension shows no Share button.

### Light and dark

Switch System Settings ▸ Appearance between Light and Dark with the app and the extension open. Text, hairlines, cards and grain stay legible in both, the window toolbar stays just the wordmark and the editor strip stays ink-soft with a lichen tab underline, and the film description does not shift the panels as it changes.

### Self-test

```sh
open -a /Applications/Mira.app --args --selftest-photos
log show --last 10m --info --predicate 'subsystem == "com.fieldframes.mira"' | grep SELFTEST
```

It imports `App/SelfTest/sample.jpg` into the album "Emulsion Test", saves Velvia with grain through `AssetEditSession`, checks `hasAdjustments` and the recipe round trip, reverts and checks again. It never touches existing photos, but it leaves the test asset in place: delete it by hand.

## Key map and menus

The window toolbar shows the Mira wordmark and, at the trailing edge, the appearance toggle. Every command is in the menu bar, and the editor has a strip under the title bar: `← LIBRARY` (app only), the FILMS · DEVELOP · CROP tabs, then the status (UNSAVED / SAVED / REVERTED / READ ONLY), Share and SAVE (app only; the Photos extension shows the tabs only and uses Photos' own Save).

Menus:

- **File**: Open… (⌘O); Export… (⌘E, photo open, not while the crop tab is open); Share… (⌥⌘S, photo open); Save to Photos (⌘S; for a file the same item reads Save Sidecar and writes the sidecar now; disabled when there is nothing to save, read-only or preview-only); Revert to Original… (asks first); Back to Library (⌘←, guarded: asks about unsaved Photos edits).
- **Edit**: Reset Adjustments (sliders, curves and mixer; keeps film and crop); Reset All (everything except the photo).
- **Preset**: Save as Preset… (⇧⌘S, photo open, not while the crop tab is open); Import Presets… (⇧⌘I); Export All Presets….
- **View**: Films (1), Develop (2), Crop (3), Toggle Full Screen (F), Zoom In (]), Zoom Out ([), Zoom to Fit (⌘0).
- **View ▸ Appearance**: System / Light / Dark (checkmark on current), the same choice as the sun/moon button at the trailing edge of the window toolbar (click toggles Light/Dark, right-click offers all three; hidden in full screen) and Settings ▸ APPEARANCE; stored in `mira.appearance`.
- Mira ▸ Settings… (⌘,) and About Mira are unchanged.

Keys (single keys work when no text field is being edited, in the app and the extension; the extension has no menus):

| Key / gesture | Does |
|---|---|
| 1 / 2 / 3 | FILMS / DEVELOP / CROP tab (3 begins the crop tool; leaving it commits) |
| F | Full screen: window full screen (app) and every panel hidden, the photo alone on pure ink. Not available while cropping. In the extension F only hides the panels |
| Esc | Leaves that view (restores panels, leaves full screen). In the crop tab Esc is CANCEL |
| C (hold) | Shows the original while held; releasing returns to the edit. Mouse: press and hold HOLD TO COMPARE |
| Click on the photo | Fit → 200% centred on the click; click again → fit. Not in the crop tab, not while the eyedropper is active |
| Drag, Space + drag, two-finger scroll or wheel | Pans while zoomed (scroll follows the fingers, momentum included; at fit scroll passes through). Space alone does nothing. Pinch zooms between fit and 400% at the pointer |
| ] / [ (dodge & burn tool open) | Brush bigger / smaller; zoom moves to ⌘= / ⌘-. O toggles the mask overlay, Esc leaves the tool, ⌥ at the start of a stroke flips dodge and burn |
| ] / [ | Zoom in / out through fit, 50%, 100%, 200%, 400% (anchored at the pointer over the photo, else the centre); a readout (100%) shows bottom left for about a second |
| ⌘0 | Zoom to Fit |
| ⌘O / ⌘E / ⌘S / ⌘← / ⌘, | Open / Export / Save / Back to Library / Settings |
| Return, Esc (crop tab) | DONE (commit, back to the previous tab) / CANCEL (put back the crop you had, stay in the tab) |

Check by hand after a change to the editor chrome:

1. Open a photo. The strip shows `← LIBRARY`, FILMS (underlined in lichen), DEVELOP, CROP. FILMS shows the film strip and, on the right, the film name and STRENGTH. DEVELOP shows the histogram, sliders, curves, mixer, TEXTURE and FRAME with RESET at the foot, and no film strip.
2. Press 3: the crop box appears. Change the ratio, press CANCEL: the box returns to the committed crop and the tab stays. Press DONE: the crop is kept and the previous tab returns. Press 3 then 1: the crop is committed.
3. Press F: the window goes full screen with only the photo on dark ink. F or Esc returns. In the Photos extension F hides the panels only.
4. Hold C: the original shows; release: the edit returns. Click the photo: 200% around the click, with `200%` bottom left for about a second; drag pans; two-finger scroll pans; pinch zooms; hold Space and drag pans; `]` and `[` step; click again or ⌘0 fits. In DEVELOP at 200%, moving a slider updates the zoomed view at once.
5. File ▸ Save adapts: Save to Photos for a Photos picture, Save Sidecar for a file. The SAVE button in the strip does the same and reads SAVED afterwards.
6. In Photos, resize the Mira editing window: the editor follows the window; the right panel is 300 to 340 pt wide and scrolls.

## Automated tests

Dodge & burn adds `DodgeBurnModelTests`, `DodgeBurnMaskTests`, `DodgeBurnRenderTests` (MiraCore, 28) and `DodgeBurnUITests` (MiraUI, 12, writing `dodgeburn-*.png` snapshots), plus the opt-in `DodgeBurnPerf`.

```sh
swift test --package-path Packages/MiraCore
swift test --package-path Packages/MiraUI
```

With presets the suites hold 186 (MiraCore) and 87 (MiraUI) tests (new: `PresetTests`, `PresetStoreTests` incl. two stores on one directory, `PresetModelTests`, `PresetSnapshotTests` writing `presets-tab-*.png` and `save-preset-sheet-*.png`). Before that, as of the editor-workflow change the suites hold 170 (MiraCore) and 68 (MiraUI) tests; the lists below are the original groups. New: `ZoomTests` (click, step, pan, clamping, viewport-to-image rect with crop, zoomed render pixels), `EditorTabTests`, `ViewingKeysTests` (key map table, zoom model, compare key, full screen), `ExtensionHostingTests` (editor fills a resizing window), plus the `editor-tab-*.png`, `editor-zoom-100.png` and `editor-immersive.png` snapshots.

MiraCore has 36 tests:

- Renderer (6): neutral recipe returns the input unchanged; rendering is deterministic; extents are preserved except with a border; warmth and tint move in the right direction; grain is resolution independent; export keeps orientation and size.
- Recipe (4): JSON round trip; empty object gives defaults; unknown keys are ignored; adjustment format identifiers.
- Film (2): a synthesised film round-trips through the library and Strength blends correctly; every bundled film renders plausibly.
- LUT (7): identity `.cube` parses; `.cube` domain is normalised; bad `.cube` input is rejected; identity HaldCLUT; bad Hald size rejected; resampled identity stays identity; large Hald is capped at 64.
- Adjustment, sidecar, source and cache (14): adjustment encode/decode round trip; foreign identifier and version rejected; legacy `com.dwjames.emulsion` still decodes and new saves write `com.fieldframes.mira`; legacy `.emulsion.json` sidecar is read, migrated on save and removed on revert; `PHAdjustmentData` round trip; sidecar URL keeps the extension; save, load and remove; fallback when the folder is read-only; foreign sidecar format rejected; RAW detection; explicit orientation swaps dimensions; LUT cache hit matches and a corrupt cache file is tolerated; prewarm loads every film.
- Photo library logic (3): RAW identifiers; dirty check; sidecar status lines.

MiraUI has 12 tests:

- Theme (6): every token has the exact value in both appearances; CSS names are custom properties; fonts register and resolve; the display weight axis applies; the cell grid; the grain tile is generated and not uniform.
- Hover (5): hover shows the preview after the debounce and ending it returns; hover never mutates the recipe; a rapid sweep ends on the last card; applied film and Compare behaviour.
- Snapshot (1): renders the editor and films browser headlessly to `build/snapshots`. Inspect them by eye.

Timing of the LUT cache:

```sh
swift run --package-path Packages/MiraCore mira-sheet --time-luts --films Films
```

Contact sheets:

```sh
scripts/contact-sheet.sh [input.jpg]
```

Writes `build/contact-sheet.png` (every film) and `build/contact-sheet-effects.png` (first six films with grain, halation, bloom and vignette). Inspect them by eye.

## Manual checklist

| Case | What to check | Result |
|------|---------------|--------|
| Portrait orientation photo | Opens upright in the editor; saved result upright in Photos | |
| Landscape photo | As above | |
| iPhone HEIC in Display P3 | Colours stay saturated and consistent with the original after saving | |
| Large 48 MP RAW+JPEG | Editor stays responsive; Save Changes completes; result is full resolution | |
| RAW from disk and from the library | Decodes upright, saves, and the exported file is Display P3 | |
| Black and white film | Output is neutral monochrome; Saturation and Warmth behave sensibly | |
| Re-edit | Edit again restores film and every slider value | |
| Revert to Original | Photo returns to the untouched original | |
| Cancel confirmation | Cancel after changing a slider asks to confirm; Cancel with no changes does not | |
| Border, grain, halation | Visible in the saved result at full resolution, not only in the preview | |
| App edit reopened in the extension | Film and sliders restored, and the reverse | |
| Revert in Photos | Photo returns to the original; no EDITED badge in the app | |

## Known gaps and unverified

- Quitting the app or closing its window does not guard unsaved Photos edits. Switching pictures or returning to the library inside the app does.
- Limited-library mode has no "select more photos" button; change the selection in System Settings ▸ Privacy & Security ▸ Photos.
- Adjacent sidecars are rarely possible under the App Sandbox, which grants only the chosen file, so recipes usually go to the Application Support fallback.
- RAW+JPEG pairs: Photos may hand over the JPEG rather than the RAW.
- The extension may write HEIC or TIFF when Photos prefers it, while the app always writes JPEG for Photos edits.
- Counts and grids are pictures only, so video-only albums (Videos, Slo-mo, Time-lapse) count 0 and are hidden from the sidebar.
- Live Photos and video are unsupported (the extension declares Image only).
- Bundled films only; there is no custom LUT import.
- The LUTs from the 2015 collection are sRGB 8-bit.
- The built app is about 80 MB because the Films folder is duplicated in the app and the extension.
- Free-team signing lasts 7 days; re-run `scripts/install.sh` when the extension or app stops launching.

## Verification log (2026-10-20)

Run on macOS 27.0, Xcode 27.0, arm64, against the user's real Photos library (48,873 photos). Screenshots are in `build/` (git-ignored).

**Verified live (as Emulsion, before the rename; same code paths):**
- Install: `scripts/install.sh` succeeded; `pluginkit` listed the extension.
- Photos permission prompt shown on first launch and approved by the user.
- `--selftest-photos`: `SELFTEST PASS` (import into "Emulsion Test", save Velvia + grain, `hasAdjustments=true`, recipe equal on reopen, revert, `hasAdjustments=false`, recipe neutral). The first two runs crashed (PhotoKit change block isolated to the main actor under Swift 6); fixed by `PhotoKitBridge`, no crash since.
- Library grid with albums, smart albums, counts and EDITED badges; thumbnails sharpen after the opportunistic pass (`v-library.png`, `v-library-edited2.png`).
- Editor on the test asset through the UI: Velvia 50, Grain 0.40, Halation 0.30, SAVE → "SAVED TO PHOTOS", EDITED badge appears via the change observer, reopening restores every slider (`v-editor-velvia-light.png`, `v-saved.png`, `v-reopen.png`).
- Hover preview: "PREVIEW · NEOPAN ACROS 100" on a B&W canvas while Velvia stays applied; leaving the strip returns to Velvia (`v-hover-light.png`, `v-hover-exit.png`). The first attempt showed no preview (hover image was not observable); fixed, with a regression test.
- Reserved description space: the inspector does not shift between Original and a film.
- Light and dark appearance (`v-editor-dark.png`, `v-films-dark.png`).

**Verified after the rename to Mira:**
- Old app quit, old extension removed with `pluginkit -r`, `/Applications/Emulsion.app` deleted; `scripts/install.sh` from `~/Developer/Active/Mira` succeeded; `pluginkit -m -p com.apple.photo-editing -v` lists `com.fieldframes.mira.photos` and not `com.dwjames.emulsion.photos`. Bundle id `com.fieldframes.mira`, team VF945J28YU.
- Mira launches, asks for Photos access again (new bundle id) (`m-launch.png`); Films window with fixed chrome and byline (`m-films.png`).
- Tests: MiraCore 36, MiraUI 12, all passing.

**Not verified live:** the in-app REVERT button (revert verified through the self-test only), the Photos extension inside Photos, Finder double-click / `open -a` file opening and sidecars from the UI, RAW files, reopening the legacy-edited test asset in Mira (covered by unit tests).

## Verification log (2026-10-21)

Installed with `scripts/install.sh` (Mira already granted Photos access), driven against the real library:

- Sidebar: LIBRARY (Library 48,873, Favourites, Recently Saved), ALBUMS with real folders (Trips expands to nested albums and sub-folders, sorted like Photos), SHARED ALBUMS, MEDIA TYPES (Selfies … RAW, Animated). No UTILITIES section: PhotoKit returned no non-empty Hidden, Recently Deleted or Imports album for this library. Up/Down moves the selection.
- Opening the test asset: canvas showed the photo 0.3 s after Return; its recipe saved by Emulsion (`com.dwjames.emulsion`) was restored (legacy read verified live).
- Crop: CROP tab → handles, dimming, controls; SQUARE + 7.0° straighten; corner drag keeps the square; DONE shows the cropped result and `CROP · SQUARE · 7.0°`; film strip thumbnails cropped; SAVE → Photos thumbnail is the cropped image; reopening restores the crop; in-app REVERT (confirmation dialog) returns the uncropped original with neutral sliders. The test asset is left reverted.
- Grid: scrolling deep into the library, thumbnails (including RAW + EDITED badges) filled within about a second.
- Benchmarks (`mira-sheet --bench --films Films`, 24 MP synthetic, 1500×1000 canvas, M1 Pro): preview frame 12.0 → 4.7 ms median (p95 13.6 → 6.5); with crop + 6° straighten 6.5 → 3.8 ms; first preview 62 → 53 ms; 32 thumbnails warm ~40–57 ms; 24 MP export ~100–110 ms.

Not measured: SwiftUI-side slider drag latency and grid scroll frame rate (no reliable headless measure); use the `com.fieldframes.mira` / `perf` signposts in Instruments.

## Verification log (2026-10-21, develop workflow)

Installed with `scripts/install.sh` and driven live (test asset in "Emulsion Test" only; nothing saved to Photos):

- Library: empty window toolbar (wordmark only); collapsible LIBRARY / ALBUMS sections; albums and folders in the same order as Photos' own sidebar; breadcrumb for nested albums; FILTER popover with scope, show-only toggles, CAMERA and LENS lists populated from the metadata index (e.g. Fujifilm X100V 246) and "INDEXING n / 48873" progress.
- Menus: File (Open…, Export…, Save to Photos, Revert to Original…, Back to Library), Edit (Reset Adjustments, Reset All), View (Films, Develop, Crop, Toggle Full Screen, Zoom In/Out, Zoom to Fit).
- Editor tabs via 1/2/3: FILMS (strip + strength), DEVELOP (live histogram; a curve point added and dragged; Orange hue +48 in the color mixer; status UNSAVED), CROP (handles, controls, readout).
- Click-to-zoom shows 200% with the readout; `]` steps to 400%, sharp; ⌘0 fits. Holding C shows the original.
- F: true full screen, photo on ink, window toolbar hidden; Esc exits.
- Photos extension: listed in Photos' Extensions menu; with the fix it fills the editing window (1723×1063, then follows a resize to 1300×808 — confirmed by the `extension` log category); tabs FILMS / DEVELOP / CROP. Cancelled without saving.

Not verified live: Space-drag pan, mixer eyedropper, SAVE through the new sub-toolbar button, file-from-disk sidecar flow in the new layout.
