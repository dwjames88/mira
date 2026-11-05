# Mira Camera: plan (iOS)

Status: plan only, nothing built. Written 2026-11-05 against `main` = v1.0.0 (commit 9a1305a). Target: Roll 1 ships as **Mira 1.1.0** on iPhone; Rolls 2 and 3 follow.

Research method: public sources only (developer sites, App Store listings, FAQs, press reviews, Apple documentation and WWDC sessions, and the iOS 27 SDK headers in Xcode 27 beta for availability). No other app's binary, asset, look, preset, copy or UI was copied or inspected. Each claim about another app or an Apple API has a link in **Sources** (section 9). Anything marked **[ASSUMPTION]** is engineering inference, and **[VERIFY]** means it must be confirmed on a device or by an API spike before we build on it.

---

## 1. Concept

Mira already knows how film behaves. It knows how a stock's latitude holds a highlight, where its grain sits in the frame, how its halation spreads, how it fails at long exposures and how a print reads. Mira Camera brings that knowledge to the moment of exposure. You load a film, and the viewfinder shows the world through it, live, rendered by the same MiraCore pipeline that develops your pictures. You meter against that stock's latitude, not a sensor's, and you press the shutter. The frame goes into Photos as an untouched original with Mira's recipe attached. It stays a negative you can reprint, re-grade or put back to Original at any time. It is quiet, square-cornered and set in the Field Frames voice: ink ground, paper type, one lichen accent and mono readouts, like the data plate on a camera back. Rolls, frame counters and a develop step are there for people who want the ritual. They never stand between you and the picture.

The main point of difference, which our research supports, is the **live look**. mood.camera, the app the brief points to, has no live preview of its looks. Its FAQ says they "can't be rendered accurately in real time", and that is its most common complaint. Mira's renderer already draws a full film grade in about 4-5 ms per 1.5 MP frame on an M1 Pro (`docs/PERFORMANCE.md`). The camera is built around showing the real look in the viewfinder.

---

## 2. What the field does (research summary)

### 2.1 mood.camera (the reference in the brief)
- **Capture.** It has a custom ProRAW pipeline on iPhone 12 Pro and later, and a JPEG pipeline on other phones. Output is capped at 24 MP because 48 MP "took over 10 s" to process. It uses the HDR gain map to find the brightest highlights for halation and bloom. The look is applied at capture and "revealed" after each shot. The FAQ says the RAW is not kept with the processed photo. [mood-site] [mood-faq] [mood-appstore]
- **Looks.** 14 colour emulations, "inspired by film qualities rather than specific film stocks". Grain and tone are adjustable per look, and there is an Advanced Preset Editor and a Random Preset mode. Looks can be hidden and reordered. Custom presets can't be imported. [mood-site] [mood-faq] [mood-appstore]
- **Controls.** Point-and-shoot with an exposure dial, a grid and a level. I found no evidence of manual focus, WB, shutter or ISO, a meter or a histogram (inference from silence). [mood-site] [mood-why]
- **Other.** Portrait "lenses" modelled on real optics, double exposure with 7 blend modes, and custom frames. It can't import photos: "a camera app, not an editing app". [mood-appstore] [mood-faq]
- **Price.** 7-day trial, then $14.99 once or $1.99 a month. Solo developer Alex Fox. iOS 16+. [mood-appstore]
- **Praise:** "pushed me to concentrate on shooting more than editing", and grain that feels "organic rather than performative". **Complaints:** no live preview, inconsistent skin tones, occasional missed captures, too little grain control. [mood-appstore] [t2online] [gizmodo]
- **Not found:** whether it has rolls, frame counters, date stamps, a Camera Control or Lock Screen capture, or a light meter.

### 2.2 Adjacent apps (one line each; detail in Sources)
- **Dazz Cam.** A catalogue of camera "bodies" (135, 120, instant, disposable, CCD, half-frame) with date stamps, light leaks, double exposure and "save the negative and reprocess". Users complain the date stamp year can't be edited. [dazz]
- **NOMO CAM.** Camera bodies sold one by one, random analog presets per shot (dust, leaks, frames), instant cameras with a development time, and double exposure. Users complain about the annual-only Pro. [nomo] [nomo-sd]
- **Huji Cam.** The 1998 disposable: an orange date stamp, random leaks, no rolls or wait. Users complain it isn't full-screen and that photos are lost when changing phones. [huji] [huji-imore]
- **Gudak.** The strictest ritual: 24-shot roll, a viewfinder about 5% of normal size, no undo, and a 3-day wait to develop. It can be cheated by changing the phone's clock, and the leaks are uncontrolled. [gudak-9to5] [gudak-dcw] [gudak-engadget]
- **Dispo.** Shots develop at 9 am the next day, with social sharing. Users complain about ads and paywalls on developing, and lost photos. [dispo] [dispo-axios]
- **Halide.** The pro reference. Process Zero (no Apple processing, RAW), focus peaking and loupe, histogram, and a Mark III Photo Lab. It has no rituals. [halide-macstories] [halide-engadget] [halide-changelog]
- **Hipstamatic.** Lens + film + flash combos baked in at capture, Shuffle, multiple exposure, and a social feed in the newer app. Users complain about the move to a subscription. [hipstamatic] [hipstamatic-classic]
- **Lapse.** A shared 36-shot roll that develops 24 hours after the first shot. [lapse-tc] [lapse-phoblographer]
- **Filmic Firstlight.** Film simulations, ISO-adaptive grain, histogram and DNG. Its sims don't apply to RAW, and it moved to a subscription. [firstlight]

**Category gaps we can fill.** No source I read mentions an app with a film-aware light meter, a meter needle, frame lines or an advance gesture. Recurring complaints in the category are paywalls on basics, uncontrollable random effects, date stamps that can't be edited or removed, punitive or bypassable waits, lost photos with no backup, and non-full-screen finders.

---

## 3. Feature set, tiered

Each feature lists what you see, the film-photography idea behind it, the API or pipeline it uses, and the risks.

### Roll 1: MVP (ships as 1.1.0)

**R1.1 Camera entry.** You see a CAMERA control in the gallery header next to IMPORT, plus a home-screen quick action ("Load film"). Opening it shows the viewfinder in under one second. This is picking up the camera. The camera is a full-screen `CameraView` presented over the gallery, the same way `RootView` layers the editor over the gallery today, so the album path survives. Risk: cold start. The session start (`startRunning`) must run off the main thread, and we warm up the kernels (`PreviewEngine.warmUp` exists but iOS never calls it) while the session spins up.

