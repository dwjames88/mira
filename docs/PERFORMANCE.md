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

Machine: Apple M1 Pro, macOS (Darwin 27.0.0), release build (`swift test -c release`). Two runs on 2026-11-05: run A at load average about 9, run B (after the fallback and card changes) at about 14. Earlier runs at load 340 to 470 were discarded as noise.

| Case (ms, median / p95) | 1920x1440 run A | 1920x1440 run B | 1206x1809 run A | 1206x1809 run B |
|---|---|---|---|---|
| full | 9.1 / 10.4 | 11.3 / 14.7 | 9.4 / 10.2 | 10.2 / 11.3 |
| grain off | 6.9 / 8.9 | 8.9 / 10.8 | 5.9 / 7.4 | 7.6 / 9.9 |
| textureScale 0.5 | 11.4 / 12.8 | 11.2 / 12.2 | 9.2 / 9.8 | 10.3 / 14.0 |
| textureScale 0.5 + grain off | 5.6 / 8.4 | 8.0 / 9.4 | 4.0 / 6.8 | 7.3 / 9.9 |
| renderScale 0.75 (grain on) | 7.6 / 9.1 | 10.4 / 12.7 | 7.0 / 9.2 | 9.8 / 14.5 |

Meter and film-door cards (run B):

| Measure | Before | After | Plan target |
|---|---|---|---|
| `latitudeReading` | 6.2 ms (1920x1440 input, Lanczos inside) | 1.36 ms median, 1.46 p95 (256 px affine-scaled input, quickselect percentiles); 4 Hz on a utility queue | under 3 ms |
| 8 film cards | 22 ms per batch (220 px, full texture) | 6.2 ms median, 6.9 p95 (LUT only, from one 240 px copy made once per batch in 1.1 ms) | under 10 ms |

