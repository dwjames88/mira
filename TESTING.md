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

### Light and dark

Switch System Settings ▸ Appearance between Light and Dark with the app and the extension open. Text, hairlines, cards and grain stay legible in both, the window toolbar stays just the wordmark and the editor strip stays ink-soft with a lichen tab underline, and the film description does not shift the panels as it changes.

### Self-test

```sh
open -a /Applications/Mira.app --args --selftest-photos
log show --last 10m --info --predicate 'subsystem == "com.fieldframes.mira"' | grep SELFTEST
```

It imports `App/SelfTest/sample.jpg` into the album "Emulsion Test", saves Velvia with grain through `AssetEditSession`, checks `hasAdjustments` and the recipe round trip, reverts and checks again. It never touches existing photos, but it leaves the test asset in place: delete it by hand.

## Key map and menus

The window toolbar shows only the Mira wordmark. Every command is in the menu bar, and the editor has a strip under the title bar: `← LIBRARY` (app only), the FILMS · DEVELOP · CROP tabs, then the status (UNSAVED / SAVED / REVERTED / READ ONLY) and SAVE (app only; the Photos extension shows the tabs only and uses Photos' own Save).

Menus:

- **File**: Open… (⌘O); Export… (⌘E, photo open, not while the crop tab is open); Save to Photos (⌘S; for a file the same item reads Save Sidecar and writes the sidecar now; disabled when there is nothing to save, read-only or preview-only); Revert to Original… (asks first); Back to Library (⌘←, guarded: asks about unsaved Photos edits).
- **Edit**: Reset Adjustments (sliders, curves and mixer; keeps film and crop); Reset All (everything except the photo).
- **View**: Films (1), Develop (2), Crop (3), Toggle Full Screen (F), Zoom In (]), Zoom Out ([), Zoom to Fit (⌘0).
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

```sh
swift test --package-path Packages/MiraCore
swift test --package-path Packages/MiraUI
```

As of the editor-workflow change the suites hold 170 (MiraCore) and 68 (MiraUI) tests; the lists below are the original groups. New: `ZoomTests` (click, step, pan, clamping, viewport-to-image rect with crop, zoomed render pixels), `EditorTabTests`, `ViewingKeysTests` (key map table, zoom model, compare key, full screen), `ExtensionHostingTests` (editor fills a resizing window), plus the `editor-tab-*.png`, `editor-zoom-100.png` and `editor-immersive.png` snapshots.

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
