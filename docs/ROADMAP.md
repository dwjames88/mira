# Roadmap

## v0.1 (now)

- Photos editing extension and host app for macOS 26+.
- 31 bundled films (RawTherapee Film Simulation Collection, CC BY-SA 4.0).
- Strength, exposure, contrast, saturation, warmth, tint, grain, halation, bloom, vignette and border.
- Re-editable edits via adjustment data `com.dwjames.emulsion` v1.
- Host app export to JPEG, HEIC and TIFF.
- Not yet verified inside Photos; see [TESTING.md](../TESTING.md).

## Next

- **Custom `.cube` and HaldCLUT import.** The parsers exist in EmulsionCore. A free Personal Team has no App Group, so imported LUTs would have to live inside the extension's own container (and be imported there), or wait for a paid team and a shared App Group container that the app and extension both read.
- **More films.** Other CC-licensed collections, and a creative pack of original looks. Each needs its own attribution entry.
- **Pre-baked 64³ binary cubes.** Cuts first-use load time and bundle size, and lets the extension share films with the host bundle rather than duplicating them. Must keep the CC BY-SA 4.0 attribution and note the conversion.
- **Metal kernel grain.** Replace the soft-light noise with a CIKernel using a proper film-grain model, with a per-channel option.
- **Presets and favourites.** Save recipes by name; pin favourite films.
- **Crop-aware border.** Make the border follow Photos' crop rather than the full image extent.
- **iOS and iPadOS.** A `PHContentEditingController` extension on iOS sharing EmulsionCore and the editor model.
- **Batch export** in the host app.
- **Notarisation and distribution** once on a paid team.
- **Localisation.**