**R1.2 Live viewfinder with the chosen film.** You see the scene through the loaded stock, its colour, tone curve, latitude shoulder, halation and bloom, at a steady frame rate. The grain is optional (see R1.7). Long-press the frame to see it without the film (the same gesture as the editor's hold-to-compare). Film photography is pre-visualising the stock. The path is `AVCaptureVideoDataOutput`, then `CVPixelBuffer`, then `CIImage(cvPixelBuffer:)` oriented upright and tagged with `withMiraHeadroom` and `withMiraExposureTime` from the frame's metadata. Then `Renderer.withPreviewScale(s).apply(draftRecipe, to:)`, rendered with a `CIContext(mtlCommandQueue:)` into a `CAMetalLayer` or `MTKView` with `isPaused = false`, driven by frames. `AVCaptureVideoPreviewLayer` can't be used because it gives no per-frame access. [wwdc26-303]

The draft recipe is the user's recipe at viewfinder quality: the same film, the same parameters, and `previewScale` equal to the preview size over the capture size, so grain pitch and every frame-relative radius match the capture (`FILM-SCIENCE.md`: all spatial parameters are relative to the frame).

Risks:
- The per-frame graph build and blur passes are the cost (see section 6).
- Grain is seeded from frame size, so it is frozen frame to frame and would look like a dirty screen. R1.7 handles it.
- The colour of the iOS `LivePreview` context (no explicit working space) and `Renderer.sharedContext` (extended linear sRGB, RGBAh) can differ. The camera must use `Renderer.makeContext`-equivalent options so the finder matches the saved photo. [VERIFY]

**R1.3 Film selection: stock cards, then options.** You see a film door. A FILM button in the bottom bar opens a sheet with the same parts as the editor's FILMS panel: the family tabs (ALL, COLOR NEGATIVE, SLIDE, BLACK & WHITE, INSTANT ...), a row of `FilmCard`s per stock (with the PRESETS group first), then the ISO and VARIATIONS chips and `OPTIONS +` (PUSH, SCAN, PAPER, TONING). The cards' thumbnails are rendered live from the current finder frame at card size, so you see your scene on each stock. This is loading a roll. You choose a stock and speed, and push or pull is decided before you shoot. It reuses `FilmStock`, `FilmBrowsing`, `FilmCard`, `ChipRow` and `OptionChip`, and `Recipe.applyingNativeTexture(filmID:)` so a new film starts at its own grain, halation and bloom. Presets come from `PresetHub` and apply as they do in the editor. Risks:
- Rendering about 8 visible cards from a live frame. Throttle this to around 2 Hz at 220 px, which is the same size as `PhotoEngine`'s thumbnail source.
- LUT and atlas first-use cost when you scroll quickly. Prewarm the visible stocks (`FilmLibrary` keeps 64 LUTs).
- **Note:** the brief mentions step icons and a "new editor flow". `main` has text tabs (CROP · FILMS · DEVELOP · DODGE & BURN) and an `OPTIONS +` toggle. If 1.0.1 changes that flow, the film door follows whatever ships. It must not invent a third pattern.

**R1.4 Exposure compensation, focus and white balance.**
- **What you see:**
  - An EV dial: a horizontal mono scale from -3 to +3 in thirds, dragged with the thumb, with a detent haptic on each third.
  - Tap to focus and meter. Long-press to lock AE/AF, which reads AE·AF LOCK in lichen.
  - A WB chip row: AUTO, DAYLIGHT 5500, CLOUDY 6500, TUNGSTEN 3200, FLUOR. 4000, plus a lock to the current value.
- **Film idea:** a compensation dial, focus and recompose, and choosing daylight or tungsten balanced film. The film's own balance comes from the stock; WB here is the light the film "sees".
- **APIs:**
  - `AVCaptureDevice.setExposureTargetBias(_:)` (within `min/maxExposureTargetBias`) and `focusPointOfInterest` / `exposurePointOfInterest` with `.autoFocus` / `.continuousAutoExposure`.
  - `exposureRectOfInterest` / `focusRectOfInterest` (iOS 26+, used when available).
  - `setWhiteBalanceModeLocked(with:)` using `deviceWhiteBalanceGains(for: AVCaptureWhiteBalanceTemperatureAndTintValues)`, with gains clamped to `1...maxWhiteBalanceGain`.
  - Everything inside `lockForConfiguration()`. [avf-device]
- **Risks:**
  - Exposure bias also brightens the finder, so the film shoulder must see the same thing. The finder and capture use the same device exposure, so it does.
  - WB in two places, on the device and in the recipe's `warmth` / `raw` temperature. Rule: device WB for the captured pixels, recipe WB untouched (0) at capture, so the editor's COLOR sliders start at neutral.

**R1.5 Film-aware light meter.**
- **What you see:** a meter at the top of the frame, a needle on a -3 to +3 scale in mono with a lichen centre mark. Under it, two small readouts.
  - "1/125 · ISO 64 · ƒ1.8", the camera's real exposure, from the device.
  - "UNDER 4% · OVER 1%", how much of the frame falls outside *this film's* latitude, from Mira's `LatitudeMeter`.
  - When the meter wants more light the needle swings left. When highlights fall past the film's shoulder, OVER turns paper-bright.
- **Film idea:** a match-needle meter, plus knowing your film. Negative film forgives overexposure and slide film doesn't. Mira already models that through `latitudeUnder` / `latitudeOver` per stock.
- **APIs:**
  - Needle: `AVCaptureDevice.exposureTargetOffset` (KVO), which is the device's metering error in EV.
  - Readout: `exposureDuration`, `iso`, `lensAperture`.
  - Film readout: `Renderer.latitudeReading(_:input:context:)`, which is already about 256 px on the long side and safe on any thread, run at about 4 Hz on the latest frame. [avf-device]
- **Risks:**
  - `latitudeReading` reads back to the CPU. At 4 Hz and 256 px that is cheap **[ASSUMPTION]**, so measure it.
  - On HEIC finder frames (display-referred) the latitude reading is limited to the SDR range. On a ProRAW-capable phone we can raise frame headroom from the EDR metadata. [VERIFY]

**R1.6 Capture: ProRAW where available, HEIC elsewhere, with the recipe as adjustment data.**
- **What you see:** press the shutter. The frame "closes" (a 1-frame ink blink), the counter advances, and a small thumbnail of the developed frame lands in the bottom-left corner. Tap it and the photo opens in the Mira editor on that film with the recipe ready to change. In Photos it shows as edited (Mira), and Revert to Original returns the untouched capture.
- **Film idea:** the negative and the print. The original is the negative; Mira's recipe is how it was printed.
- **APIs and pipeline:**
  - `AVCapturePhotoOutput` with `isAppleProRAWEnabled` (iOS 14.3+) when `isAppleProRAWSupported`.
  - Settings are `AVCapturePhotoSettings(rawPixelFormatType: <ProRAW format>, rawFileType: .dng, processedFormat: [AVVideoCodecKey: .hevc], processedFileType: .heic)`, a ProRAW DNG plus a HEIC pair.
  - Without ProRAW, HEIC only.
  - `maxPhotoDimensions` is 12 MP in Roll 1; 24 and 48 MP come in Roll 3.
  - `photoQualityPrioritization = .balanced`.
  - Zero shutter lag and responsive capture are on by default for iOS 17+ links. Use `AVCapturePhotoOutputReadinessCoordinator` to drive the shutter's enabled state. [avf-photo] [wwdc23-10105]
- **Save in two steps** (the pattern Mira's editor already uses):
  1. `PHAssetCreationRequest.forAsset()` with `.photo` = HEIC and `.alternatePhoto` = DNG (a RAW+processed pair, which `RawOpenPolicy` already handles on open).
  2. Fetch the new `PHAsset`, open an `AssetEditSession` on it and call `save(recipe:renderer:)`. This writes `MiraAdjustment.adjustmentData(for: recipe, rawBase: true)` and the full render, developed from the DNG through `RawDevelop`, which is the existing scene-referred path with the film shoulder. Format version "4" (pipeline 2).
- **Fallback when there's no ProRAW:** `.photo` = HEIC, `rawBase: false`.
- **Risks:**
  - **Two library writes per frame.** Between steps 1 and 2, Photos shows the plain original for a moment. That is acceptable, and if the app dies between the steps you still have the negative. A "pending prints" queue in the app container retries step 2 on the next launch.
  - **One-step creation is unverified.** Creating an asset with `.adjustmentData` + `.fullSizePhoto` resources in one request, which would avoid the moment of plain original, is unverified. The `.adjustmentData` resource expects Photos' own serialised form [VERIFY with a spike; do not depend on it].
  - **Step 2 needs read access.** `.readWrite` authorisation is required, because it needs a `PHContentEditingInput`. Mira already asks for read-write for its library. With add-only or limited access, we save the original plus a baked JPEG and say plainly that it is not re-editable.
  - **Deferred photo processing is off in Roll 1.** A proxy's final pixels arrive later, and an edit has to wait for them. Revisit in Roll 3. [wwdc23-10105]
  - **Render cost.** A full-quality RAW develop and render of 12 MP on the phone is unmeasured. The Mac export is 100-220 ms at 24 MP. It runs on a detached utility task, the shutter is never blocked, and a queue of at most N pending frames applies back-pressure (with "DEVELOPING 2" shown in the counter).
  - **Metadata.** `Renderer.export` copies metadata from a URL, so the capture is written to a temp file first (the HEIC from `fileDataRepresentation()`).

**R1.7 Grain, halation and bloom, native to each film at capture.**
- **What you see:** each stock's own texture by default (`applyingNativeTexture`, 50% = the film's level). Halation and bloom show live. A GRAIN control in the film door has three settings:
  - FINDER: OFF / LIVE, default LIVE.
  - AMOUNT and SIZE, the editor's sliders.
- **Film idea:** grain and halation belong to the stock, not a filter.
- **Pipeline:** the capture uses the deterministic grain seed, the same as the editor. The finder needs a **per-frame seed** so grain shimmers like projected film rather than sitting on the glass. That is a small MiraCore change: an optional `grainSeedOverride` on `Renderer`, similar to `withPreviewScale`, never written to a recipe.
- **Risks:**
  - Grain cost per finder pixel (up to 6x6 taps, `Grade.ci.metal`). If the frame budget is tight, FINDER: OFF saves it.
  - Halation and bloom blurs at finder size. The renderer already reduces blurs for large sigmas (`blurReductionThreshold`).

**R1.8 Lenses and zoom.**
- **What you see:** focal-length chips in mono, "13 · 24 · 48 · 120" (35 mm equivalents on the 16 Pro, not "0.5x / 1x"), plus pinch.
- **Film idea:** prime lenses. A film shooter thinks in millimetres.
- **API:** `builtInTripleCamera` or the best available virtual device, `videoZoomFactor` jumped to `virtualDeviceSwitchOverVideoZoomFactors`, and `displayVideoZoomFactorMultiplier` (iOS 18) to label correctly. The focal lengths are computed from the device's field of view, never hard-coded per model. [avf-device]
- **Risk:** devices differ. "48" is the 2x crop of the 1x lens, so its label must say it is a crop.

**R1.9 Hardware shutter.** Volume buttons, the Action button and a Camera Control press fire the shutter (captured on `.ended`). This is the shutter release. It uses `onCameraCaptureEvent` / `AVCaptureEventInteraction` (iOS 17.2). Risk: once adopted, every event must be handled. [wwdc25-253]

**R1.10 Haptics and shutter sound.**
- **Haptics:**
  - A rigid `UIImpactFeedbackGenerator` on shutter press.
  - A light selection tick on each EV third and lens detent.
  - A soft success on "frame developed".
- **Sound:** the system shutter sound. Mira does not ship a fake mechanical sound in Roll 1. Silent capture uses `isShutterSoundSuppressionEnabled` (iOS 18) only where `isShutterSoundSuppressionSupported` is true, because some regions require the sound, and it sits behind a Settings toggle that is off by default. [avf-photo]
- **Film idea:** the feel of a shutter. Haptics stand in for the mechanism.

**R1.11 Orientation.** `AVCaptureDeviceRotationCoordinator` (iOS 17) supplies `videoRotationAngleForHorizonLevelPreview` for the finder and `...Capture` for the photo connection. The UI chrome stays portrait and only the readouts rotate, as a camera's top plate does. [avf-rotation]

**R1.12 Permissions and privacy.** See section 5.5.

### Roll 2: the roll

**R2.1 Rolls (optional mode).**
- **What you see:** LOAD A ROLL in the film door, with a choice of 12, 24 or 36 frames, or ∞, the default, which means no roll.
- **While a roll is loaded:**
  - A frame counter in the top plate: "07 / 36" in mono, the number in Cormorant.
  - The film can't be changed mid-roll. Exposure, lens and WB can.
  - An optional "advance" gesture. A short swipe on the shutter arms the next frame, with a ratchet haptic. It is off by default and lives under Settings > Ritual.
- **Film idea:** a fixed roll of one stock.
- **Pipeline:** a `Roll` record (id, filmID plus the frozen recipe, length, frames with Photos local identifiers, loadedAt, developedAt) in the app container. Each roll also gets a Photos album named "Mira · Portra 400 · 5 Nov" through `PHAssetCollectionChangeRequest`.
- **Risks:**
  - Rolls must never trap or lose photos. Every frame is in Photos from the moment it is shot.
  - The roll is a view over Photos assets, not a store of its own.

**R2.2 Develop.**
- **What you see:** when the last frame is shot, or when you choose REWIND early, the roll shows as UNDEVELOPED in the Rolls list. DEVELOP reveals the frames one by one in a strip, timed to the roll's length, about 4 seconds in total, never days.
- **Optional "Develop overnight":** reveal at 9 am the next morning, an honest timer with no paywall and no clock-change cheat (it uses the stored date). It is off by default.
- **Film idea:** the wait and the reveal.
- **Honest constraint:** the frames are already in Photos, edited. The develop step hides them in Mira's own camera roll view and last-shot thumbnail only. We say so in one line: "Your frames are safe in Photos already; developing is how Mira shows you the roll."
- **Optional strict mode, "Print on develop".** Step 2 of R1.6, attaching the recipe, waits until develop. Photos holds the plain negative until then, which is closer to film. [ASSUMPTION: users who choose rolls want this.]
- **Risk:** PhotoKit failures at develop time. The pending-prints queue covers them.

**R2.3 Contact sheet.**
- **What you see:** a developed roll has CONTACT SHEET, which makes one image with the frames in strips of six, frame numbers, the stock name and the date along the rebate, in Mira's own typography. You can share it or save it to Photos.
- **Film idea:** the contact print.
- **Pipeline:** a new `RollSheet` renderer in MiraCore. It is related in spirit to the dev-only `ContactSheet` (films x states), but it is a new layout. It takes thumbnails from `PHImageManager` and composites in Core Image.
- **Risk:** the edge-marking text must be ours. No manufacturer's DX codes or trade dress.

**R2.4 Date stamp and edge markings, an optional export.**
- **What you see:** in Share / Export only, three toggles: DATE STAMP (style: Mira's own segmented numerals, colour amber or paper, position), EDGE (a thin rebate with frame number and stock name), and BORDER (exists).
- **Off by default.** The date is editable (Dazz and Huji users complain it isn't).
- **Film idea:** the datestamp camera and the scanned rebate.
- **Pipeline:** `ShareRender` overlay stages, deliberately **not** part of the recipe. A recipe field would bump the adjustment format to "5" and make the stamp part of the Photos edit, which older builds would refuse to open.
- **Decision to revisit:** if users want the stamp in Photos, add it as a format-5 recipe field later.

**R2.5 Camera Control (iPhone 16 and later).**
- **What you see:** light press and slide changes, in order, EXPOSURE (the system exposure-bias slider), ZOOM (the system zoom slider) and FILM (an index picker over the films in your "favourite stocks", or the presets).
- **Film idea:** the dial under your finger.
- **API:** `AVCaptureSystemExposureBiasSlider`, `AVCaptureSystemZoomSlider`, `AVCaptureIndexPicker`, `session.addControl`, `setControlsDelegate(_:queue:)`, all iOS 18. Check `supportsControls` / `canAddControl`. [avf-controls]
- **Risks:**
  - Film switching on the control triggers LUT loads. Prewarm the favourites.
  - The film picker must be disabled, not removed, during a roll.
  - Pinch must read the live zoom value so it doesn't start from a stale one.

**R2.6 Manual shutter and ISO, with reciprocity.**
- **What you see:** an M mode where the EV dial becomes two dials, SHUTTER (1/8000 to the device max) and ISO. The needle now shows how far off the meter you are.
- **For long times**, the readout shows Mira's reciprocity result for the loaded film: "1/4 s · −0.3 EV · cast +CC05R". The frame is captured with `exposureTime` stored so the reciprocity stage applies, which turns Mira's datasheet model (41 stocks) into a shooting tool.
- **API:** `setExposureModeCustom(duration:iso:)`, and `Reciprocity.effect(...)`. Zero shutter lag is unavailable with manual exposure, and that's expected. [avf-device]

**R2.7 Manual focus with peaking.** A focus ring, a slider at the frame edge, through `setFocusModeLocked(lensPosition:)`. Peaking is a lichen edge overlay, our own Core Image kernel, finder only. Film idea: focusing the lens.

**R2.8 Frame lines and formats.** Frame lines show 3:2 (35 mm), 6x6, 6x7 and 4:5, and the captured frame is cropped through the recipe's `CropSettings`. Nothing is thrown away and the frame can be uncropped in the editor. A stock's natural format could be a default, for example instant films at 1:1 or close to it. That needs a new per-film `format` field in `films.json`, which Mira doesn't have today. Film idea: the format of the camera.

### Roll 3: reach

**R3.1 Lock Screen and Control Center capture.**
- **What you see:** a Mira control in Control Center, on the Lock Screen and on the Action button that opens a locked viewfinder on your last film.
- **API:** a `LockedCameraCaptureExtension` with `LockedCameraCaptureUIScene`, plus a WidgetKit control widget whose intent is a `CameraCaptureIntent` (shared by the app, the widget and the extension), all iOS 18. [wwdc24-10204]
- **Constraints while locked:**
  - No shared group container.
  - PhotoKit can add assets but read only those from the session, so the two-step recipe save (R1.6 step 2) is not possible while locked.
- **Plan:**
  - Save the negative while locked, and write a small "pending print" JSON (asset local id + recipe) to `sessionContentURL`.
  - The main app collects it through `LockedCameraCaptureManager.sessionContentUpdates` on the next launch and attaches the recipe.
  - The extension must show a finder quickly or it is killed, so it uses the same `MiraCamera` module with a reduced film set (the last film and favourites only, to limit the LUT payload).
- **Risks:**
  - The extension's size and memory limits with a 126 MB film payload. Bundle only the recent stocks' cubes, or share them through the app bundle if allowed [VERIFY].
  - The app-group entitlement is missing on iOS today.

**R3.2 Double exposure.** Two frames combined in the film's density domain, adding exposure in linear light before the film stage, as on a real negative, not a Photoshop blend. The first frame is held as a ghost in the finder. It is saved as a new asset whose recipe references the second, and needs a new recipe field, which means format "5" [design spike]. Film idea: not advancing the film.

**R3.3 Higher resolution and deferred processing.**
- 24 MP (quality) and 48 MP (single frame), where `supportedMaxPhotoDimensions` allows.
- Deferred photo delivery (`.photoProxy`, iOS 17), with the recipe attached once the final photo exists, through the pending-prints queue.
- Only after Roll 1 measurements show the phone handles 12 MP renders comfortably. mood's 10-second 48 MP experience is the warning. [mood-faq] [wwdc26-304]

**R3.4 HDR finder and gain-map-aware halation.** Drive the finder in EDR on HDR displays, so the film shoulder is shown against real highlight headroom. For HEIC captures, read the gain map (`CIImage` `.expandToHDR` / `.auxiliaryHDRGainMap`) so halation and the shoulder see the real highlights. This is the same idea mood uses for halation, done through Mira's existing `miraHeadroom` path. [wwdc24-10177] [mood-site]

**R3.5 iPad.** The camera on iPad, landscape-first. Low priority.

### Intentionally not included, and why
- **Live Photos: no.** A Live Photo's movie would need the film look rendered frame by frame. Photos would play an unprocessed movie next to a graded still, and Bayer RAW forbids it. A moving clip isn't part of still film. Reconsider only if users ask.
- **Video.** It is a separate product (Kino-like). Out of scope.
- **Random light leaks, dust and scratches.** These are overlay tricks from other apps. Mira models physical processes and ships no textures (`COMPETITIVE-NOTES.md` §4, `GRAIN.md`). Users complain about leaks they can't control. Physical light-piping, if ever, would be modelled, optional and controllable.
- **Punitive waits, paywalled developing, ads, a social feed.** These are recurring complaints in the category. The develop step is a ritual you choose, never a lock.
- **A fake viewfinder or a tiny finder.** Gudak's 5% finder is a gimmick that hurts pictures. Frame lines (R2.8) carry the idea honestly.
- **Bayer RAW and Process-Zero-style capture.** Mira's RAW path is tuned to ProRAW and DNG through `CIRAWFilter`. Bayer RAW forbids ZSL and Live Photos and offers little over ProRAW for a film look. Revisit with RAW 9 (`CIRAWFilter.decoderVersion = .version9`, iOS 27). [wwdc26-305]
- **Camera bodies to buy.** Mira's stocks are the "bodies". No in-app purchases are planned.
- **Portrait or bokeh lenses.** Out of scope. Depth effects aren't film.

---

## 4. Architecture

### 4.1 Module: a new `MiraCamera` package
Put the camera in a new Swift package, `Packages/MiraCamera`, that depends on `MiraCore` and `MiraUI`. Don't build it inside `iOSApp/Sources`. Reasons:
- The Lock Screen extension (R3.1) needs the same code.
- The pure logic (state machine, meter maths, roll model, settings mapping, lens labelling) can be unit-tested headless with `swift test` on the Mac, the way MiraCore is.
- It keeps AVFoundation out of the editor target.

It has two layers.
- **Pure layer:** `MiraCameraKit`, compiles on macOS and iOS.
  - `CameraState`, a value-type state machine: idle, starting, running, capturing(n), interrupted(reason), failed.
  - `ExposureModel`: EV clamping, thirds, needle mapping from `exposureTargetOffset`, shutter and ISO stepping.
  - `LensCatalog`: focal-length equivalents from FOV and zoom factors.
  - `Roll` / `RollStore` (Codable, in the app container).
  - `PendingPrints` queue.
  - `FinderRecipe`: `Recipe` to finder recipe, a preview-scale computation, and the grain-seed policy.
  - `CaptureFormatPolicy`: ProRAW vs HEIC, dimensions, prioritisation from device capabilities, expressed as plain structs.
- **Platform layer:** `#if os(iOS)`.
  - `CaptureController` (session, devices, photo output).
  - `FinderRenderer` (video frames to Metal).
  - `PhotoSaver` (PhotoKit two-step save).
  - `CameraView` and SwiftUI parts.
  - Each talks to the pure layer through protocols: `CaptureDeviceControlling`, `PhotoLibraryWriting`. Tests can therefore substitute fakes.

MiraCore changes (small, each with tests):
- `Renderer.withGrainSeed(_:)` for the finder.
- `CIImage` tagging helpers made public, if they aren't already.
- An iOS `warmUp` call.
- An optional `Film.format` field.
- `RollSheet` (Roll 2).
- A one-step `AssetCreation` helper in `MiraAdjustment` if the spike in R1.6 succeeds.

### 4.2 Session management
- `actor CaptureController` whose `unownedExecutor` is a `DispatchSerialQueue`, the session queue. Under Swift 6 strict concurrency, every `AVCaptureSession` / `AVCaptureDevice` call is then isolated to one serial queue, which is what AVFoundation expects. (`DispatchSerialQueue` as an executor needs iOS 17+.)
  - `start()`, `stop()`, `configure(CaptureFormatPolicy)`, `setExposureBias`, `focus(at:)`, `setWhiteBalance`, `selectLens`, `capture(recipe:) async throws -> CaptureResult`.
- The session preset is `.photo` (needed for more than 12 MP later). Inputs are the virtual back camera.
- Outputs:
  - `AVCapturePhotoOutput`.
  - `AVCaptureVideoDataOutput` with `alwaysDiscardsLateVideoFrames = true`, BGRA or 420 bi-planar full range [VERIFY which renders cheaper through Core Image on A18; Apple gives no recommendation].
- Interruptions: observe `AVCaptureSession.wasInterruptedNotification` / `interruptionEndedNotification`, `runtimeErrorNotification`, and `systemPressureState`. When pressure is serious, the finder drops to FINDER grain OFF and half resolution, then to 24 fps.
- Background: stop the session when the scene goes inactive and restart when it becomes active.
- iOS 26 deferred start: with a video-data-output finder, set `automaticallyRunsDeferredStart = false` and call `runDeferredStartWhenNeeded()` after the first finder frame is presented. [wwdc26-303]

### 4.3 Finder rendering path
- `final class FinderRenderer: AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable`. Its delegate queue is a dedicated `finder` queue.
- It holds:
  - One `MTLCommandQueue`.
  - A `CIContext` built with the same working space and format as `Renderer.makeContext` (extended linear sRGB, RGBAh), plus `cacheIntermediates: false`, because inputs change every frame.
  - `CAMetalLayer`, `framebufferOnly = false`, `maximumDrawableCount = 3`.
- State shared with the main actor is a `Mutex<FinderState>` (Synchronization, iOS 18): the current `Recipe`, grain-in-finder, showingOriginal, the rotation angle and the zoom crop. It is written by the `@MainActor` `CameraModel` and read once per frame. This avoids actor hops on the hot path.
- **Per frame:**
  1. `CIImage(cvPixelBuffer:)`, rotated by the coordinator's preview angle.
  2. Lanczos-free downscale: request the video output at finder size, so there is no scaling.
  3. Tag `miraHeadroom` (1 for SDR) and `miraExposureTime` (from the sample buffer's exposure metadata) so reciprocity previews in M mode.
  4. `renderer.withPreviewScale(finderLong / captureLong).withGrainSeed(frameIndex).apply(recipe, to:)`.
  5. Aspect-fit into the drawable over ink.
  6. `ciContext.startTask(toRender:to: CIRenderDestination(mtlTexture:commandBuffer:))`.
  7. Present.
- **Latest-wins.** If the previous frame's command buffer hasn't completed, drop the new frame. The pattern matches `RenderGate` in `PreviewSizing.swift`.
- **Meter tap:** every 15th frame, hand a 256 px copy to a `utility` task for `latitudeReading`, and publish the result to `CameraModel` on the main actor.
- **Card tap:** about every 2 Hz while the film door is open, a 220 px frame for the cards.

### 4.4 Capture, render and save
1. `CameraModel.shutter()`, on the main actor, asks the haptic to fire, then `await controller.capture(recipe: finderState.recipe)`.
2. On the session actor, build `AVCapturePhotoSettings` from `CaptureFormatPolicy` and set the capture rotation angle. A per-request `PhotoCaptureDelegate` collects the `AVCapturePhoto`s: the DNG and the HEIC, both `fileDataRepresentation()`.
3. Write both to the app's `tmp/` (crash-safe).
4. `PhotoSaver` (an actor):
   - Step A: `PHAssetCreationRequest` with `.photo` = HEIC and `.alternatePhoto` = DNG, both with `shouldMoveFile = true`, inside a roll album if a roll is loaded. It returns the `localIdentifier`.
   - It enqueues `PendingPrint(assetID, recipe, rawBase)` in the app container.
5. Step B, on a utility task with a concurrency of 1:
   - `AssetEditSession(asset)`, then `load()`, then `save(recipe:renderer:)`. The RAW is developed through `RawDevelop`, `renderer.export` writes a JPEG at 0.95 to `renderedContentURL`, and `PHAssetChangeRequest.contentEditingOutput` is set.
   - On success, dequeue and post "frame developed" (the thumbnail lands).
   - On failure, the item stays queued and is retried at launch or when the app becomes active.
6. `AssetEditSession` is `@MainActor` today. Either let `PhotoSaver` call it from the main actor, since its heavy work already hops to `Task.detached`, or split a nonisolated `EditWriter` out of it. Choose during implementation, and prefer the split, so camera saves never compete with UI work.

### 4.5 Thread and actor model (Swift 6, strict concurrency complete)

| Component | Isolation |
|---|---|
| `CameraModel` (@Observable, all UI state) | `@MainActor` |
| `CaptureController` | actor on the session `DispatchSerialQueue` |
| `FinderRenderer` | finder queue; `Mutex` for shared state; `@unchecked Sendable` documented |
| `PhotoCaptureDelegate` (per shot) | AVFoundation callback queue, which resumes a `CheckedContinuation` |
| `PhotoSaver`, `PendingPrints` | actor |
| `Renderer`, `Recipe`, `Film` | already `Sendable` value types |
| `CIImage` / `CVPixelBuffer` hand-offs | `Unchecked` box (existing pattern) only across one hop |

### 4.6 Test strategy
- **Headless, on the Mac** (`swift test --package-path Packages/MiraCamera`):
  - State machine transitions, including interruptions.
  - `ExposureModel` (thirds, clamping, needle mapping).
  - `LensCatalog` against recorded FOV and zoom tables for 15 Pro, 16 Pro and 17 Pro, with fixture JSON.
  - `CaptureFormatPolicy` decisions.
  - `Roll` and `RollStore` round trips.
  - `PendingPrints` retry logic against a fake `PhotoLibraryWriting`.
  - **Finder-capture parity:** render a fixture image at finder size with `previewScale` and at full size, downscale the full render, and compare mean, colour and grain RMS within tolerance (extends `RendererTests` / `GrainModelTests`).
  - The finder recipe never carries a seed into the saved recipe.
  - Adjustment data written for a capture decodes as format "4" with `rawBase` set correctly.
  - A finder frame-time benchmark at 1206x1809 on the Mac (opt-in, `MIRA_PERF=1`) as a relative guard.
- **Headless iOS simulator.** The simulator has no camera. `MIRA_SNAPSHOT=1 MIRA_SNAPSHOT_TAB=camera` feeds a `FakeCaptureSource` that loops `sample.jpg` as frames, so `scripts/ios-snapshots.sh` can capture the camera layout, the film door and the roll views. This does not use the user's pointer or screen.
- **Real iPhone only** (a checklist in TESTING.md):
  - Frame time and thermals over 10 minutes.
  - ProRAW + HEIC pair save and re-open in the editor.
  - Revert in Photos.
  - Camera Control, hardware buttons and haptics.
  - Rotation.
  - Interruptions (a call, Control Center).
  - Limited or add-only access.
  - Memory with LUT switching.
  - The Lock Screen extension.
  - Signpost intervals: "finder frame", "capture", "develop", "save".
- There is no iOS test target today. Add one, `MiraCameraTests` running in the simulator, for the platform layer with fakes.

---

## 5. Design

### 5.1 Principles
- Field Frames tokens throughout:
  - Ground: `ink`.
  - Type: `paper`, `paperMid` and `paperDim`.
  - One accent, `lichen`, for the active state, the meter centre and a lock.
  - `hair` 1 pt dividers.
  - `onPhoto*` and `onPhotoVeil` for anything drawn over the finder.
- Type:
  - IBM Plex Mono `.ffLabel` for readouts.
  - Cormorant Garamond for the frame number and the film name only.
- Square corners. The only radius is the existing 2 pt button chrome.
- No glass. `THEME.md` says no glass, and the camera follows Mira's language, not iOS Camera's. Background grain (`FFGroundBackground(grain: 0.07)`) sits on the chrome, never over the finder.
- 8 x 16 pt cell grid. The gutter is 2 cells.
- The finder is the photograph, so nothing is drawn over it except the meter, frame lines and the focus mark, and all of those are `onPhoto` hairlines.

### 5.2 iPhone 16 Pro portrait (402 x 874 pt), 3:2 frame

```
┌──────────────────────────────────────────┐  status bar (system)
│ ‹ LIBRARY            PORTRA 400   07/36  │  48 pt header: back (chevron + mono, as in the editor),
│──────────────────────────────────────────│  film name in Cormorant, frame counter (roll only)
│   −3 ·  ·  −1 ·  ·   ▼   ·  · +1 ·  · +3 │  meter scale (mono), needle ▼ (paper), centre tick lichen
│   1/125  ISO 64  ƒ1.8   UNDER 4 · OVER 1 │  readout row, ffLabel 9 pt, paperDim; OVER → paper when >2%
│┌────────────────────────────────────────┐│
││                                        ││
││                                        ││
││          LIVE FINDER (3:2, 402 x 603)  ││  Metal layer, film look live
││                 ┌──┐                   ││  focus mark: 44 pt square hairline, onPhoto
││                 └──┘ AE·AF LOCK        ││  lock label in lichen when locked
││                                        ││
││  ┆                                   ┆ ││  frame lines (Roll 2) in onPhotoDim hairline
│└────────────────────────────────────────┘│
│   13      ·24·      48      120          │  lens chips, mono; active paper + lichen underline
│──────────────────────────────────────────│
│  −1  −⅔  −⅓   [ 0 ]  +⅓  +⅔  +1   EV    │  EV dial, horizontal drag, thirds detents
│──────────────────────────────────────────│
│ ┌────┐                            FILM ▸ │  last-frame thumb (taps → editor) · FILM door
│ │ ▣  │           ( ◯ )             WB ▸ │  shutter: 72 pt ring, paper hairline, ink fill
│ └────┘                                   │  WB door; long-press shutter → nothing (no burst)
└──────────────────────────────────────────┘  home indicator
```

- The header copies the editor header exactly: `chevron.left` with LIBRARY at 11 pt mono, paper, a 44 pt minimum hit area, and a 1 pt hairline under it. The camera is a sibling of the editor, so it gets the same back pattern. Whatever back and step pattern 1.0.1 ships (text tabs today, step icons if the new flow lands) is the one the camera's doors use. The camera does not get a third pattern.
- **Shutter.** A 72 pt ring with a 1.5 pt paper hairline and an ink fill. On press it fills lichen for 120 ms. When readiness is `notReadyWaitingForProcessing` the ring dims to paperDim. It does not dim for `notReadyMomentarily`.
- **Film door.** A bottom sheet on `ink-soft` with grain, laid out exactly like the editor's FILMS panel: family `FFTabBar`, card row, ISO and VARIATIONS chips, `OPTIONS +`, STRENGTH. Its last rows are GRAIN (FINDER OFF/LIVE, AMOUNT, SIZE) and, in Roll 2, LOAD A ROLL. The cards show your scene, live.
- **WB door.** One `ChipRow`: AUTO · 5500 · 6500 · 3200 · 4000 · LOCK.
- **Counter while developing.** "DEVELOPING 2" in mono paperDim replaces the counter.

### 5.3 Landscape
The finder takes the long side. The meter and lens chips move to the left edge and the shutter column to the right. Only the readouts rotate (`videoRotationAngleForHorizonLevelPreview`), and the chrome reflows. The iOS target already supports landscape.

### 5.4 Roll views (Roll 2)
- **ROLLS** is a gallery section: rows of rolls, with the stock name in Cormorant, "36 EXP · 5 NOV" in mono, and UNDEVELOPED or DEVELOPED.
- **DEVELOP** shows a strip that reveals frames left to right.
- **CONTACT SHEET** is a full-screen sheet on ink.
- The copy is plain and in the Field Frames voice: "Load a roll", "Rewind", "Develop", "Your frames are already safe in Photos."

### 5.5 Permissions and privacy
- **Camera:** add `NSCameraUsageDescription`, "Mira uses the camera to take pictures through your chosen film." Add it to both `iOSApp/Info.plist` and the `project.yml` `info:` block, because `GENERATE_INFOPLIST_FILE` is NO.
- **Camera denied:** the camera shows an `FFEmptyState` titled "Camera" with "CAMERA ACCESS IS OFF" and an OPEN SETTINGS button.
- **Photos:** Mira already asks for read-write. If the user has granted add-only or limited access, the camera still saves (the original plus a baked JPEG) and shows one line: "Allow full Photos access to keep frames re-editable." The baked JPEG uses the existing `saveToLibrary` path.
- **Location:** off by default. A Settings toggle "Add location to frames" asks for `NSLocationWhenInUseUsageDescription` only when it is turned on. No location is ever sent anywhere.
- **Microphone:** none. No video and no Live Photos, so there is no microphone permission.
- No analytics and no network. The Lock Screen extension has no network anyway.

---

## 6. Performance budget

These are targets, to be measured with the "finder frame" signpost on a real phone. No iPhone numbers exist in the repo yet.

| Item | Target | Basis |
|---|---|---|
| Finder size | the drawable: 1206 x 1809 px for a 3:2 finder on the 16 Pro (402 pt x 3) | `LivePreview` sizes to the drawable |
| Finder rate, A18 Pro (16 Pro) | 30 fps sustained, 60 fps stretch, grain LIVE | Mac M1 Pro: 3.9-5.1 ms per 1.5 MP effects frame (`docs/PERFORMANCE.md`). At about 2.2 MP and an A18 Pro GPU **[ASSUMPTION]** 2-3x slower, that is about 15-25 ms, so within the 33 ms of 30 fps |
| Finder rate, A17 Pro (15 Pro) | 30 fps with grain LIVE; fallback is grain OFF or 0.75x resolution | **[ASSUMPTION]** about 20 % slower than A18 Pro |
| Fallback ladder | 1) grain FINDER OFF, 2) finder at 0.75x drawable with GPU upscale, 3) 24 fps | `systemPressureState` and a measured frame time over 30 ms for more than 1 s |
| Meter | `latitudeReading` at 4 Hz, under 3 ms each | 256 px CPU read |
| Cards | 8 cards at 220 px, 2 Hz, under 10 ms per batch | |
| Shutter to "closed" blink | under 50 ms (ZSL) | `isZeroShutterLagEnabled` default |
| Capture to developed thumbnail, 12 MP ProRAW | under 2.5 s, off the main thread | Mac 24 MP export 100-220 ms, plus RAW develop, plus PhotoKit; **[ASSUMPTION]** |
| Memory | under 600 MB peak with 3 pending frames | ProRAW 12 MP DNG about 25 MB **[ASSUMPTION]**; LUT cache capped |
| Thermals | 10 min of finder without `serious` pressure on 16 Pro | measure |

The **Roll 1 go/no-go gate** is a spike on a real 16 Pro: the full film grade at drawable size must sustain 30 fps. If it doesn't, Roll 1 ships the finder with halation, bloom and grain at half resolution, and the capture stays full quality. The live look is the feature, so it gets measured before anything else is built.

---

## 7. Estimates and sequence

Agent-hours mean implementation plus headless verification by agents. Device checks by the user are not counted. The ranges reflect API spikes that may fail.

### Roll 1 → 1.1.0 (about 46-62 agent-hours)

| # | Step | Hours |
|---|---|---|
| 0 | **Spikes, gate first.** (a) Finder frame time on a real 16 Pro with a throwaway harness. (b) ProRAW + HEIC pair save, then `AssetEditSession.save`, then reopen in the editor. (c) One-step creation with an adjustment resource, informational only | 6-8 |
| 1 | `MiraCamera` package skeleton, pure layer (state, exposure, lens catalogue, format policy, pending prints) and tests | 6-8 |
| 2 | `CaptureController` actor: session, devices, rotation coordinator, interruptions, deferred start | 6-8 |
| 3 | `FinderRenderer` (Metal, latest-wins, `Mutex` state), the MiraCore `withGrainSeed` change, iOS warm-up, and parity tests | 7-9 |
| 4 | Capture plus `PhotoSaver` (two-step save, pending queue, add-only fallback), with the `EditWriter` split from `AssetEditSession` | 6-8 |
| 5 | UI: `CameraView`, header, meter and readouts, EV dial, lens chips, shutter readiness, last-frame thumb into the editor | 6-8 |
| 6 | Film door (reusing FILMS panel parts, live cards), WB door, GRAIN controls | 4-6 |
| 7 | Hardware buttons, haptics, sound setting, permissions and copy, the snapshot `FakeCaptureSource` | 3-4 |
| 8 | Docs (THEME, TESTING device checklist, CHANGELOG 1.1.0), review and fixes | 2-3 |

**Sequence.** Step 0 gates everything. Steps 1 and 3 can run in parallel. Step 2 runs after 1, step 4 after 2 and 3, step 5 after 2, steps 6 and 7 after 5, and step 8 last. Roll 1 ships as **1.1.0** when the device checklist passes. Branch off `main` after 1.0.1 merges, so the film door picks up any 1.0.1 editor changes.

### Roll 2 → 1.2.0 (about 34-44 agent-hours)
- Rolls, store and albums: 6-8.
- Develop, including overnight and print-on-develop: 5-6.
- Contact sheet (`RollSheet`): 5-6.
- Date stamp and edge as share stages: 4-5.
- Camera Control: 4-5.
- Manual shutter and ISO with reciprocity readout: 4-6.
- Manual focus with peaking: 3-4.
- Frame lines and formats, plus `Film.format`: 3-4.

### Roll 3 → 1.3.0 (about 30-42 agent-hours)
- Lock Screen extension, control widget, pending-print handoff and app-group entitlement: 12-16.
- Double exposure (format 5 recipe): 7-10.
- 24/48 MP and deferred delivery: 5-7.
- HDR finder and gain-map halation: 4-6.
- iPad layout: 2-3.

---

## 8. What we adapt, and what we won't copy

The user's standing rule is no plagiarism: we take ideas and mould them into Mira's own. Nothing in this plan uses another app's looks, presets, names, assets, textures, sounds, copy or UI layout.

| Idea seen in the field | Mira's own version |
|---|---|
| Look applied at capture, revealed after (mood) | Look shown **live** in the finder through MiraCore, and saved as a **re-editable recipe** over an untouched original. mood can't preview its looks and doesn't keep the RAW |
| Gain map used to find highlights for halation (mood) | Mira's existing scene-referred headroom (`miraHeadroom`) and film shoulder, with gain-map input as a Roll 3 extension of that path |
| 14 "inspired-by" looks (mood) | Mira's 51 stocks and 264 films, already modelled (latitude, grain from datasheet RMS, reciprocity). No looks are added for the camera |
| Fixed rolls, waits, 9 am develop (Gudak, Dispo, Lapse) | Optional rolls with a 4-second develop by default. Overnight is opt-in, has no paywall and can't be cheated with the clock. Frames are always safe in Photos |
| Date stamps (Huji, Dazz) | Export-only, off by default, editable date, Mira's own numerals and colour |
| Light leaks, dust (Huji, NOMO, Gudak) | Not included. Mira models physics and ships no overlays |
| Camera bodies (Dazz, NOMO) | The stock is the body. No purchases |
| Pro controls, peaking, histogram (Halide, Firstlight) | A **film-aware** meter (latitude per stock) and a reciprocity readout for long times. No other app in the research does either |
| Contact sheets | Mira's own sheet layout and rebate typography. No manufacturer markings or DX codes |
| Double exposure as blend modes (mood, Dazz, NOMO) | Exposure added in linear light before the film, as on a negative |

---

## 9. Sources

**mood.camera**
- [mood-site] https://www.mood.camera
- [mood-faq] https://www.mood.camera/faq
- [mood-why] https://www.mood.camera/why-i-built-mood-camera
- [mood-appstore] https://apps.apple.com/us/app/id6472954208
- [gizmodo] https://gizmodo.com/photo-apps-iphone-mood-huji-kamon-1851436284
- [t2online] https://t2online.in/tech/tech-reviews/mood-camera-review--why-this-analogue-inspired-iphone-app-stands-apart/2003328

**Adjacent apps**
- [dazz] https://apps.apple.com/us/app/id1422471180
- [nomo] https://apps.apple.com/ph/app/id1362548649?l=en-gb
- [nomo-sd] https://screensdesign.com/showcase/nomo-cam-point-and-shoot
- [huji] https://apps.apple.com/us/app/id781383622
- [huji-imore] https://www.imore.com/huji-cam-super-popular-new-app-turns-your-photos-1990s-film
- [gudak-9to5] https://9to5mac.com/2017/07/14/gudak-iphone-disposable-camera/
- [gudak-dcw] https://www.digitalcameraworld.com/news/this-app-makes-you-wait-three-days-for-pictures-to-develop
- [gudak-engadget] https://engadget.com/2017/07/14/gudak-turns-your-1-000-iphone-into-a-20-disposable-camera
- [dispo] https://apps.apple.com/app/id1491684197
- [dispo-axios] https://www.axios.com/2021/02/16/retro-photo-app-is-winning-buzz
- [halide-macstories] https://www.macstories.net/news/manual-camera-app-halide-introduces-process-zero-a-new-unprocessed-image-capture-mode/
- [halide-engadget] https://www.engadget.com/apps/iphone-camera-app-halide-has-an-anti-intelligent-mode-to-make-shooting-with-raw-easier-211802575.html
- [halide-changelog] https://www.lux.camera/halide-changelog
- [halide-mk3] https://www.notebookcheck.net/Halide-Mark-III-for-iPhone-promises-better-picture-quality-and-more-realistic-RAW.1214462.0.html
- [hipstamatic] https://apps.apple.com/au/app/hipstamatic/id1450672436
- [hipstamatic-classic] https://apps.apple.com/app/id342115564
- [lapse-tc] https://techcrunch.com/2021/12/20/lapse-an-app-that-lets-you-snap-and-develop-rolls-of-film-with-groups-of-friends-raises-11m-from-gv-and-others
- [lapse-phoblographer] https://www.thephoblographer.com/?p=241369
- [firstlight] https://apps.apple.com/us/app/-/id1482338564
- [kino] https://redsharknews.com/lux-optics-kino-camera-app-review-for-iphone
- [obscura] https://9to5mac.com/2022/02/17/obscura-3-camera-app-brings-a-revamped-interface-and-new-capture-modes/

**Apple platform**

Availability was checked against the iOS 27 SDK headers in Xcode 27 beta. The documentation landing-page links (avf-photo, avf-rotation, avf-device, avf-controls, phkit) are the API reference pages for the symbols named; the version numbers come from the headers.

- [avf-photo] AVCapturePhotoOutput: https://developer.apple.com/documentation/avfoundation/avcapturephotooutput
  - ProRAW: `isAppleProRAWEnabled` 14.3.
  - `maxPhotoDimensions` 16.
  - Constant colour 18.
  - ZSL, responsive capture and readiness coordinator 17.
  - Auto-deferred delivery 17.
  - Shutter-sound suppression 18.
- [wwdc23-10105] WWDC23 session 10105 (ZSL, responsive capture, deferred delivery): https://developer.apple.com/videos/play/wwdc2023/10105/
- [wwdc24-10162] WWDC24 session 10162 (constant colour): https://developer.apple.com/videos/play/wwdc2024/10162/
- [wwdc24-10177] WWDC24 session 10177 (HDR, gain maps in Core Image): https://developer.apple.com/videos/play/wwdc2024/10177/
- [wwdc24-10204] WWDC24 session 10204 (LockedCameraCapture, iOS 18): https://developer.apple.com/videos/play/wwdc2024/10204/
- [avf-rotation] AVCaptureDeviceRotationCoordinator (iOS 17): https://developer.apple.com/documentation/avfoundation/avcapturedevice/rotationcoordinator
- [avf-device] AVCaptureDevice manual controls (exposure, bias, `exposureTargetOffset`, lens position, white balance gains, zoom, `displayVideoZoomFactorMultiplier` 18): https://developer.apple.com/documentation/avfoundation/avcapturedevice
- [avf-controls] AVCaptureControl, AVCaptureSlider, AVCaptureIndexPicker, system zoom and exposure sliders (iOS 18): https://developer.apple.com/documentation/avfoundation/avcapturecontrol
- [wwdc25-253] WWDC25 session 253 (capture controls; AVCaptureEventInteraction 17.2; sound control iOS 26): https://developer.apple.com/videos/play/wwdc2025/253/
- [wwdc25-319] WWDC25 session 319 (cinematic video API): https://developer.apple.com/videos/play/wwdc2025/319/
- [wwdc26-303] WWDC26 session 303 (deferred start with AVCaptureVideoDataOutput): https://developer.apple.com/videos/play/wwdc2026/303/
- [wwdc26-304] WWDC26 session 304 (photo resolutions by prioritisation; iOS 27 deferred processing): https://developer.apple.com/videos/play/wwdc2026/304/
- [wwdc26-305] WWDC26 session 305 (RAW 9 in Core Image, `CIRAWFilter.decoderVersion`): https://developer.apple.com/videos/play/wwdc2026/305/
- [phkit] PHAssetCreationRequest / PHAssetResourceType (`.photo`, `.alternatePhoto`, `.adjustmentData`, `.photoProxy` 17), PHContentEditingOutput, PHAdjustmentData, PHPhotoLibrary authorization (`.addOnly` / `.readWrite`, iOS 14):
  - https://developer.apple.com/documentation/photos/phassetcreationrequest
  - https://developer.apple.com/documentation/photos/phadjustmentdata
- [forum-791234] WWDC25 camera lab summary (community, not official): https://developer.apple.com/forums/thread/791234

**Mira (this repo)**
- iOS app: `iOSApp/Sources/{RootView,EditorViewModel,LivePreview,MetalPreviewView,AssetEditSession,PhotoEngine}.swift`
- MiraCore: `Packages/MiraCore/Sources/MiraCore/{Renderer,LatitudeMeter,Reciprocity,MiraAdjustment,Recipe,FilmStock,FilmCharacter,GrainModel,RawDevelop,PreviewSizing,WarmUp}.swift`
- Design docs: `Design/THEME.md`, `Design/FILM-SCIENCE.md`, `Design/GRAIN.md`, `Design/COMPETITIVE-NOTES.md`
- Performance: `docs/PERFORMANCE.md`
