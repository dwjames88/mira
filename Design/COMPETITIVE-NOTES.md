# Competitive notes: Photomator 3.4.15 and Latent Manager 1.1.7 (for Mira)

Method: names, sizes, formats, Info.plist keys, entitlement keys, `otool -L` library names only. No files copied, no apps launched, no strings/disassembly, no JSON/data read.
Binding rule: ideas, architecture and vocabulary only. Nothing here is to be copied: no assets, LUTs, textures, tables, strings, UI copy, preset names or parameter sets. Each takeaway carries a "Mira way".

## 0. Licence terms
- Apple Standard EULA (fetched https://www.apple.com/legal/internet-services/itunes/dev/stdeula/), Scope of License: user "may not copy (except as permitted...), reverse-engineer, disassemble, attempt to derive the source code of, modify, or create derivative works of the Licensed Application". Exception where prohibited by law. It does not mention inspecting bundle layout. Photomator also ships its own `Contents/Resources/EULA_Photomator.pdf` (2 PDFs in Resources); I could not read it (no pdftotext), so its terms are unknown from allowed evidence.
- Consequence: I did only non-binary-content listing, plist, entitlement keys and linked-library names. No strings/disassembly/nm, per the brief. Nothing derived from code.
- Latent (fetched https://latentstudios.art, /terms): footer links Privacy, Terms, Refunds; no EULA page. Terms say "Please don't copy, redistribute, modify, or use them without permission", "You may not redistribute the software, its protected media or material data, or your account access", "Latent applications are licensed, not sold". No explicit clause on inspection or reverse engineering. I therefore kept to listing names and Info.plist, and did not open or hash any content. Nothing skipped for licence reasons; the Latent "protected media or material data" wording is why Mira must not touch or reuse their data.

## 1. Photomator: what is on disk
Evidence: `/Applications/Photomator.app`, 673M, bundle id com.pixelmatorteam.pixelmator.touch.x.photo, 3.4.15, min macOS 13. App 'PlugIns/Add to Photomator.appex' (48K), 'XPCServices/ExtendedRAWSupport.xpc' (32K; executable 139152 bytes, version 3.4.15, min macOS 12).
Frameworks (names, sizes): PXMPro 359M (resources), PTPhotoKit 36M, PTFoundation 43M, PXMKit 8.6M, PXMEngine 5.0M, PTImageIO 3.5M, PDFEngine, PSDEngine, SVGEngine, PTPaintTools, PTPaintSelection, PTObjectRemoval, PXMPhotoKitUI, PXMUIKit.
File counts by extension in the bundle: 1320 strings, 1137 plist, 637 png, 60 nib, 55 bin, 42 cube, 36 ttf, 36 mp4, 13 each of weights/shape/net (ML parts), 13 json, 6 car, 5 metallib, 1 mom.
Entitlement keys (codesign): app-sandbox, assets.pictures.read-write, iCloud CloudDocuments container, ubiquity kvstore, application-groups 4R6749AYRE.com.pixelmator, maps.

## 2. Photos browser speed (findings and limits)
- Main executable links Photos.framework directly; PTPhotoKit and PTFoundation also link Photos, ImageIO. So PhotoKit is used, not a raw file scan of the Photos library (`otool -L` on Contents/MacOS/Photomator and Frameworks/PTPhotoKit/PTFoundation).
- PTFoundation links CoreData (and a `LegacyBrushModel.mom` model only, 8K, is bundled); PTImageIO links libsqlite3. So a local Core Data/SQLite store is plausible, but no Photos-specific model is bundled: unknown whether it holds a thumbnail/metadata DB.
- No thumbnail cache exists on this Mac: `~/Library/Caches/com.pixelmatorteam.pixelmator.touch.x.photo` is absent; `~/Library/Group Containers/4R6749AYRE.com.pixelmator/Library/Caches` is 0B; the sandbox container is 1.2M total. Group container Application Support is about 10M per app subfolder, holding only 126 .cube, 64 plist, 16 png (user presets/LUTs). Thumbnail formats and sizes on disk: unknown from allowed evidence (app evidently has not cached thumbnails to disk, likely relies on PhotoKit's own PHImageManager cache; inference, not proven).
- Separate extension targets: thumbnailextension, quicklookpreviewextension, photos-extension, remove-background exist as containers (`~/Library/Containers` listing) for the sibling Pixelmator app.
- Mira way: lean on PHImageManager/PHCachingImageManager with own sizing and prefetch windows; add our own small on-disk cache only if measurement shows need, with our own key scheme and sizes.

## 3. RAW
- ExtendedRAWSupport.xpc is a separate tiny sandboxable service linking PTFoundation, Swift CoreImage/AVFoundation shims, libc++ (otool -L). PTFoundation links CoreImage, ImageIO, Metal, MPS, Accelerate, Vision, CoreML. No RawCamera.bundle reference visible in otool output of these libraries (RawCamera is dynamically loaded by CoreImage anyway, so: unknown). Most plausible: Apple RAW decoding via CoreImage/ImageIO (CIRAWFilter), plus a helper XPC to isolate extended RAW formats. Inference.
- ML models (PXMPro Resources .mlmodelc, names): AutoCrop (45M), ColorFixing (59M), Decontamination, Deposterize, DeposterizeAnalysis, HorizonDetection, ImageAnalysis, MaskRefinement, NoiseAnalysis, NoiseReduction, ObjectDetection, SkyDetection, SuperResolution. These are editing aids, not a film look.
- Metal: default.metallib files in PTFoundation (104K) plus PTCIKernels.ci.metallib (16K, CoreImage kernels), PTPaintTools (72K x2, one apple-silicon), PXMEngine (16K). Small, so kernels are compact Core Image/Metal pieces.
- Mira way: our own CIRAWFilter pipeline in-process, our own kernel set and our own working colour space; use an isolated service only if a crash-isolation need appears.

## 4. Grain
- PTFoundation Resources holds `grain.png` (4.1M, PNG 2069x1026, 8-bit RGB) and `noise.png` (3.0M, 1024x1024, 8-bit RGB), plus light-leak JPGs (3000x2400 e.g. LightLeakLyra.jpg, 8 files), 35mm/instant frame and dust-speck overlays (webp/png). So Photomator's grain is texture-based (tiled/composited bitmap), not purely procedural. Content of the textures was not viewed.
- Mira way: generate grain procedurally in a Core Image/Metal kernel (seeded, resolution-independent, scaled to output size, per-channel and luma-dependent), so no texture to ship, no tiling, same result at any export size. Keep our own parameter model.

## 5. Looks
- 42 .cube files in `PXMPro.framework/.../Custom LUTs/` in 5 groups: Cinematic (7), Color Blindness, Duotone, Grayscale Conversion, Photo Filter. File sizes 52K to 230K (small grids). Presets in `Adjustments.library` (presets/ and collections/ plist folders, UUID-named), `Effects.library` (6 collection plists), `Crop.library`. Library bundles are folders with `*-LibraryInfo.plist`, `collections/`, `presets/`, `resources/`.
- User-added looks land in the shared group container (`.../Application Support/<bundle>/Custom LUTs` and `Presets`). 
- Mira way: our own stock model (see section 7), parametric rather than LUT-only, stored in our own format.

## 6. Latent Manager and Ritual
- `/Applications/Latent Manager.app` 17M, com.latent.manager 1.1.7, min macOS 14. Contents: MacOS/Latent Manager, Resources/latent-content-service (helper), Fonts (CormorantGaramond, DMSans, JetBrainsMono, OFL.txt), ProductIcons/TheRitual.png, TheMoment.png, PrintEngine.png, plus files named EntitlementPolicy.json, TrustedEntitlementKeys.json, ManagerReleaseKeys.json, ManagerContentRelease.json, PlateManifest.json (names only; not opened). Library/LaunchAgents: content-service and refresh plists.
- Info.plist keys: LatentContentReleaseURL ends `.../latent-print-engine/production/core-plates`, LatentRitualReleaseURL (`latent-ritual`), LatentLicensingServiceURL, LatentAccountServiceURL, LatentRitualOnSale = true. So Manager is a licence and content-delivery shell; films are delivered as "plates" content packages, from a server, not shipped in the Manager bundle.
- Ritual app is not installed (nothing in /Applications or ~/Applications). Support dir `~/Library/Application Support/Latent` is 20K: Manager/release-ledger.json, release-notes.json, Manager/Content/release-ledger.json, PrintEngine/preview.lpent (1567 bytes, extension .lpent = Latent print-engine file; not opened). 
- Answer on film organisation: unknown from allowed evidence. No stock files on disk; vocabulary only: "plates", "Print Engine". Stage names (negative, paper, scan, halation, rem-jet) are not visible in any file or directory name.
- Mira way: do our own pipeline stage model and naming; do not infer or copy their plate structure.

## 7. What Mira should copy as an approach (re-done our own way)
1. Delegate Photos access to PhotoKit and keep the library untouched; add our own light cache only if measured. Mira: own sizes and key scheme.
2. Isolate heavy or risky decoding behind a small XPC helper when needed. Mira: only if crash isolation justifies it.
3. Keep Metal/Core Image kernels small and compiled into a metallib. Mira: our own kernels.
4. Ship content as library bundles (info plist, collections, presets, resources) and put user content in an App Group container. Mira: our own stock package schema and naming.
5. Grain and film extras: Mira goes procedural rather than image overlays.
6. Separate engine frameworks from UI frameworks. Mira: MiraCore already fits.
7. Deliver paid looks as downloadable signed content packs, separate from the app binary. Mira: only if we ever sell content; our own scheme.

## 8. What Mira must not copy
- Any of their data and assets: the 42 .cube LUTs, grain.png, noise.png, light-leak/frame/dust overlays, ML models (.mlmodelc), preset and collection plists, Latent plates, .lpent files, fonts that are not freely licensed, icons.
- Their preset/collection names, parameter values, stage names, file formats or extension names, UI copy, URL scheme or API paths.
- Anything under Latent's licence/entitlement/key files. Never read, decode or imitate them. Never crack Ritual.
- Nothing from Photomator's binaries (Apple EULA forbids reverse engineering).
