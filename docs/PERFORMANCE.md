# Performance

Measured, not guessed. Every number below comes from the two harnesses described under "Reproduce".

**Machine:** Apple M1 Pro, 10 cores. **Image:** synthetic 6000x4000 JPEG (24 MP). **Canvas:** 1500x1000 px (rendered as 1536x1024). 31 films. Release builds. Medians of repeated runs; the machine was shared with other builds while measuring (load average 10 to 50), so treat differences under about 10 % as noise.

## Result

The app was already well optimised, so the work was finding what was still left. Most suspects measured clean; three things were worth fixing.

| Measure | Before | After | Note |
|---|---|---|---|
| Slider change to published preview frame (model level) | 5.5 ms | 5.5 ms | Render is 2 to 4 ms; the rest is the task hop. Unchanged. |
| Film switch to published frame (model level) | 4.9 ms | 4.8 ms | Unchanged. |
| Film switch, Core only (effects recipe, new film every frame) | 3.8 ms | 3.7 ms | Same-film slider tick 2.0 ms. LUT is not the cost. |
| Burst of 120 slider changes to settled frame | 10 to 11 ms, 2 frames | 10 ms, 2 frames | Coalescing already works. |
| **SwiftUI work per slider tick** (mutate, layout, display) | **4.0 to 4.4 ms** | **2.3 ms** | Film strip no longer re-evaluates. |
| Film strip `body` evaluations per slider tick | 1 | 0 | |
| **Film strip refill after a crop** (32 thumbnails, to last card) | **150 to 250 ms, 33 strip evaluations** | **59 to 66 ms, 1 evaluation** | Thumbnails published in 60 ms batches. |
| Histogram compute, 1536x1024 frame | 0.33 ms | 0.35 ms | Already cheap; left alone. |
| Frame to histogram ready | about 50 ms | about 50 ms | That is the deliberate 20 Hz pacing, not compute. |
| LUT prewarm, cold disk cache (first launch only) | 487 to 654 ms (4 workers) | 277 to 505 ms (10 workers), median about 335 ms | Default is now 4 to 8 workers (8 on this Mac). |
| LUT prewarm, warm disk cache | 10 to 11 ms | 6 to 7 ms | |
| `FilmLibrary` init (`films.json`) | 0.3 ms | 0.3 ms | Nothing synchronous at launch. |
| **First preview frame in a new process** | **24 to 36 ms** | **12 to 15 ms** | Kernel warm-up runs in the background at launch. |
| Thumbnails, cold / warm disk / hot (32) | 716 / 75 / 54 ms | unchanged | |
| Export 24 MP JPEG, decoded source | 100 to 220 ms | unchanged | |
| Export, lazy file-backed source | 135 to 547 ms | unchanged | The app always exports from `fullSource()`, the decoded image. |

Preview frame times at 1500x1000 (effects 3.9 ms, effects+mixer+curves 4.5 ms, crop+6 deg 3.7 ms) are unchanged.

## After merging the new develop controls (main, 2026-10-22)

Re-run of `mira-sheet --bench` on main with Highlights/Shadows/Whites/Blacks, Texture/Clarity and Vibrance in the pipeline (same machine, load average about 13):

| Measure | Result |
|---|---|
| Preview frame 1500x1000, effects / effects+mixer+curves / crop+6 deg | 5.1 / 4.6 / 3.5 ms median |
| Stage: film + tone (highlights, shadows, whites, blacks; one kernel plus a reduced-size blur) | 2.5 ms (film only about 2.1 ms) |
| Stage: film + clarity, texture, vibrance | 3.3 ms |
| Film switch, effects recipe, new film every frame | 3.3 ms median |
| Histogram, 1536x1024 frame | 0.33 ms |
| LUT prewarm cold, 10 workers / warm | 296 to 306 ms / 7 ms |
| Thumbnails cold / warm disk / hot (32) | 510 / 71 / 54 ms |

The new stages are skipped when their values are 0, so a recipe that does not use them costs exactly what it did before.

## Dodge & Burn (feature/dodgeburn, 2026-10-23)

Painting must fit in a 16 ms frame at preview size. Measured with `mira-sheet --bench` (section h: 24 MP source, mask and canvas 1500x1000, release build) and the opt-in `DodgeBurnPerf` UI test (a 60-point drag on a 24 MP photo, one point per frame, pointer move to published frame).

