# Roadmap

## v0.2 (now)

- Photos library browser in the app: sidebar (All Photos, Favourites, albums, non-empty smart albums), caching grid with RAW and EDITED badges, non-destructive saves through PhotoKit, Revert to Original.
- One shared adjustment codec (`MiraAdjustment`), so edits from the app and the extension reopen in each other.
- RAW decoding with `CIRAWFilter` (default decode), Display P3 export.
- Files from disk: never overwritten, recipe autosaved to a sidecar (adjacent when writable, otherwise Application Support); open at launch and from Finder.
- Field Frames theme in the app and extension; mono text toolbar without glass.
- Hover preview of a film on the canvas, in the app and the extension.
- Disk cache of resampled 64³ cubes, parallel thumbnails and a launch prewarm (cold load of all films about 0.56 s, warm about 19 ms).
- Tests: MiraCore 36, MiraUI 12; `--selftest-photos` and `--selftest-sidecar`; `mira-sheet --time-luts`.
- Renamed from Emulsion to Mira (software by FieldFrames): new bundle ids `com.fieldframes.mira`, app and extension icons, "Software by FieldFrames" byline, Films window chrome fixed. Old adjustment data (`com.dwjames.emulsion`) and `.emulsion.json` sidecars are still read.
- Not yet verified inside Photos by a person; see [TESTING.md](../TESTING.md).

## v0.1

- Photos editing extension and host app for macOS 26+.
- 31 bundled films (RawTherapee Film Simulation Collection, CC BY-SA 4.0).
- Strength, exposure, contrast, saturation, warmth, tint, grain, halation, bloom, vignette and border.
- Re-editable edits via adjustment data `com.dwjames.emulsion` v1 (now `com.fieldframes.mira`, the old id is still read).
- Host app export to JPEG, HEIC and TIFF.
- Not yet verified inside Photos; see [TESTING.md](../TESTING.md).

## Next

- **Quit-time unsaved guard.** Warn on quit and window close when a Photos edit is unsaved.
- **Limited-library picker.** A "select more photos" button for limited-access mode.
- **Folder access grant for adjacent sidecars.** Keep a security-scoped bookmark of the folder so the sidecar can sit next to the image under the sandbox.
- **RAW decode controls.** Exposure, boost and noise reduction on `CIRAWFilter`.
- **Batch apply** a recipe to a library selection.
- **Presets.** Save recipes by name.
- **Custom `.cube` and HaldCLUT import.** The parsers exist in MiraCore. A free Personal Team has no App Group, so imported LUTs would have to live inside the extension's own container (and be imported there), or wait for a paid team and a shared App Group container that the app and extension both read.
- **More films.** Other CC-licensed collections, and a creative pack of original looks. Each needs its own attribution entry.
- **Metal kernel grain.** Replace the soft-light noise with a CIKernel using a proper film-grain model, with a per-channel option.
- **Favourite films.** Pin favourite films.
- **Share films between app and extension.** The Films folder is still duplicated in both bundles (about 80 MB).
- **Crop-aware border.** Make the border follow Photos' crop rather than the full image extent.
- **iOS and iPadOS.** A `PHContentEditingController` extension on iOS sharing MiraCore and the editor model.
- **Batch export** in the host app.
- **Notarisation and distribution** once on a paid team.
- **Localisation.**
