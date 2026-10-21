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

Check: the app opens; Open (or drag a photo onto the window) loads it; the film strip shows thumbnails and the family picker filters them; selecting a film updates the preview; press and hold on the preview or the Compare button shows the original; the Films window (Shift-Command-L) lists all 31 films and the credit; Export offers JPEG, HEIC and TIFF, and the written files open correctly with orientation and colour intact.

### Library browser

1. The sidebar lists All Photos, Favourites, your albums and the non-empty smart albums (RAW, Recently Added, Screenshots, Selfies, Portrait, Panoramas, Live Photos); counts match Photos.
2. The grid scrolls smoothly on a large library, thumbnails sharpen as cells appear, and the arrow keys move the selection.
3. RAW pictures carry a RAW badge; pictures with adjustments carry EDITED.
4. Double-click, or Return on the selection, opens the picture in the editor; Library in the toolbar returns to the grid.
5. Changes made in Photos while the app is open (a new favourite, a new picture) appear after a moment.
6. With Limited Access, only the chosen pictures appear and the header says LIMITED ACCESS.

### Photos round trip

1. Open a picture from the library, pick a film, adjust, and choose Save (Command-S). The footer reports the result and the EDITED badge appears.
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

Switch System Settings ▸ Appearance between Light and Dark with the app and the extension open. Text, hairlines, cards and grain stay legible in both, the toolbar stays a mono text bar without a glass capsule, and the film description does not shift the panels as it changes.

### Self-test

```sh
open -a /Applications/Mira.app --args --selftest-photos
log show --last 10m --info --predicate 'subsystem == "com.fieldframes.mira"' | grep SELFTEST
```

It imports `App/SelfTest/sample.jpg` into the album "Emulsion Test", saves Velvia with grain through `AssetEditSession`, checks `hasAdjustments` and the recipe round trip, reverts and checks again. It never touches existing photos, but it leaves the test asset in place: delete it by hand.

## Automated tests

```sh
swift test --package-path Packages/MiraCore
swift test --package-path Packages/MiraUI
```

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
- Live Photos and video are unsupported (the extension declares Image only).
- Bundled films only; there is no custom LUT import.
- The LUTs from the 2015 collection are sRGB 8-bit.
- The built app is about 80 MB because the Films folder is duplicated in the app and the extension.
- Free-team signing lasts 7 days; re-run `scripts/install.sh` when the extension or app stops launching.

## Verification log (2026-10-20)

_To be filled in by the lead._