| Measurement | Result |
|---|---|
| Mask rasterisation from scratch, 1 stroke (40 points, brush 10% of the short side) | 0.8 ms |
| ... 10 strokes | 7.3 ms |
| ... 50 strokes | 37 ms |
| Live stroke, +1 point with 10 strokes cached (mask only) | 0.7 ms |
| Graded frame, effects recipe, no strokes / 10 / 50 strokes (cached masks) | 14.2 / 15.1 / 14.8 ms |
| Painting frame in the bench (10 cached + live stroke, whole graph, CGImage read back) | 17.0 ms median, 18.9 ms p95 |
| Painting frame in the editor model (`DodgeBurnPerf`), empty photo / 10 strokes painted | 6.8 / 6.9 ms median, 7.6 / 7.7 ms p95 |

How it stays fast: strokes are stamped as dabs into a float bitmap at the size of the graded image; the cache keeps the committed strokes' masks, a checkpoint one stroke back and the live stroke's coverage, so a new point only stamps its new dabs and a finished stroke only the one stroke on top. Strokes that share their settings share one mask, and each mask is one kernel pass (`miraDodgeBurn`). A picture longer than 4096 px gets its masks at reduced size (export) or for the visible region only (zoomed preview). With no active strokes the stage is skipped, so a recipe without strokes costs exactly what it did before. Editing an earlier stroke (its strength, hiding it) rebuilds the masks once, about 7 ms per 10 strokes at preview size.

## Film strip thumbnails: lazy and cached on disk (fs2-thumbs, 2026-11-04)

With 82 stock cards under "All", every open or crop change used to render a thumbnail for each card. Now:

