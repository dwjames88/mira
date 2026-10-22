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

Model level and SwiftUI (drives a real `EditorModel`, hosts `EditorView` in an `NSHostingView`, counts film strip and card `body` evaluations; also writes `build/perf-ui.txt`):

```
cd Packages/MiraUI && MIRA_PERF=1 swift test -c release -Xswiftc -enable-testing --filter UIPerf
```

The UI test is skipped unless `MIRA_PERF=1`. Run on a quiet machine and repeat; one run on a loaded Mac can be 2x off.