iOS simulator (iOS 27.2 "iPhone Duo" type on the same Mac, so the Mac GPU through the simulator's Metal), through the camera's own `FinderRenderer` (`FinderBudgetSimTests`, `TEST_RUNNER_MIRA_PERF=1`), 1920x1440, load about 11 to 17:

| Case (ms, median / p95) | run A | run B |
|---|---|---|
| full | 17.5 / 22.3 | 15.6 / 17.3 |
| half texture (manual option only) | 19.3 / 23.7 | 17.3 / 18.6 |
| grain off (AUTO step 1) | 11.8 / 15.2 | 12.8 / 14.5 |
| reduced: 0.75 render scale, grain off (AUTO step 2) | n/a | 11.0 / 12.3 |

Film door, cold renderer, simulator: first card 201 ms, all 8 visible-first cards 845 ms, reopening on the same scene 2 ms (memory cache). Before the change the cards took about 15 s on first open (cards were requested in list order from the strip's left edge rather than the visible ones first, went through a 200 ms poll and the 2 Hz gate, waited for a LUT prewarm of every film, and rendered grain, halation and bloom). In the headless app run the cards are on screen about 0.6 s after the door appears.

| Platform | Result |
|---|---|
| iPhone 16 Pro (device) | outstanding: the go/no-go (TESTING.md, camera checklist item 1) |

Reading:
- The full finder grade with native grain, halation and bloom fits a 33 ms (30 fps) frame with room on the Mac (9 to 11 ms) and in the simulator (16 to 18 ms). The plan's guess for an A18 Pro is 2 to 3x the Mac, about 20 to 35 ms: tight. Only the device can say.
- Grain is the stage that matters: grain off saves 20 to 30 %.
- Half-resolution texture does not save time at finder sizes on these GPUs (the reduce and enlarge passes cost about what the smaller blurs and grain save, because `softBlur` already downsamples wide blurs). So AUTO does not use it: the ladder is full, then grain off, then 0.75 render scale with grain off, then 24 fps. Half texture stays as a manual FINDER QUALITY option (Camera settings, ADVANCED) to try on the device.

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

## Round 3 baseline (base 07790d2, 2026-11-05 to 06)

Taken before any Round 3 change, as the reference for the before/after comparison. **Machine:** Apple M1 Pro (`sysctl -n machdep.cpu.brand_string`), 10 cores, macOS (Darwin 27.0.0), Xcode-beta, iOS 27.2 simulators ("Mira QA iOS" / "Mira QA UI", iPhone Duo type; several other simulators were booted). Every command ran through `build/round3/tools/locked.sh`, so no other build or test ran at the same time, but processes started outside the lock (other workers' editors, agents, Spotlight) were not controlled: the load average at the start of each run is in the first line of its raw file (`build/round3/perf/raw/*`), typically 3 to 6; the Mac editor-open runs (15 to 21) and the cold-process warm-up-on runs (about 12 to 21) were taken at a visibly higher load and are likely a little pessimistic. Release builds for the Mac numbers (`-c release -Xswiftc -enable-testing` where the tests need it); iOS simulator numbers are from the Debug app (what `xcodebuild test` builds), through the Mac GPU, so proxies only. The film library now has 264 entries (`UIPerf` prints the count; the thumbnail test uses 51 stocks + Original), so numbers are not comparable one-to-one with the sections above, which were measured with 31 to 82 films. Medians of 3 runs of each command (each run also reports its own median over many frames); machine-readable copy: `build/round3/perf/baseline.json`, raw outputs `build/round3/perf/raw/`, aggregation `build/round3/tools/perf-aggregate.py`.

Reproduce (all through `locked.sh <label> ...`; worktree = the one under test, `Films` and `Fixtures` from it):

| Measure | Command |
|---|---|
| Pipeline bench, 24 MP export, LUT prewarm | `swift build -c release --product mira-sheet --package-path Packages/MiraCore --scratch-path <spm>/MiraCore`, then `<spm>/MiraCore/release/mira-sheet --bench --films Films` (run from the repo root) |
| First frame in a new process | `MIRA_BENCH_COLD=1 MIRA_BENCH_WARMUP=<0\|1> mira-sheet --bench --films Films` |
| Develop slider, film switch, SwiftUI per tick, RAW sliders | `MIRA_PERF=1 MIRA_RAW_DIR=<folder with iphone-12-pro.dng, sony-ilce7m3.arw> swift test -c release -Xswiftc -enable-testing --no-parallel --package-path Packages/MiraUI --filter UIPerf` |
| Film card render / strip thumbnails | `MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --no-parallel --package-path Packages/MiraUI --filter ThumbnailTimingTests` |
| Editor open JPEG / HEIC / DNG / ARW (Mac model level) | `MIRA_PERF=1 MIRA_RAW_DIR=... swift test -c release -Xswiftc -enable-testing --no-parallel --package-path Packages/MiraUI --filter OpenTimingPerf` (new test `OpenTimingPerfTests`, writes `build/perf-open.txt`) |
| Finder, Mac | `MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --no-parallel --package-path Packages/MiraCore --filter FinderBudgetBenchmark` |
| Finder, iOS simulator | `TEST_RUNNER_MIRA_PERF=1 xcodebuild test -scheme MiraiOS -destination id=53F823D9-5CAA-4BFF-9142-891BA0596065 -derivedDataPath <dd>/ios -only-testing:MiraiOSTests/FinderBudgetSimTests CODE_SIGNING_ALLOWED=NO` |
| Editor open, iOS simulator | same with `-only-testing:MiraiOSTests/OpenTimingSimTests` and `TEST_RUNNER_MIRA_PERF=1 TEST_RUNNER_MIRA_RAW_DIR=...` (new `OpenTimingSimTests`) |
| iOS cold launch, gallery first paint and scroll, editor round trip, thumbnail request counter, app memory | `build/round3/tools/perf-ios-ui.sh <worktree> 59B50036-9FDC-4C79-8CCF-B2C94E51CA5A <outdir> <dd>/ios` (new UI test `PerfUITests`, `TEST_RUNNER_MIRA_PERF=1`; plus an os-log stream of the `thumbs` category and a 1 Hz `ps`/`footprint` sampler of the simulator process) |
| Sizes and link maps | `build/round3/tools/perf-size.sh <worktree>` (Release builds with `LD_GENERATE_MAP_FILE=YES` on the command line, `generic/platform=macOS` and `generic/platform=iOS`, `CODE_SIGNING_ALLOWED=NO`; reports from `tools/size-report.sh`, `tools/linkmap-top.py`) |

Memory: for the Mac commands the largest process's maximum resident set from `/usr/bin/time -l`: UIPerf 985 MB (peak memory footprint 211 MB), OpenTimingPerf 823 MB, ThumbnailTimingTests 421 MB, FinderBudgetBenchmark 1.5 GB (the `swift test` build and runner), `mira-sheet --bench` 2.8 to 3.7 GB resident (8.1 GB peak footprint: it holds several 24 MP sources), cold-process runs 239 to 246 MB. The per-file open rows below end with the test process's own peak resident size. For the iOS app: `ps` rss / `footprint` of the simulator process and `XCTMemoryMetric`.

### iOS simulator: launch, gallery, editor, memory (3 runs of `PerfUITests`)

| Measure | Result | How |
|---|---|---|
| Cold launch to first frame (camera screen, fake source, Debug app) | median 3.31 s, p95 3.5 s (18 samples: runs of 3.43 / 3.32 / 3.31 s mean) | `XCTApplicationLaunchMetric` (terminate, launch, first frame); the app has no launch signpost of its own |
| Gallery: tap Library to the grid header | 1.80 to 1.83 s (median of 5 per run; first tap of a run 1.95 s) | wall time in the UI test, includes the UI test's own polling (about 0.1 s) |
| Gallery: tap to the first image | 2.88 to 2.92 s (first tap 3.0 to 3.06 s) | same |
| Gallery scroll: 2 fast swipes up, 2 down | 1.30 / 1.32 / 1.33 s per iteration (rsd 1 to 1.7 %); CPU time 0.88 / 0.90 / 0.90 s; 1.77 to 1.85 G cycles | `XCTOSSignpostMetric.scrollingAndDecelerationMetric`, `XCTCPUMetric`. `XCTHitchMetric` reports nothing on the iOS 27.2 simulator |
| Thumbnail requests (`ThumbnailMetrics`, os log `thumbs`) | 57 requests while the grid settles, then **+0** across editor open, 10 s in the editor, editor close and 8 s after, in all 3 runs | log stream phase markers (`tools/thumbs-phases.py`) |
| App memory | 156 to 164 MB physical during the grid scroll (`XCTMemoryMetric`, constant across iterations); 481 MB footprint with the editor open 10 s (`footprint -p`, all 3 runs) | 1 Hz sampler of the simulator process |
| Camera finder statistics (`MIRA_CAMERA_STATS=1`) | not available headless: the Camera settings readout shows nothing with the fake source in the simulator (and the label is an accessibility label, not readable text) | `PerfUITests.testCameraFinderStats` |

### Mac and simulator tables (median of 3 runs; "median of runs" is the median over the 3 per-run medians)

#### mira-sheet --bench (release)

| Measure | median of 3 runs | min..max | p95 (median of runs) |
|---|---|---|---|
| b. open: ImageSource.load (lazy) | 42.7 ms | 42.4..42.8 | - |
| b. open: first displayable preview (load+first render) | 68.4 ms | 68.0..71.8 | - |
| b. open: full-res source ready (load + first 1:1 read) | 46.3 ms | 46.2..46.5 | - |
| a. preview frame, effects | 14.2 ms | 14.0..14.2 | 15.0 |
| a. preview frame, crop+6deg | 7.2 ms | 7.1..7.6 | 7.8 |
| c. 32 thumbnails, cold LUT cache | 912.0 ms | 814.0..921.0 | - |
| c. 32 thumbnails, warm disk LUT cache | 855.0 ms | 842.0..891.0 | - |
| c. 32 thumbnails, hot (LUTs in memory) | 800.0 ms | 799.0..872.0 | - |
| d. export 24 MP JPEG (effects recipe) | 164.0 ms | 157.0..226.0 | - |
| b. open: ImageIO thumbnail decode | 44.6 ms | 44.1..45.4 | - |
| b. open: first displayable preview (thumb+first render) | 52.3 ms | 51.8..53.9 | - |
| b. open: full-res source decoded | 93.8 ms | 92.9..99.1 | - |
| b. open: first frame from full-res (base build + render) | 21.1 ms | 20.8..23.5 | - |
| a. preview frame 1500x1000, effects | 8.4 ms | 8.0..8.4 | 9.3 |
| a. preview frame 1500x1000, effects+mixer+curves | 6.9 ms | 6.8..6.9 | 7.0 |
| a. preview frame 1500x1000, crop+6deg | 5.7 ms | 4.5..6.4 | 9.2 |
| a. preview frame 2400x1600, effects | 10.2 ms | 10.1..10.4 | 11.2 |
| a. preview frame 2400x1600, effects+mixer+curves | 11.8 ms | 11.8..11.8 | 12.7 |
| a. preview frame 2400x1600, crop+6deg | 9.1 ms | 9.1..9.3 | 9.6 |
| z. zoom 100% effects+mixer+curves, slider drag | 8.2 ms | 8.1..9.5 | 10.9 |
| z. zoom 100% effects+mixer+curves, pan drag | 7.8 ms | 7.7..9.3 | 10.6 |
| z. zoom 100% crop+6deg, slider drag | 5.7 ms | 5.6..6.4 | 6.3 |
| z. zoom 100% crop+6deg, pan drag | 5.8 ms | 5.7..6.2 | 6.4 |
| z. zoom 50% effects+mixer+curves, slider drag | 7.2 ms | 7.0..8.9 | 9.3 |
| z. zoom 50% effects+mixer+curves, pan drag | 7.4 ms | 7.3..10.1 | 10.9 |
| z. zoom 50% crop+6deg, slider drag | 6.1 ms | 5.7..6.5 | 8.4 |
| z. zoom 50% crop+6deg, pan drag | 6.3 ms | 5.9..6.8 | 8.0 |
| z. zoom 200% effects+mixer+curves, slider drag | 8.8 ms | 8.1..10.1 | 10.9 |
| z. zoom 200% effects+mixer+curves, pan drag | 9.6 ms | 9.5..9.8 | 10.6 |
| z. zoom 200% crop+6deg, slider drag | 6.3 ms | 6.2..6.4 | 6.7 |
| z. zoom 200% crop+6deg, pan drag | 6.5 ms | 6.5..6.5 | 7.3 |
| a. crop tool: straighten drag frame | 7.8 ms | 7.7..10.7 | 10.2 |
| a. same frame read back as 8-bit CGImage | 7.6 ms | 7.4..7.7 | 9.6 |
| d. export 24 MP JPEG, decoded CGImage source | 142.0 ms | 130.0..143.0 | - |
| d. export 24 MP JPEG, lazy file-backed source | 125.0 ms | 123.0..147.0 | - |
| h. mask rasterisation, 1 stroke (cold) | 0.8 ms | 0.8..0.8 | 0.8 |
| h. mask rasterisation, 10 strokes (cold) | 7.8 ms | 7.5..7.9 | 8.1 |
| h. mask rasterisation, 50 strokes (cold) | 37.5 ms | 37.4..38.0 | 39.4 |
| h. live stroke update, +1 point on 10 cached (mask only) | 0.9 ms | 0.8..1.0 | 2.4 |
| h. graded frame, effects recipe + no strokes | 16.6 ms | 15.9..16.7 | - |
| h. graded frame, effects recipe + 10 strokes | 16.9 ms | 16.5..17.5 | - |
| h. graded frame, effects recipe + 50 strokes | 17.6 ms | 16.4..19.2 | - |
| h. painting frame (10 cached + live stroke, full graph) | 22.4 ms | 20.4..22.6 | 29.4 |
| e. slider tick, same film (film only + exposure) | 1.8 ms | 1.6..1.9 | - |
| e. film switch, effects recipe, every frame new film | 27.6 ms | 27.0..27.7 | 44.9 |
| e. film switch, film only, every frame new film | 20.6 ms | 20.2..21.1 | 34.9 |
| f. histogram of a 1536x1024 frame | 0.3 ms | 0.3..0.3 | 0.3 |
| g. launch: FilmLibrary init (films.json) | 3.1 ms | 3.0..3.2 | - |
| g. launch: prewarm all LUTs, cold disk cache, 4 workers | 194.0 ms | 193.0..194.0 | - |
| g. launch: prewarm all LUTs, cold disk cache, 10 workers | 93.0 ms | 93.0..108.0 | - |
| g. launch: prewarm all LUTs, warm disk cache, 4 workers | 193.0 ms | 192.0..195.0 | - |
| g. launch: prewarm all LUTs, warm disk cache, 10 workers | 96.0 ms | 91.0..101.0 | - |
| g. launch: first frame on a brand-new CIContext | 127.8 ms | 116.9..221.5 | - |

#### cold process, launch warm-up off (MIRA_BENCH_COLD=1 MIRA_BENCH_WARMUP=0)

| Measure | median of 3 runs | min..max | p95 (median of runs) |
|---|---|---|---|
| first frame | 37.4 ms | 33.2..41.3 | - |
| second frame | 8.7 ms | 8.5..8.9 | - |
| max RSS (value in MB, not ms) | 239.0 ms | 237.1..239.7 | - |

#### cold process, launch warm-up on (MIRA_BENCH_COLD=1 MIRA_BENCH_WARMUP=1)

| Measure | median of 3 runs | min..max | p95 (median of runs) |
|---|---|---|---|
| first frame | 20.1 ms | 18.0..21.0 | - |
| second frame | 8.8 ms | 8.7..9.4 | - |
| max RSS (value in MB, not ms) | 245.0 ms | 240.0..246.0 | - |

#### Finder frame time, Mac (FinderBudgetBenchmark, release)

| Measure | median of 3 runs | min..max | p95 (median of runs) |
|---|---|---|---|
| full 1920x1440 | 8.8 ms | 8.8..9.4 | 11.1 |
| full 1206x1809 | 9.1 ms | 9.0..9.6 | 10.1 |
| grain off 1920x1440 | 5.9 ms | 5.9..6.0 | 6.6 |
| grain off 1206x1809 | 4.8 ms | 4.5..4.9 | 5.4 |
| textureScale 0.5 1920x1440 | 11.0 ms | 10.9..11.3 | 12.0 |
| textureScale 0.5 1206x1809 | 9.0 ms | 8.9..9.2 | 9.5 |
| textureScale 0.5 + grain off 1920x1440 | 4.3 ms | 4.3..4.4 | 4.9 |
| textureScale 0.5 + grain off 1206x1809 | 3.6 ms | 3.6..3.7 | 4.1 |
| renderScale 0.75 1920x1440 | 8.0 ms | 7.4..8.4 | 10.3 |
| renderScale 0.75 1206x1809 | 6.2 ms | 6.1..6.6 | 6.8 |

#### Finder frame time, iOS simulator (FinderBudgetSimTests, Debug app)

| Measure | median of 3 runs | min..max | p95 (median of runs) |
|---|---|---|---|
| full 1920x1440 | 19.2 ms | 19.0..21.1 | 28.0 |
| half texture 1920x1440 | 19.8 ms | 19.7..20.9 | 25.3 |
| grain off 1920x1440 | 15.0 ms | 14.9..18.0 | 21.4 |
| reduced 1920x1440 | 12.6 ms | 12.5..14.8 | 19.2 |

#### UIPerf (Mac model + SwiftUI, release)

| Measure | median of 3 runs | min..max | p95 (median of runs) |
|---|---|---|---|
| slider change -> published preview frame | 12.1 ms | 11.4..12.5 | 15.0 |
| frame -> histogram ready (incl. 20 Hz pacing) | 41.4 ms | 41.3..42.1 | 45.1 |
| film switch -> published preview frame | 29.1 ms | 29.0..29.4 | 45.2 |
| burst of 120 slider changes -> settled | 17.1 ms | 16.5..18.9 | - |
| SwiftUI per slider tick, DEVELOP tab (mutate + layout + displa | 13.5 ms | 13.4..13.6 | 15.2 |
| SwiftUI per slider tick, FILMS tab (mutate + layout + display) | 5.8 ms | 5.8..5.9 | 6.3 |
| thumbnail batch after a crop (to last card) | 64.0 ms | 50.0..167.0 | - |
| RAW: exposure slider -> published frame | 6.4 ms | 6.3..6.9 | 17.5 |
| RAW: white balance slider -> settled frame | 484.4 ms | 480.0..487.6 | 492.2 |

#### Editor open, Mac model level (OpenTimingPerf, release)

| Measure | median of 3 runs | min..max | p95 (median of runs) |
|---|---|---|---|
| JPEG 6000x4000 / returned (cold) | 58.7 ms | 56.6..62.8 | - |
| JPEG 6000x4000 / returned (warm median) | 50.0 ms | 49.6..50.7 | 58.7 |
| JPEG 6000x4000 / first frame (cold) | 104.8 ms | 102.0..106.1 | - |
| JPEG 6000x4000 / first frame (warm median) | 62.1 ms | 61.6..62.3 | 104.8 |
| JPEG 6000x4000 / full source (cold) | 119.5 ms | 116.5..126.9 | - |
| JPEG 6000x4000 / full source (warm median) | 109.5 ms | 109.3..112.0 | 119.5 |
| HEIC 6000x4000 / returned (cold) | 187.0 ms | 176.4..193.9 | - |
| HEIC 6000x4000 / returned (warm median) | 115.5 ms | 112.8..117.6 | 187.0 |
| HEIC 6000x4000 / first frame (cold) | 199.1 ms | 189.6..205.7 | - |
| HEIC 6000x4000 / first frame (warm median) | 127.0 ms | 122.4..129.1 | 199.1 |
| HEIC 6000x4000 / full source (cold) | 339.1 ms | 330.2..348.4 | - |
| HEIC 6000x4000 / full source (warm median) | 267.7 ms | 265.1..270.4 | 339.1 |
| DNG iphone-xs 4032x3024 / returned (cold) | 152.0 ms | 149.2..154.6 | - |
| DNG iphone-xs 4032x3024 / returned (warm median) | 13.5 ms | 13.3..13.6 | 152.0 |
| DNG iphone-xs 4032x3024 / first frame (cold) | 161.1 ms | 158.4..163.8 | - |
| DNG iphone-xs 4032x3024 / first frame (warm median) | 20.5 ms | 19.5..20.6 | 161.1 |
| DNG iphone-xs 4032x3024 / full source (cold) | 376.8 ms | 365.8..469.4 | - |
| DNG iphone-xs 4032x3024 / full source (warm median) | 146.7 ms | 146.6..164.0 | 376.8 |
| DNG iphone-xs 4032x3024 / refined (cold) | 629.1 ms | 619.9..723.5 | - |
| DNG iphone-xs 4032x3024 / refined (warm median) | 399.4 ms | 398.9..416.9 | 629.1 |
| DNG iphone-12-pro / returned (cold) | 53.9 ms | 53.0..59.3 | - |
| DNG iphone-12-pro / returned (warm median) | 53.7 ms | 53.4..54.2 | 56.5 |
| DNG iphone-12-pro / first frame (cold) | 65.8 ms | 64.0..71.0 | - |
| DNG iphone-12-pro / first frame (warm median) | 64.3 ms | 64.0..65.0 | 66.2 |
| DNG iphone-12-pro / full source (cold) | 241.4 ms | 240.6..280.3 | - |
| DNG iphone-12-pro / full source (warm median) | 209.4 ms | 208.5..215.4 | 241.4 |
| DNG iphone-12-pro / refined (cold) | 492.4 ms | 491.0..532.3 | - |
| DNG iphone-12-pro / refined (warm median) | 463.0 ms | 461.3..468.2 | 492.4 |
| ARW sony-a7iii 6000x4000 / returned (cold) | 37.6 ms | 36.4..39.2 | - |
| ARW sony-a7iii 6000x4000 / returned (warm median) | 31.5 ms | 31.3..31.6 | 37.6 |
| ARW sony-a7iii 6000x4000 / first frame (cold) | 49.3 ms | 48.2..51.3 | - |
| ARW sony-a7iii 6000x4000 / first frame (warm median) | 41.1 ms | 40.8..41.4 | 49.3 |
| ARW sony-a7iii 6000x4000 / full source (cold) | 324.0 ms | 324.0..377.5 | - |
| ARW sony-a7iii 6000x4000 / full source (warm median) | 314.0 ms | 312.6..316.4 | 324.0 |
| ARW sony-a7iii 6000x4000 / refined (cold) | 577.9 ms | 577.0..628.6 | - |
| ARW sony-a7iii 6000x4000 / refined (warm median) | 567.1 ms | 564.6..567.7 | 577.9 |

#### Editor open, iOS simulator (OpenTimingSimTests, Debug)

| Measure | median of 3 runs | min..max | p95 (median of runs) |
|---|---|---|---|
| JPEG 6000x4000 / PhotoEngine.load(data:) (cold) | 57.7 ms | 54.5..58.6 | - |
| JPEG 6000x4000 / PhotoEngine.load(data:) (warm median) | 51.2 ms | 50.6..51.5 | 57.7 |
| HEIC 6000x4000 / PhotoEngine.load(data:) (cold) | 186.0 ms | 164.8..188.4 | - |
| HEIC 6000x4000 / PhotoEngine.load(data:) (warm median) | 34.6 ms | 34.0..35.1 | 186.0 |
| DNG iphone-xs 4032x3024 / openDraft (first editable frame) (cold) | 636.4 ms | 587.3..808.0 | - |
| DNG iphone-xs 4032x3024 / openDraft (first editable frame) (warm median) | 245.6 ms | 237.9..248.5 | 636.4 |
| DNG iphone-xs 4032x3024 / refine at preview size, realised (cold) | 135.1 ms | 116.9..215.6 | - |
| DNG iphone-xs 4032x3024 / refine at preview size, realised (warm median) | 125.5 ms | 125.0..144.6 | 144.9 |
| DNG iphone-xs 4032x3024 / full-size develop, realised (Save / zoom) (cold) | 225.4 ms | 201.0..273.2 | - |
| DNG iphone-xs 4032x3024 / full-size develop, realised (Save / zoom) (warm median) | 201.3 ms | 200.3..211.3 | 225.4 |
| DNG iphone-12-pro / openDraft (first editable frame) (cold) | 328.4 ms | 303.1..334.8 | - |
| DNG iphone-12-pro / openDraft (first editable frame) (warm median) | 241.1 ms | 237.3..245.8 | 328.4 |
| DNG iphone-12-pro / refine at preview size, realised (cold) | 99.0 ms | 88.9..116.8 | - |
| DNG iphone-12-pro / refine at preview size, realised (warm median) | 97.2 ms | 88.9..99.2 | 100.1 |
| DNG iphone-12-pro / full-size develop, realised (Save / zoom) (cold) | 133.2 ms | 127.4..188.7 | - |
| DNG iphone-12-pro / full-size develop, realised (Save / zoom) (warm median) | 137.2 ms | 130.3..165.7 | 145.7 |
| ARW sony-a7iii / openDraft (first editable frame) (cold) | 493.9 ms | 474.3..497.2 | - |
| ARW sony-a7iii / openDraft (first editable frame) (warm median) | 422.9 ms | 421.3..426.9 | 493.9 |
| ARW sony-a7iii / refine at preview size, realised (cold) | 168.4 ms | 154.6..175.5 | - |
| ARW sony-a7iii / refine at preview size, realised (warm median) | 147.9 ms | 146.9..159.1 | 168.4 |
| ARW sony-a7iii / full-size develop, realised (Save / zoom) (cold) | 781.4 ms | 747.5..974.5 | - |
| ARW sony-a7iii / full-size develop, realised (Save / zoom) (warm median) | 423.2 ms | 418.5..515.3 | 781.4 |

#### Film strip thumbnails (ThumbnailTimingTests, release; 'before' = every card, no disk cache)

| Measure | median of 3 runs | min..max | p95 (median of runs) |
|---|---|---|---|
| before: every card, no disk cache / first 8 tiles | 75.0 ms | 75.0..75.0 | - |
| before: every card, no disk cache / window settled | 96.0 ms | 94.0..105.0 | - |
| before: every card, no disk cache / all tiles | 96.0 ms | 94.0..105.0 | - |
| after: lazy window + disk cache, cold / first 8 tiles | 49.0 ms | 46.0..50.0 | - |
| after: lazy window + disk cache, cold / window settled | 49.0 ms | 46.0..50.0 | - |
| after: lazy window + disk cache, cold / all tiles | 108.0 ms | 105.0..108.0 | - |
| after: lazy window + disk cache, warm / first 8 tiles | 31.0 ms | 30.0..31.0 | - |
| after: lazy window + disk cache, warm / window settled | 31.0 ms | 30.0..31.0 | - |
| after: lazy window + disk cache, warm / all tiles | 46.0 ms | 46.0..47.0 | - |

### Binary and resource sizes (Release, no signing; `build/round3/perf/raw/size-mac.txt`, `size-ios.txt`, `linkmaps/`, `top20-*.txt`)

| Item | Mac app (universal x86_64 + arm64) | iOS app (arm64 device) |
|---|---|---|
| Bundle total (sum of file sizes) | 304,027,779 B (291 MB on disk) | 144,856,827 B (139 MB on disk) |
| Main executable | `Mira` 19,648,936 B | `Mira` 10,023,600 B |
| Photos extension executable | `MiraPhotos` 13,932,296 B (inside `PlugIns/MiraPhotos.appex`, which is 145,880 KB) | none |
| Film LUT packs (`Films/Packed/*.mlut`, 260 files) | 129,168 KB in the app and again 129,168 KB in the extension | 129,168 KB |
| `films.json` | 157,207 B, twice | 157,207 B |
| Asset catalog `Assets.car` | 133,208 B (app), 134,760 B (extension) | 62,328 B |
| Kernels (`Grade.ci.metallib`, `.iossim.metallib`, `.ios.metallib`) | 52,199 / 52,182 / 52,166 B in each of app and extension; the Mac needs only the first | the same three files (the iOS device needs only `.ios`) |
| Fonts (MiraUI bundle) | 2,324 KB in the app, again in the extension (Cormorant VF 1,195,560 B, italic VF 715,644 B, IBM Plex Mono x3) | 2,300 KB |
| Frameworks | none (all packages are linked statically) | none |

Duplicated content (same sha256) inside the Mac bundle: 271 file groups, 269 of them app + extension pairs, **135,480,587 bytes** of extra copies, of which 132,789,520 B are the Films packs, and 1.2 MB the fonts; the list with shas is in `size-mac.txt`. The two Mac Assets.car files differ (different icon sets), so they are not counted.

Link maps (`LD_GENERATE_MAP_FILE=YES`; the symbol sizes the linker lists add up to 3.6 MB of the 19.6 MB / 10.0 MB executables, the rest being strings, metadata, unwind and Swift reflection that the map does not attribute per symbol). Packages are linked as one object each, so the contribution per target:

| Target (arm64 slice) | Mac `Mira` | Mac `MiraPhotos` | iOS `Mira` |
|---|---|---|---|
| MiraUI | 1,319,474 B (36.2 %) | 1,325,379 B (50.3 %) | 168,491 B (4.7 %) |
| MiraCore | 1,202,774 B (33.0 %) | 1,214,693 B (46.1 %) | 1,182,099 B (32.7 %) |
| App sources (`Mira.build` / `MiraPhotos.build` / `MiraiOS.build`) | 916,504 B (25.2 %) | 21,651 B (0.8 %) | 1,473,657 B (40.8 %) |
| MiraUpdates | 100,750 B (2.8 %) | none | none |
| MiraCamera + MiraCameraKit | none | none | 534,238 + 141,581 B (14.8 % + 3.9 %) |
| linker synthesized | 69,256 B | 49,985 B | 81,022 B |

Top 20 object files per executable (the app's own sources appear per file, the packages as one object each) are in `build/round3/perf/raw/top20-*.txt`; the full maps are in `build/round3/perf/raw/linkmaps/`.

What the sizes say, for later rounds (observations, nothing was changed): the Films packs are 89 % of the iOS bundle and, on the Mac, are shipped twice (app and extension, 129 MB each); the Mac app also carries the iOS and simulator kernel libraries (104 KB each in app and extension, unused on the Mac).

### Notes on this baseline

- `UIPerf` "SwiftUI per slider tick, DEVELOP tab" (mutate + layout + display) is the known 13 ms item: 13.5 ms median (13.4 to 13.6) here, p95 15.2 ms. The FILMS tab tick is 5.8 ms and the film strip evaluates 0 times per tick on both. This is where the Mac Develop slider's UI cost is measured (`UIPerfTests.sliderAndFilmTiming`, the `NSHostingView` loop).
- Camera finder, simulator vs Mac: full grade 19.2 ms median in the simulator against 8.8 ms on the Mac GPU (1920x1440); the plan's 30 fps gate (33 ms) is still an outstanding device measurement.
- `OpenTimingPerf` first-frame rows: the DNG "returned" cold value (152 ms) is the embedded-preview stand-in decode; warm it is 13.5 ms because the proxy and develop caches are in memory. The iPhone 12 Pro and Sony files come from `MIRA_RAW_DIR` (they are git-ignored, so other worktrees skip them unless the variable is set). The iPhone XS DNG is the committed fixture; none of the available files is an Apple ProRAW, so the iPhone 12 Pro DNG (8-bit linear) is the closest stand-in.
- Not measured: Mac app cold launch (a window would appear on screen; `MIRA_BENCH_COLD` above is the headless proxy for the first frame), a real device, thermal behaviour.

## Round 3 result (round3/quality 809a5a4 against the baseline above)

Every measurement of "Round 3 baseline" was repeated with the same commands and scripts (`build/round3/tools/perf-mac2.sh`, `perf-ios.sh`, `perf-ios-ui.sh`, `perf-size.sh`; only the output folder differs, `RAW_DIR`) on a fresh worktree of `round3/quality` at 809a5a4, on the same Apple M1 Pro, one locked command at a time, 3 runs each, 2026-11-06 05:03 to 05:32. Raw outputs: `build/round3/perf/raw-result/` (baseline: `perf/raw/`); machine-readable: `build/round3/perf/result.json`; comparison script `build/round3/tools/perf-compare.py`. Load average at the start of each block (first number of `uptime`), baseline then result: sheet 3 to 6 / 4 to 13, cold process warm-up off 7 to 10 / 4.7, warm-up on 16 to 21 / 4.4, UIPerf 3 to 8 / 3 to 4, Mac editor open 10 to 15 / 4, thumbnails 7 to 10 / 4, Mac finder 4.5 to 6.6 / 3.2 to 4.4, simulator finder 4.6 to 5.4 / 4.8 to 9.9, simulator open 4 to 7 / 10 to 12.6. The baseline rows taken at a high load (warm-up on, Mac editor open) were therefore pessimistic; some of their improvement below is load, not code. The residual load of about 4 on a quiet Mac is the booted simulators.

**Noise and the flagging rule.** The run-to-run range (max minus min over the 3 runs, as a share of the median) has a median of 6 % over all rows and a 90th percentile of 31 %; single-digit-millisecond rows, first-run (cold) rows and anything touching Photos decoders or the GPU scheduler are the noisy ones. A row is flagged REGRESSED only when the result median is more than 10 % above the baseline median AND the result's fastest run is slower than the baseline's slowest run (the run ranges do not overlap); "faster" is the mirror image. Everything else with a change above 10 % is noise by this rule.

### Summary

- **Faster:** the Mac Develop slider's SwiftUI cost per tick 13.5 to 2.0 ms (-85 %) and the FILMS-tab tick 5.8 to 1.5 ms (-73 %); thumbnail refill after a crop 64 to 39 ms (-39 %, noisy); LUT prewarm 11 to 16 % faster in all four configurations; 24 MP export from a decoded source 142 to 123 ms (-13 %); film switch, film only 20.6 to 17.9 ms (-13 %); iOS simulator RAW open (first editable frame, cold) -13 to -20 % and the cold full-size develop of the Sony ARW -32 %; the cold-process bench process uses 8 % less memory (240 to 222 MB).
- **Release binaries are much smaller** (area h strips them): Mac `Mira` 19.6 to 8.35 MB (-57 %), `MiraPhotos` 13.9 to 5.99 MB (-57 %), Mac bundle 304.0 to 284.8 MB (-6.3 %); iOS `Mira` 10.0 to 4.05 MB (-60 %), iOS bundle 144.9 to 138.9 MB (-4.1 %). The Films packs (129,372 KB each, still shipped twice in the Mac app) are unchanged, so they are now 95 % of the iOS bundle (91 % before; the baseline section's 89 % divided kilobytes by megabytes).
- **Unchanged within noise:** every Mac finder row, preview frame times, slider and RAW slider latency, JPEG, DNG and ARW opens on the Mac, iOS cold launch (3.3 s), gallery first paint (1.82 s to the grid header, 2.92 s to the first image) and scroll, memory (156 to 164 MB during the scroll, about 475 MB with the editor open), and the thumbnail request counter (57 while the grid settles, +0 after the editor opens and closes).
- **Second Core Image context for RAW (area a):** the cold-process first frame, which is where a second context would show, is 33.7 ms with the launch warm-up off against 37.4 ms before (-10 %, inside the run range 33.2 to 41.3), and 20.3 ms with it on against 20.1 ms (+1 %). RAW opens on the Mac (DNG 154.6 ms first frame cold against 161.1) and the RAW slider latency (6.5 against 6.4 ms exposure, 481 against 484 ms white balance) show no regression either.

### Regressions and rows to watch

- **`g. launch: FilmLibrary init (films.json)`, 3.1 to 3.6 ms (+16 %)** is the only row that meets the rule (ranges 3.0 to 3.2 against 3.3 to 4.2). It is half a millisecond, once per launch, and `films.json` is byte for byte the same size (157,207 B) in both bundles, so the cost is in the loading code (area b changed the LUT code), not the data. In a second A/B run of the two binaries alternated back to back the values were 3.1, 4.2 and 17.3 ms (one cold outlier) against 3.3, 3.3, 3.2 ms for the baseline commit, which is consistent with a small real increase of 0.3 to 1 ms. Not isolated further.
- **`h.` dodge & burn graded and painting frame, 16 to 450 ms:** in this block the result shows about 450 ms per frame (p95 about 480 ms) for the effects-recipe graded frame (even with no strokes) in 2 of 3 runs. This is **not a code regression**: an alternating A/B of the baseline binary and the result binary (3 runs each, same session) gave the slow mode in 2 of 3 runs of the baseline commit (448, 23, 455 ms) and 2 of 3 runs of the result (17, 451, 449 ms). The bench process lands in a fast (16 to 23 ms) or a slow (about 450 ms) mode per launch, independent of the commit; the baseline numbers above happened to be 3 of 3 fast. It looks like a Core Image / Metal state that persists for the life of the process after an earlier bench section (the earlier sections, including the plain preview frames, are unaffected). Worth its own investigation: if it can also happen in the app, a painting frame would take 28 times its budget. A/B raw files: `build/round3/perf/raw-result/ab/`.
  **Resolved (bench only, no app effect):** section h built its source with the lazy `ImageSource.load(url:)` (`CIImage(contentsOf:)` over the 24 MP JPEG), and in the slow launches Core Image re-decoded the whole JPEG through CMPhoto/AppleJPEG on every frame (`sample`: `CI::SurfaceCacheEntry::fillAsync` -> `applejpeg_decode_image_all`; `createCGImage` 450 ms, graph build 0.2 ms, masks 0.8 ms). The editors never render a lazy file per frame (`PreviewEngine` materialises its bases once); in the same slow-state process a `PreviewEngine` painting drag ran 19 to 21 ms median from a lazy source. The bench now uses `ImageSource.loadDecoded` for these rows: 6 of 6 launches graded 12.8 to 14.2 ms, painting median 14.8 to 22.3 ms. Why some earlier sections make the surface cache drop the decoded JPEG is not known. `MIRA_BENCH_ONLY=l|c|h|e` runs parts of the bench.
- **Mac HEIC open** (returned, first frame, full source: +4 to +13 % medians, run ranges overlap) and **simulator finder** (grain off +9 %, reduced +8 %, overlapping ranges) are inside the noise by the rule; watch them in the next run.

### Binary and resource sizes (Release, no signing; `size-mac.txt`, `size-ios.txt`, `linkmaps/`, `top20-*.txt` in `raw-result/`)

| Item | Baseline | Result | Change |
|---|---|---|---|
| Mac bundle, sum of file sizes | 304,027,779 B | 284,785,011 B | -6.3 % |
| Mac `Mira` (x86_64 + arm64) | 19,648,936 B | 8,350,760 B | -57.5 % |
| Mac `MiraPhotos` (x86_64 + arm64) | 13,932,296 B | 5,987,704 B | -57.0 % |
| iOS bundle, sum of file sizes | 144,856,827 B | 138,879,331 B | -4.1 % |
| iOS `Mira` (arm64) | 10,023,600 B | 4,046,104 B | -59.6 % |
| Films packs, each copy (Mac app, Mac extension, iOS) | 129,372 KB | 129,372 KB | 0 % |
| Duplicated content inside the Mac bundle (app + extension) | 135,480,587 B in 271 groups | 135,480,587 B in 271 groups | 0 % |
| Mac `Assets.car` (app / extension), iOS `Assets.car` | 133,208 / 134,760 / 62,328 B | 133,208 / 134,760 / 62,328 B | 0 % |
| Link-map symbol total, Mac `Mira` arm64 / `MiraPhotos` / iOS `Mira` | 3,640,501 / 2,636,880 / 3,612,507 B | 3,670,321 / 2,659,262 / 3,668,268 B | +0.8 % / +0.8 % / +1.5 % |
| Release build wall time, Mac / iOS | 59.9 s / 43.2 s | 59.5 s / 41.9 s | -0.7 % / -3.0 % |

The link-map symbol totals are unchanged (the linked code is the same size to within 1.5 %); the executables shrank because stripping removed their symbol and debug tables. Contribution per target in the iOS and Mac maps is the same as in the baseline table (MiraUI, MiraCore, app sources, MiraUpdates, MiraCamera).

### Row by row (baseline against result; medians of 3 runs; change = (result - baseline) / baseline; units as in the baseline tables)

#### mira-sheet --bench (release)

| Measure | Baseline | Result | Change | Note |
|---|---|---|---|---|
| b. open: ImageSource.load (lazy) | 42.7 ms | 50.2 ms | +18 % |  |
| b. open: first displayable preview (load+first render) | 68.4 ms | 76.9 ms | +12 % |  |
| b. open: full-res source ready (load + first 1:1 read) | 46.3 ms | 52.4 ms | +13 % |  |
| a. preview frame, effects | 14.2 ms | 14.3 ms | +1 % |  |
| a. preview frame, crop+6deg | 7.2 ms | 7.2 ms | +0 % |  |
| c. 32 thumbnails, cold LUT cache | 912.0 ms | 961.0 ms | +5 % |  |
| c. 32 thumbnails, warm disk LUT cache | 855.0 ms | 815.0 ms | -5 % |  |
| c. 32 thumbnails, hot (LUTs in memory) | 800.0 ms | 801.0 ms | +0 % |  |
| d. export 24 MP JPEG (effects recipe) | 164.0 ms | 173.0 ms | +5 % |  |
| b. open: ImageIO thumbnail decode | 44.6 ms | 49.6 ms | +11 % |  |
| b. open: first displayable preview (thumb+first render) | 52.3 ms | 57.7 ms | +10 % |  |
| b. open: full-res source decoded | 93.8 ms | 90.7 ms | -3 % |  |
| b. open: first frame from full-res (base build + render) | 21.1 ms | 18.2 ms | -14 % |  |
| a. preview frame 1500x1000, effects | 8.4 ms | 8.2 ms | -2 % |  |
| a. preview frame 1500x1000, effects+mixer+curves | 6.9 ms | 7.6 ms | +10 % |  |
| a. preview frame 1500x1000, crop+6deg | 5.7 ms | 4.5 ms | -21 % |  |
| a. preview frame 2400x1600, effects | 10.2 ms | 10.3 ms | +1 % |  |
| a. preview frame 2400x1600, effects+mixer+curves | 11.8 ms | 11.8 ms | +0 % |  |
| a. preview frame 2400x1600, crop+6deg | 9.1 ms | 9.1 ms | +0 % |  |
| z. zoom 100% effects+mixer+curves, slider drag | 8.2 ms | 8.0 ms | -2 % |  |
| z. zoom 100% effects+mixer+curves, pan drag | 7.8 ms | 7.6 ms | -3 % |  |
| z. zoom 100% crop+6deg, slider drag | 5.7 ms | 5.8 ms | +2 % |  |
| z. zoom 100% crop+6deg, pan drag | 5.8 ms | 5.8 ms | +0 % |  |
| z. zoom 50% effects+mixer+curves, slider drag | 7.2 ms | 7.6 ms | +6 % |  |
| z. zoom 50% effects+mixer+curves, pan drag | 7.4 ms | 7.1 ms | -4 % |  |
| z. zoom 50% crop+6deg, slider drag | 6.1 ms | 5.6 ms | -8 % |  |
| z. zoom 50% crop+6deg, pan drag | 6.3 ms | 6.0 ms | -5 % |  |
| z. zoom 200% effects+mixer+curves, slider drag | 8.8 ms | 7.9 ms | -10 % |  |
| z. zoom 200% effects+mixer+curves, pan drag | 9.6 ms | 8.0 ms | -17 % |  |
| z. zoom 200% crop+6deg, slider drag | 6.3 ms | 7.4 ms | +17 % |  |
| z. zoom 200% crop+6deg, pan drag | 6.5 ms | 7.8 ms | +20 % |  |
| a. crop tool: straighten drag frame | 7.8 ms | 9.1 ms | +17 % |  |
| a. same frame read back as 8-bit CGImage | 7.6 ms | 9.0 ms | +18 % |  |
| d. export 24 MP JPEG, decoded CGImage source | 142.0 ms | 123.0 ms | -13 % | faster |
| d. export 24 MP JPEG, lazy file-backed source | 125.0 ms | 151.0 ms | +21 % |  |
| h. mask rasterisation, 1 stroke (cold) | 0.8 ms | 0.8 ms | -3 % |  |
| h. mask rasterisation, 10 strokes (cold) | 7.8 ms | 7.7 ms | -2 % |  |
| h. mask rasterisation, 50 strokes (cold) | 37.5 ms | 38.3 ms | +2 % |  |
| h. live stroke update, +1 point on 10 cached (mask only) | 0.9 ms | 0.8 ms | -6 % |  |
| h. graded frame, effects recipe + no strokes | 16.6 ms | 449.1 ms | +2605 % | bimodal, see text (not a code regression) |
| h. graded frame, effects recipe + 10 strokes | 16.9 ms | 449.9 ms | +2562 % | bimodal, see text (not a code regression) |
| h. graded frame, effects recipe + 50 strokes | 17.6 ms | 449.2 ms | +2452 % | bimodal, see text (not a code regression) |
| h. painting frame (10 cached + live stroke, full graph) | 22.4 ms | 451.5 ms | +1916 % | bimodal, see text (not a code regression) |
| e. slider tick, same film (film only + exposure) | 1.8 ms | 2.0 ms | +11 % |  |
| e. film switch, effects recipe, every frame new film | 27.6 ms | 25.6 ms | -7 % |  |
| e. film switch, film only, every frame new film | 20.6 ms | 17.9 ms | -13 % | faster |
| f. histogram of a 1536x1024 frame | 0.3 ms | 0.3 ms | -3 % |  |
| g. launch: FilmLibrary init (films.json) | 3.1 ms | 3.6 ms | +16 % | REGRESSED |
| g. launch: prewarm all LUTs, cold disk cache, 4 workers | 194.0 ms | 169.0 ms | -13 % | faster |
| g. launch: prewarm all LUTs, cold disk cache, 10 workers | 93.0 ms | 83.0 ms | -11 % |  |
| g. launch: prewarm all LUTs, warm disk cache, 4 workers | 193.0 ms | 169.0 ms | -12 % | faster |
| g. launch: prewarm all LUTs, warm disk cache, 10 workers | 96.0 ms | 81.0 ms | -16 % |  |
| g. launch: first frame on a brand-new CIContext | 127.8 ms | 147.9 ms | +16 % |  |

#### cold process, launch warm-up off (MIRA_BENCH_COLD=1 MIRA_BENCH_WARMUP=0)

| Measure | Baseline | Result | Change | Note |
|---|---|---|---|---|
| first frame | 37.4 ms | 33.7 ms | -10 % |  |
| second frame | 8.7 ms | 8.9 ms | +2 % |  |
| max RSS (value in MB, not ms) | 239.0 ms | 221.6 ms | -7 % |  |

#### cold process, launch warm-up on (MIRA_BENCH_COLD=1 MIRA_BENCH_WARMUP=1)

| Measure | Baseline | Result | Change | Note |
|---|---|---|---|---|
| first frame | 20.1 ms | 20.3 ms | +1 % |  |
| second frame | 8.8 ms | 8.8 ms | +0 % |  |
| max RSS (value in MB, not ms) | 245.0 ms | 224.4 ms | -8 % |  |

#### Finder frame time, Mac (FinderBudgetBenchmark, release)

| Measure | Baseline | Result | Change | Note |
|---|---|---|---|---|
| full 1920x1440 | 8.8 ms | 8.9 ms | +1 % |  |
| full 1206x1809 | 9.1 ms | 8.9 ms | -2 % |  |
| grain off 1920x1440 | 5.9 ms | 5.9 ms | +0 % |  |
| grain off 1206x1809 | 4.8 ms | 4.6 ms | -4 % |  |
| textureScale 0.5 1920x1440 | 11.0 ms | 11.0 ms | +0 % |  |
| textureScale 0.5 1206x1809 | 9.0 ms | 8.9 ms | -1 % |  |
| textureScale 0.5 + grain off 1920x1440 | 4.3 ms | 4.2 ms | -2 % |  |
| textureScale 0.5 + grain off 1206x1809 | 3.6 ms | 3.6 ms | +0 % |  |
| renderScale 0.75 1920x1440 | 8.0 ms | 7.4 ms | -7 % |  |
| renderScale 0.75 1206x1809 | 6.2 ms | 6.5 ms | +5 % |  |

#### Finder frame time, iOS simulator (FinderBudgetSimTests, Debug app)

| Measure | Baseline | Result | Change | Note |
|---|---|---|---|---|
| full 1920x1440 | 19.2 ms | 19.8 ms | +3 % |  |
| half texture 1920x1440 | 19.8 ms | 20.0 ms | +1 % |  |
| grain off 1920x1440 | 15.0 ms | 16.3 ms | +9 % |  |
| reduced 1920x1440 | 12.6 ms | 13.6 ms | +8 % |  |

#### UIPerf (Mac model + SwiftUI, release)

| Measure | Baseline | Result | Change | Note |
|---|---|---|---|---|
| slider change -> published preview frame | 12.1 ms | 12.0 ms | -1 % |  |
| frame -> histogram ready (incl. 20 Hz pacing) | 41.4 ms | 41.4 ms | +0 % |  |
| film switch -> published preview frame | 29.1 ms | 27.2 ms | -7 % |  |
| burst of 120 slider changes -> settled | 17.1 ms | 17.8 ms | +4 % |  |
| SwiftUI per slider tick, DEVELOP tab (mutate + layout + displa | 13.5 ms | 2.0 ms | -85 % | faster |
| SwiftUI per slider tick, FILMS tab (mutate + layout + display) | 5.8 ms | 1.5 ms | -73 % | faster |
| thumbnail batch after a crop (to last card) | 64.0 ms | 39.0 ms | -39 % |  |
| RAW: exposure slider -> published frame | 6.4 ms | 6.5 ms | +2 % |  |
| RAW: white balance slider -> settled frame | 484.4 ms | 481.1 ms | -1 % |  |

#### Editor open, Mac model level (OpenTimingPerf, release)

| Measure | Baseline | Result | Change | Note |
|---|---|---|---|---|
| JPEG 6000x4000 / returned (cold) | 58.7 ms | 59.9 ms | +2 % |  |
| JPEG 6000x4000 / returned (warm median) | 50.0 ms | 49.3 ms | -1 % |  |
| JPEG 6000x4000 / first frame (cold) | 104.8 ms | 103.5 ms | -1 % |  |
| JPEG 6000x4000 / first frame (warm median) | 62.1 ms | 60.9 ms | -2 % |  |
| JPEG 6000x4000 / full source (cold) | 119.5 ms | 120.1 ms | +1 % |  |
| JPEG 6000x4000 / full source (warm median) | 109.5 ms | 108.5 ms | -1 % |  |
| HEIC 6000x4000 / returned (cold) | 187.0 ms | 211.8 ms | +13 % |  |
| HEIC 6000x4000 / returned (warm median) | 115.5 ms | 122.9 ms | +6 % |  |
| HEIC 6000x4000 / first frame (cold) | 199.1 ms | 222.2 ms | +12 % |  |
| HEIC 6000x4000 / first frame (warm median) | 127.0 ms | 134.2 ms | +6 % |  |
| HEIC 6000x4000 / full source (cold) | 339.1 ms | 360.8 ms | +6 % |  |
| HEIC 6000x4000 / full source (warm median) | 267.7 ms | 278.0 ms | +4 % |  |
| DNG iphone-xs 4032x3024 / returned (cold) | 152.0 ms | 145.5 ms | -4 % |  |
| DNG iphone-xs 4032x3024 / returned (warm median) | 13.5 ms | 13.7 ms | +1 % |  |
| DNG iphone-xs 4032x3024 / first frame (cold) | 161.1 ms | 154.6 ms | -4 % |  |
| DNG iphone-xs 4032x3024 / first frame (warm median) | 20.5 ms | 19.3 ms | -6 % |  |
| DNG iphone-xs 4032x3024 / full source (cold) | 376.8 ms | 355.7 ms | -6 % |  |
| DNG iphone-xs 4032x3024 / full source (warm median) | 146.7 ms | 148.6 ms | +1 % |  |
| DNG iphone-xs 4032x3024 / refined (cold) | 629.1 ms | 608.2 ms | -3 % |  |
| DNG iphone-xs 4032x3024 / refined (warm median) | 399.4 ms | 402.1 ms | +1 % |  |
| DNG iphone-12-pro / returned (cold) | 53.9 ms | 53.0 ms | -2 % |  |
| DNG iphone-12-pro / returned (warm median) | 53.7 ms | 53.4 ms | -1 % |  |
| DNG iphone-12-pro / first frame (cold) | 65.8 ms | 63.2 ms | -4 % |  |
| DNG iphone-12-pro / first frame (warm median) | 64.3 ms | 63.0 ms | -2 % |  |
| DNG iphone-12-pro / full source (cold) | 241.4 ms | 236.8 ms | -2 % |  |
| DNG iphone-12-pro / full source (warm median) | 209.4 ms | 205.1 ms | -2 % |  |
| DNG iphone-12-pro / refined (cold) | 492.4 ms | 487.9 ms | -1 % |  |
| DNG iphone-12-pro / refined (warm median) | 463.0 ms | 458.6 ms | -1 % |  |
| ARW sony-a7iii 6000x4000 / returned (cold) | 37.6 ms | 36.9 ms | -2 % |  |
| ARW sony-a7iii 6000x4000 / returned (warm median) | 31.5 ms | 31.1 ms | -1 % |  |
| ARW sony-a7iii 6000x4000 / first frame (cold) | 49.3 ms | 47.3 ms | -4 % |  |
| ARW sony-a7iii 6000x4000 / first frame (warm median) | 41.1 ms | 40.4 ms | -2 % |  |
| ARW sony-a7iii 6000x4000 / full source (cold) | 324.0 ms | 319.2 ms | -1 % |  |
| ARW sony-a7iii 6000x4000 / full source (warm median) | 314.0 ms | 304.7 ms | -3 % |  |
| ARW sony-a7iii 6000x4000 / refined (cold) | 577.9 ms | 570.6 ms | -1 % |  |
| ARW sony-a7iii 6000x4000 / refined (warm median) | 567.1 ms | 557.6 ms | -2 % |  |

#### Editor open, iOS simulator (OpenTimingSimTests, Debug)

| Measure | Baseline | Result | Change | Note |
|---|---|---|---|---|
| JPEG 6000x4000 / PhotoEngine.load(data:) (cold) | 57.7 ms | 51.4 ms | -11 % | faster |
| JPEG 6000x4000 / PhotoEngine.load(data:) (warm median) | 51.2 ms | 48.7 ms | -5 % |  |
| HEIC 6000x4000 / PhotoEngine.load(data:) (cold) | 186.0 ms | 148.1 ms | -20 % | faster |
| HEIC 6000x4000 / PhotoEngine.load(data:) (warm median) | 34.6 ms | 33.5 ms | -3 % |  |
| DNG iphone-xs 4032x3024 / openDraft (first editable frame) (cold) | 636.4 ms | 506.1 ms | -20 % |  |
| DNG iphone-xs 4032x3024 / openDraft (first editable frame) (warm median) | 245.6 ms | 227.1 ms | -8 % |  |
| DNG iphone-xs 4032x3024 / refine at preview size, realised (cold) | 135.1 ms | 141.5 ms | +5 % |  |
| DNG iphone-xs 4032x3024 / refine at preview size, realised (warm median) | 125.5 ms | 127.5 ms | +2 % |  |
| DNG iphone-xs 4032x3024 / full-size develop, realised (Save / zoom) (cold) | 225.4 ms | 195.0 ms | -13 % |  |
| DNG iphone-xs 4032x3024 / full-size develop, realised (Save / zoom) (warm median) | 201.3 ms | 191.2 ms | -5 % |  |
| DNG iphone-12-pro / openDraft (first editable frame) (cold) | 328.4 ms | 267.5 ms | -19 % |  |
| DNG iphone-12-pro / openDraft (first editable frame) (warm median) | 241.1 ms | 238.5 ms | -1 % |  |
| DNG iphone-12-pro / refine at preview size, realised (cold) | 99.0 ms | 98.0 ms | -1 % |  |
| DNG iphone-12-pro / refine at preview size, realised (warm median) | 97.2 ms | 97.6 ms | +0 % |  |
| DNG iphone-12-pro / full-size develop, realised (Save / zoom) (cold) | 133.2 ms | 131.1 ms | -2 % |  |
| DNG iphone-12-pro / full-size develop, realised (Save / zoom) (warm median) | 137.2 ms | 130.2 ms | -5 % |  |
| ARW sony-a7iii / openDraft (first editable frame) (cold) | 493.9 ms | 431.8 ms | -13 % |  |
| ARW sony-a7iii / openDraft (first editable frame) (warm median) | 422.9 ms | 426.4 ms | +1 % |  |
| ARW sony-a7iii / refine at preview size, realised (cold) | 168.4 ms | 147.7 ms | -12 % |  |
| ARW sony-a7iii / refine at preview size, realised (warm median) | 147.9 ms | 148.7 ms | +1 % |  |
| ARW sony-a7iii / full-size develop, realised (Save / zoom) (cold) | 781.4 ms | 531.8 ms | -32 % | faster |
| ARW sony-a7iii / full-size develop, realised (Save / zoom) (warm median) | 423.2 ms | 427.0 ms | +1 % |  |

#### Film strip thumbnails (ThumbnailTimingTests, release; 'before' = every card, no disk cache)

| Measure | Baseline | Result | Change | Note |
|---|---|---|---|---|
| before: every card, no disk cache / first 8 tiles | 75.0 ms | 76.0 ms | +1 % |  |
| before: every card, no disk cache / window settled | 96.0 ms | 89.0 ms | -7 % |  |
| before: every card, no disk cache / all tiles | 96.0 ms | 89.0 ms | -7 % |  |
| after: lazy window + disk cache, cold / first 8 tiles | 49.0 ms | 45.0 ms | -8 % |  |
| after: lazy window + disk cache, cold / window settled | 49.0 ms | 45.0 ms | -8 % |  |
| after: lazy window + disk cache, cold / all tiles | 108.0 ms | 104.0 ms | -4 % |  |
| after: lazy window + disk cache, warm / first 8 tiles | 31.0 ms | 30.0 ms | -3 % |  |
| after: lazy window + disk cache, warm / window settled | 31.0 ms | 30.0 ms | -3 % |  |
| after: lazy window + disk cache, warm / all tiles | 46.0 ms | 46.0 ms | +0 % |  |

#### iOS simulator UI perf (PerfUITests)

| Measure | Baseline | Result | Change | Note |
|---|---|---|---|---|
| cold launch (s, per-iteration median of runs) | 3.3 s | 3.3 s | -0 % |  |
| gallery: tap -> grid header (ms) | 1808.0 ms | 1824.0 ms | +1 % |  |
| gallery: tap -> first image (ms) | 2903.0 ms | 2917.0 ms | +0 % |  |
| gallery scroll (s per iteration) | 1.3 s | 1.3 s | -0 % |  |
| gallery scroll CPU time (s) | 0.9 s | 0.9 s | +2 % |  |
| app memory, grid scroll (MB) | 153.0 MB | 162.3 MB | +6 % |  |
| app footprint, editor open (MB) | 481.0 MB | 474.0 MB | -1 % |  |
| thumbnail requests while grid settles | 57.0  | 57.0  | +0 % |  |
| thumbnail requests after editor opened/closed | 0.0  | 0.0  | +0 % |  |

iOS simulator rows use the Debug app, Mac rows Release, as in the baseline. Not measured again (as in the baseline): Mac app cold launch, a real device.

## iPhone library: open, scroll, changes (fix/library-three, 2026-11-06)

What was measured: the iPhone gallery root (the album list) against a large library, before and after.
The question was whether a big library blocks the main thread or leaves the first screen blank.

**Machine and simulator.** Apple M1 Pro, macOS 27.0, Xcode beta, Debug app. "Mira QA Library" (iOS 27.2), a dedicated
perf simulator. Other workers shared the machine, but every run went through the machine-wide lock, so no other
build or simulator run overlapped.

**Seeded library (exact).** 10,024 pictures: 5,000 generated 320 px JPEGs (`tools/make-seed-jpegs.swift`, varied
gradients and shapes, EXIF dates spread over about 6 years) added twice by two `simctl addmedia` runs (the first run
was not noticed when the second started), plus the simulator's 24 original pictures. 154 albums (150 seeded by
`iOSTests/LibrarySeedTool.swift` plus 4 that were already there) in 87 top-level collections: 7 folders (Trips with a
nested Trips 2019, Projects, Family, Archive with Archive 2018 and Archive 2018 Q4), 3 albums of 1,000 to 2,000
pictures (2,000 / 1,500 / 1,000), 12 of 150 to 500, 6 empty ones, the rest 3 to 60 pictures.
**Not measurable here:** an iCloud Shared Library and shared albums cannot be created on a simulator, so the shared
albums fetch (and the SHARED / PERSONAL scopes against real shared content) was not measured; the SHARED ALBUMS section
was empty in every run. Its cost on a device is one `fetchAssetCollections(.albumCloudShared)` plus one count per shared
album, fetched lazily like the user albums now.

**Method.** `iOSTests/GalleryRootPerfProbe.swift` hosts the real `GalleryView` (the model is injectable) in a window and
prints one `GALLERYROOT` line; `iOSTests/GalleryPerfProbe.swift` (existing, album grid of node "all") prints
`GALLERYPROBE`. Both are opt-in and read the same env var. Commands, through the machine lock, one process per run:

```
TEST_RUNNER_MIRA_GALLERY_PROBE=1 xcodebuild test-without-building -scheme MiraiOS \
  -destination id=7D29270C-F9F9-4F96-AD54-91732EC0F108 -derivedDataPath build/dd \
  -only-testing:MiraiOSTests/GalleryRootPerfProbe        # and /GalleryPerfProbe
```

Seeding: `build/seed/gen build/seed/jpgs 5000` (from `tools/make-seed-jpegs.swift`), `xcrun simctl addmedia` in
batches of 500, Photos granted to the app and the test bundle, then
`TEST_RUNNER_MIRA_SEED_LIBRARY=1 ... -only-testing:MiraiOSTests/LibrarySeedTool` (refuses any device not named
"Mira QA Library"). Each number below is the median of 3 runs (a fresh process each).
The probe's change step toggles the favorite flag of the newest picture and restores it (allowed on this simulator only).
Definitions: first sections = window shown to the sections published (the first screen can draw); all ready = every
count the first screen needs is known and cover requests were quiet for 0.7 s (before the fix the counts came with the
sections, so the definition gives the same answer for the base code); open frames = display-link intervals from
window shown to all ready; scroll = scripted 12,000 pt at 2,400 pt/s through the album list; change = ms from the
`performChanges` call until the Favorites count shows it, and the main-thread frames while it is processed.

| Measure | Before | After | Change |
|---|---|---|---|
| first sections published (blank screen until then) | 2722 ms | 248 ms | -91 % |
| all first-screen counts + covers ready | 2787 ms | 336 ms | -88 % |
| open: main-thread max frame | 73.6 ms | 141.6 ms | worse (see below) |
| open: main-thread p95 frame | 16.7 ms | 37.3 ms | worse, few frames (about 20) |
| open: frames > 50 ms | 2 | 1 | |
| album-list scroll: p50 / p95 frame | 16.7 / 16.7 ms | 16.7 / 16.7 ms | same |
| album-list scroll: max frame | 16.7 ms | 16.7 ms | same (one run each: 34.9 before, 54.3 after) |
| album-list scroll: frames > 33 ms | 0 | 0 | same |
| one library change (favorite on), ms until Favorites shows it | 2606 ms | 45 ms | -98 % |
| same, favorite off | 2586 ms | 29 ms | -99 % |
| main-thread max frame while a change is processed | 16.7 ms | 16.7 ms | same |
| cover lookups caused by two changes (every visible tile re-ran before) | 16 | 8 | -50 % |
| album grid (node "all") first request | 89 ms | 85 ms | same |
| album grid scroll p95 / max frame | 16.7 / 16.7 ms | 16.7 / 16.7 ms | same |
| album grid scroll, thumbnail requests | 216 | 216 | same |

`SidebarLoader` timed on a background thread (median of 3, ms):

| Part | Before | After |
|---|---|---|
| `loadAll()` including album capabilities | 1350 | not used by the iPhone any more (still the Mac's) |
| `loadAll(withAlbumEntries: false)` | 1159 | not used by the iPhone any more |
| of which: user album counts (154 albums, one fetch each) | 1178 | 0 up front; one fetch per tile, when it appears |
| of which: library + favorites counts | 11 + 3 | same, in the first-screen pass |
| `albumCapabilities` (one fetch per album) | 234 | 0; asked when a context menu opens |
| first-screen structure (`SidebarLoader.structure`) | | 65 |
| media types + utilities counts (background pass) | | 61 |

**Where the time went.** The main thread was never the problem at base: the loader already ran in a detached task, the
list scrolled at the display rate, and a library change did not stall frames. The problems were latency and waste.
The first screen was blank until `loadAll` had counted everything (2.7 s on 154 albums; it grows with the number
of albums), and every library change re-ran the whole of `loadAll` (2.6 s to show a changed favorite count) and made
every visible cover tile look its cover up again.

**Open frame.** The max frame while the screen opens went from 74 to about 140 ms. Before, the screen was blank for the
whole 2.7 s, so the first frame that draws content (the album list with its tiles' first tasks) happened late and the
stall was the same kind of event. Now it happens 250 ms in, and the same event is the 140 ms frame. It did not get
cheaper; it got earlier. Reducing it (cheaper first layout of the list) was left for later.

**What each fix was.**
- First screen from a cheap pass: `SidebarLoader.structure` builds LIBRARY (three counts, about 12 ms), ALBUMS and
  SHARED ALBUMS from collection lists only (folders walked, no per-album fetch; an estimated count of zero is trusted, as
  before) and lists the media-type / utility smart albums that exist, without counts.
- Counts and covers on demand: a tile's `.task` asks `GalleryModel.ensureCount`, which fetches on a detached task
  (skipped if the tile already scrolled away) and caches the count in `counts`; media types and utilities are
  counted in one background pass right after the first paint so empty rows leave the list before they are reached.
  Nodes known to be empty are kept in `emptyIDs`; the list reads only that, so a count arriving re-evaluates the small
  count label, not the list.
- Incremental changes: `LibraryTracker` holds each counted node's fetch result; `photoLibraryDidChange` applies the
  `PHChange` to those results on Photos' own queue (`changeDetails(for:)`, in delivery order), publishes the new
  counts, and bumps the cover version of only the albums that changed. The sections are rebuilt only when the
  top-level collections, a folder's children or the shared albums list changed (also watched with `changeDetails`),
  and those rebuilds are still coalesced.
- Cover token: no longer includes the global change count (`scopeEpoch` + the node's own version). A library-wide
  membership change no longer clears every cover.
- Cover lookup uses `fetchLimit = 1`.
- Album capabilities: asked in the context menu's own view, so the PhotoKit lookup runs when the menu opens, not for
  every album up front and not with every body pass (`ContextMenuLazinessTests` still pass).
- Not done: moving `AlbumModel.apply`'s `changeDetails(for:)` off the main actor. It only runs for an open album grid;
  the probe's grid steps showed no stall, and the change step does not open one. Left as is.
