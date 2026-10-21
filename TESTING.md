# Testing Emulsion

## Install

```sh
scripts/install.sh
```

This regenerates the project with xcodegen, builds Release into `build/DerivedData`, copies `Emulsion.app` to `/Applications`, verifies its signature, removes the build products' own extension registrations so only the `/Applications` copy is known, refreshes Launch Services (`lsregister -f`), registers the extension with `pluginkit -a` (retrying while registration settles), and elects it with `pluginkit -e use -i com.dwjames.emulsion.photos`. It finishes by listing Photos editing extensions and fails if Emulsion is not among them.

## Enable in Photos (macOS 26/27)

1. Open System Settings ▸ General ▸ Login Items & Extensions.
2. Scroll to the Extensions section and choose "By Category" (or by app).
3. Under Photos Editing, click the ⓘ button and turn on Emulsion.

Alternative: in Photos open a photo ▸ Edit ▸ click the ⋯ (More) or Extensions button in the toolbar ▸ More… This opens the same pane.

Then:

1. Open a photo in Photos ▸ Edit ▸ ⋯ ▸ Emulsion.
2. Pick a film, adjust the sliders, and click Save Changes.
3. To verify re-editability, choose Edit again ▸ ⋯ ▸ Emulsion and confirm the film and sliders are restored.
4. Revert to Original should return the untouched photo.

Check registration from the shell:

```sh
pluginkit -m -p com.apple.photo-editing -v | grep emulsion
```

## Troubleshooting

- **Extension missing from Photos or the list:** re-run `scripts/install.sh`; then `pluginkit -e use -i com.dwjames.emulsion.photos`; quit and reopen Photos; and, if needed, `/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/Emulsion.app`.
- **Extension fails to load or does nothing:** open Console, filter on `EmulsionPhotos`, and reproduce.
- **Stopped working after a few days:** the project uses Personal Team development signing. Free-team provisioning profiles last 7 days, so re-run `scripts/install.sh` to re-sign if the extension stops loading.

## Host app

```sh
scripts/run.sh
```

Check: the app opens; Open (or drag a photo onto the window) loads it; the film strip shows thumbnails and the family picker filters them; selecting a film updates the preview; press and hold on the preview or the Compare button shows the original; the Films window (Shift-Command-L) lists all 31 films and the credit; Export offers JPEG, HEIC and TIFF, and the written files open correctly with orientation and colour intact.

## Automated tests

```sh
swift test --package-path Packages/EmulsionCore
```

There are 19 tests:

- Renderer (6): neutral recipe returns the input unchanged; rendering is deterministic; extents are preserved except with a border; warmth and tint move in the right direction; grain is resolution independent; export keeps orientation and size.
- Recipe (4): JSON round trip; empty object gives defaults; unknown keys are ignored; adjustment format identifiers.
- Film (2): a synthesised film round-trips through the library and Strength blends correctly; every bundled film renders plausibly.
- LUT (7): identity `.cube` parses; `.cube` domain is normalised; bad `.cube` input is rejected; identity HaldCLUT; bad Hald size rejected; resampled identity stays identity; large Hald is capped at 64.

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
| Black and white film | Output is neutral monochrome; Saturation and Warmth behave sensibly | |
| Re-edit | Edit again restores film and every slider value | |
| Revert to Original | Photo returns to the untouched original | |
| Cancel confirmation | Cancel after changing a slider asks to confirm; Cancel with no changes does not | |
| Border, grain, halation | Visible in the saved result at full resolution, not only in the preview | |

## Known gaps and unverified

- The UI and the extension have **not** been run inside Photos by the build agent. The build was headless, so the extension flow above is untested end to end.
- Photos' acceptance of HEIC rendered output is untested. The extension writes JPEG unless Photos asks for HEIC (or TIFF) as its default rendered type.
- RAW originals are read with `CIImage(contentsOf:)`, so RAW decoding uses default settings.
- Orientation comes from the file's metadata. If Photos' `fullSizeImageOrientation` disagrees with an untagged file, the result would be wrong.
- Live Photos and video are unsupported (the extension declares Image only).
- Bundled films only; there is no custom LUT import.
- The LUTs from the 2015 collection are sRGB 8-bit.
- First use of a film loads a 1728² HaldCLUT (Ektar 100 is 4096²) and resamples it, so the first thumbnail strip may take a moment.
- The built app is about 80 MB because the Films folder is duplicated in the app and the extension.
