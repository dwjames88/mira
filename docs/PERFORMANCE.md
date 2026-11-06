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