- **Lazy.** The strip groups are `LazyHStack`s. A film card reports `onAppear`/`onDisappear` to the model, which renders the cards on screen plus 6 on each side (nearest to the screen first, the applied card ahead of them, Original always). Before any card has reported (no strip view, another tab open) the first 8 count as on screen. Each change of the window (40 ms settle) cancels the running batch and starts one for what is still missing; finished tiles stay cached in memory per crop. Batched publishing (60 ms) is unchanged.
- **Disk cache.** Tiles are JPEGs (quality 0.9) in `Library/Caches/<bundle id or "Mira">/Thumbnails/` (the Photos extension has its own folder), 200 MB bound, least recently used first (a hit touches the file's date). Written and read on the render worker threads, never the main actor. The file name is an FNV-1a hash of: film id, a film signature (LUT file size and mtime, resolved grain/halation character), source hash, crop, thumbnail size, pipeline number of the default recipe (`Recipe.currentPipeline`) and `ThumbnailCacheVersion.renderer`. Thumbnails are `Recipe(filmID:)` defaults on the cropped base, so no slider setting is part of the key. **Bump `ThumbnailCacheVersion.renderer` when the grading graph changes how a default film looks.** The source hash is taken from the cropped thumbnail base downscaled to 32 px (6 bits per channel), so it follows the photo, crop and RAW develop settings (all in the pixels), not the file path.
- Disk hits are delivered before any GPU work (no base render except the 32 px hash).

Measured with the opt-in `ThumbnailTimingTests` (`MIRA_PERF=1`, release, `Fixtures/sample.jpg`, 82 stocks + Original, canvas 1200x800, LUTs prewarmed, ms from `loadSource`, medians of 3). The machine was heavily loaded (load average 35 to 55 from other builds), so only the large differences mean anything:

| Case | First 8 thumbnails | Initial window (15 tiles) | All 83 tiles | Renders |
|---|---|---|---|---|
| Before: every card, no disk cache | 177 ms | 1789 ms (all) | 1789 ms | 83 |
| After, cold disk cache | 138 ms | 154 ms | 931 ms (scrolled through the whole strip) | 83 |
| After, warm disk cache | 73 ms | 73 ms | 166 ms | 0 |

Debug build (what `swift test` runs), same load: before 1715 / 7806 / 7806 ms, cold 973 / 1537 / 9447 ms, warm 74 / 74 / 140 ms. The cold "all" figure is not faster than before in total work (83 renders either way); the gain cold is that only 15 tiles are needed to show the strip, and warm that nothing is rendered. Snapshot and perf tests now wait for the wanted tiles (`EditorModel.thumbnailsSettled`) instead of all 83 (wait ceiling 180 s down to 90 s; the full `MiraUI` suite of 142 tests passes in about 165 s in debug under that load).

Reproduce:

```
cd Packages/MiraUI && MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --filter ThumbnailTimingTests
```

(writes `build/perf-thumbnails.txt`).

## Camera finder (Roll 1 proxy, Mac)

**These are proxies. The Roll 1 go/no-go measurement (30 fps sustained on a real iPhone 16 Pro, see `Design/CAMERA.md` section 6) is still outstanding.** A Mac GPU is not an A18 Pro; use these only to compare the cases with each other and to size the plan, not as a pass or fail.

What was added to `Renderer` for the live finder (capture and export always use the defaults, which render exactly as before):

- `withGrainSeed(_:)` / `grainSeedOverride`: a per-frame grain seed (integer below 2^24) instead of the photo's own. Never part of `Recipe`.
- `withTextureScale(_:)` / `textureScale` (0.25...1, default 1): halation (both pipelines), bloom and pipeline-2 grain do their work on a copy at that fraction of the resolution. Halation blurs the reduced highlights (sigma scales with the size) and enlarges the glow; bloom and grain run on the reduced copy and only what they added (result minus input) is enlarged and added at full size. The grain keeps its pitch in frame terms and takes its amplitude from the full-size pitch, so strength matches. Measured against textureScale 1 on a synthetic scene with strong halation, bloom and grain: mean colour within 0.1 %, halation energy within 1.5 %, grain RMS within 2 %.

Measured with the opt-in `FinderBudgetBenchmark` (`MIRA_PERF=1`): Kodak Portra 400 at native grain, halation and bloom (50 %), `Fixtures/sample.jpg` cover-fitted into an IOSurface BGRA buffer, a Metal-queue `CIContext` with the shared working space (extended linear sRGB, RGBAh, `cacheIntermediates` off), `startTask(toRender:to: CIRenderDestination(mtlTexture:commandBuffer:))` into a bgra8 texture, waited on; a new `CIImage` and grain seed every frame, 90 frames after 20 warm-up; ms per frame, CPU start to GPU complete.

Machine: Apple M1 Pro, macOS (Darwin 27.0.0), release build (`swift test -c release`), load average about 9 (2026-11-05, a quiet run; two earlier runs at load 340 to 470 were discarded as noise).

| Case (ms) | 1920x1440 median | p95 | 1206x1809 median | p95 |
|---|---|---|---|---|
| full | 9.1 | 10.4 | 9.4 | 10.2 |
| grain off | 6.9 | 8.9 | 5.9 | 7.4 |
| textureScale 0.5 | 11.4 | 12.8 | 9.2 | 9.8 |
| textureScale 0.5 + grain off | 5.6 | 8.4 | 4.0 | 6.8 |
| renderScale 0.75 | 7.6 | 9.1 | 7.0 | 9.2 |

Other costs, same run: `latitudeReading` on a 1920x1440 frame 6.2 ms median (6.5 p95), run on a utility queue every 15th frame (2 Hz at 30 fps), so off the frame path but above the plan's 3 ms target; 8 film-door card thumbnails at 220 px 22 ms median (33 p95) per batch, above the plan's 10 ms target, run at most at 2 Hz on a utility queue while the door is open.

iOS simulator (iOS 27.2 "iPhone Duo" type on the same Mac, so the Mac GPU through the simulator's Metal), through the camera's own `FinderRenderer.consume` path (`FinderBudgetSimTests`, `TEST_RUNNER_MIRA_PERF=1`), 1920x1440:

| Case (ms) | median | p95 |
|---|---|---|
| full | 17.5 | 22.3 |
| half texture (textureScale 0.5) | 19.3 | 23.7 |
| grain off | 11.8 | 15.2 |
| reduced (0.75 render scale, half texture, grain off) | 10.1 | 12.9 |

| Platform | Result |
|---|---|
| iPhone 16 Pro (device) | outstanding: the go/no-go (TESTING.md, camera checklist item 1) |

Reading:
- The full finder grade with native grain, halation and bloom fits a 33 ms (30 fps) frame with room on the Mac (9 ms) and in the simulator (18 ms). The plan's guess for an A18 Pro is 2 to 3x the Mac, about 20 to 30 ms: tight but inside the budget. Only the device can say.
- Grain is the stage that matters: grain off saves 25 to 35 %.
- **Half-resolution texture does not save time at finder sizes on these GPUs** (slightly slower: the reduce/enlarge passes cost about what the smaller blurs and grain save, because `softBlur` already downsamples wide blurs). It only pays together with grain off. It is built and switchable at runtime (camera settings, ADVANCED, FINDER QUALITY), but AUTO no longer steps through it (full, grain off, 0.75x, 24 fps). Confirm on the device.
- 0.75 render scale is the strongest single step in the simulator.

Reproduce:

```
MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --package-path Packages/MiraCore --filter FinderBudgetBenchmark
```

(prints the table to stdout; `-Xswiftc -enable-testing` is needed because the suite uses `@testable import`; record `sysctl -n machdep.cpu.brand_string` and `uptime` with the numbers.)

## What each change was

1. **Narrower observation (`EditorModel.selectedFilmID`).** `FilmStrip.body` read `model.recipe.filmID`, and `recipe` is one observed property, so every slider tick re-evaluated the strip and its 32 cards. The model now keeps a stored `selectedFilmID` that changes only when the film does, and the strip reads that. Result: 0 strip evaluations per tick, SwiftUI cost per tick 4.0 to 2.3 ms.
2. **Batched thumbnails.** Each of the 32 arriving thumbnails wrote the `thumbnails` dictionary and re-evaluated the strip (33 times). Results are now collected and published every 60 ms (and once at the end). A refill after a crop takes about 60 ms with one strip evaluation instead of 150 to 250 ms with 33.
3. **Launch warm-up (`PreviewEngine.warmUp`).** After the LUT prewarm, the app renders one 96x64 frame through every stage on the shared context, in a utility task, so Metal and Core Image kernel setup is paid in the background. First real frame in a new process: 24 to 36 ms down to 12 to 15 ms. It costs 20 to 40 ms of background time.
4. **Prewarm concurrency.** `FilmLibrary.defaultPrewarmConcurrency` is 4 to 8 workers (was fixed 4). Only the first launch after install sees it (afterwards the 16-bit disk cache is used).

## Tried, did not help

- **Caching a prebuilt `CIColorCubeWithColorSpace` per film** (copy of a template filter instead of rebuilding the filter with the 4 MB `cubeData` each frame): film-only stage 2.1 ms vs 2.1 ms, same-film tick 2.0 vs 2.0 ms, film switch 3.8 vs 3.7 ms. Core Image already holds the data cheaply. Reverted.
- **Histogram changes** (fewer samples, Accelerate, `CIAreaHistogram`): compute is 0.35 ms for about 175k samples, off the main actor and paced to 20 Hz. Nothing to gain.
- **Slider debounce:** a burst of 120 changes renders 2 frames; `RenderGate` already coalesces.
- **Export paths:** the app saves and exports from the decoded source, so the slow lazy-source case is not reachable.

## Reproduce

Headless pipeline, including film switch, histogram and launch rows (sections e, f, g):

```
cd Packages/MiraCore && swift build -c release --product mira-sheet && cd ../..
Packages/MiraCore/.build/release/mira-sheet --bench --films Films
```

First frame in a brand-new process, without and with the launch warm-up:

```
for w in 0 1; do MIRA_BENCH_COLD=1 MIRA_BENCH_WARMUP=$w Packages/MiraCore/.build/release/mira-sheet --bench --films Films; done
```

The dodge & burn rows are in the same bench run (section h). The painting drag timing:

```
cd Packages/MiraUI && MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --filter DodgeBurnPerf
```

(writes `build/perf-dodgeburn.txt`).

Model level and SwiftUI (drives a real `EditorModel`, hosts `EditorView` in an `NSHostingView`, counts film strip and card `body` evaluations; also writes `build/perf-ui.txt`):

```
cd Packages/MiraUI && MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --filter UIPerf
```

The UI test is skipped unless `MIRA_PERF=1`. Run on a quiet machine and repeat; one run on a loaded Mac can be 2x off.
