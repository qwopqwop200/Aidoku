# Native Swift image translation runner

Run from the Aidoku Git root on Apple Silicon macOS 15+ with Xcode command-line tools and Rust (`rustc`):

```sh
swift Scripts/image-translation.swift /path/to/page.png
swift Scripts/image-translation.swift /path/to/images
swift Scripts/image-translation.swift --list /path/to/images.json
swift Scripts/image-translation.swift --help
```

The launcher compiles current repository sources, including uncommitted changes, into a native host executable. It shares production Core ML OCR, recovery/grouping, provider translation, native layout, source restoration and Core Graphics/Core Text/PDF composition. Original Rust pixel kernels compile into a native static library. Rendering does not execute WebKit, JavaScript or WebAssembly. The macOS graphics adapter supplies UIKit-shaped drawing operations; source-canvas composition uses the same worker-side Core Graphics implementation as the app.

The executable, object files and compiled Core ML models are reused under `build/image-translation-host`. Source, native-library and model changes invalidate affected cache entries. The command does not build or launch the iOS app or a simulator. Core Text/AppKit font metrics, spelling dictionaries, color management and Core ML execution may differ from iOS; host success does not establish iPhone pixel parity or performance.

## Configuration

The repository's ignored `.env` loads automatically, including when the launcher is invoked by absolute path from another directory. Precedence is **CLI > shell environment > .env > built-in defaults**. `.env.example` contains no credential. Credentials are excluded from printed settings and artifacts. Dotenv supports `KEY=value`, quoted literals, comments and optional `export`; it does not evaluate shell expressions.

OCR defaults to a detector maximum side of 1184 and a recognizer maximum width of 1184 at height 48. Positive CLI/environment sizes are bounded to the reader's supported 32...1184 range, including historical phone snapshots. Effective OCR settings are recorded in the input and runtime-settings diagnostics; model function names retain their bundled package identities.

Import a phone's saved settings with:

```sh
python3 Scripts/image-translation/sync-iphone-settings.py \
  --device <DEVICE_ID> --bundle-id <INSTALLED_AIDOKU_BUNDLE_ID>
```

This reads installed preferences and preserves the local API key; it does not read the phone's Keychain. Imported values are a saved snapshot, not a live query at each run. Scheduling/cache settings are provenance: the CLI uses its own bounded workers. Credential-free effective settings are recorded in `runtime-settings.json`. Boolean defaults can be overridden with `--no-include-image`, `--no-filter-sfx`, `--no-filter-background` and `--no-rtl`.

```sh
# No translation provider required.
swift Scripts/image-translation.swift --ocr-only --recursive /path/to/images
swift Scripts/image-translation.swift --ocr-only page1.png page2.jpg

# Lists contain newline-separated paths or a JSON array; relative paths resolve
# beside the list file.
swift Scripts/image-translation.swift --list /path/to/images.txt --source ja --target ko

# Local compatible servers require an explicit loopback development flag.
swift Scripts/image-translation.swift --base-url http://127.0.0.1:8000/v1 \
  --model your-model --allow-local-http --target ko /path/to/page.png

# Offline replay: a JSON object maps exact OCR source text to translated text.
swift Scripts/image-translation.swift --translations translations.json /path/to/page.png
```

`--viewport WIDTHxHEIGHT` / `AIDOKU_RENDER_VIEWPORT` sets the reader container in screen points. The default 430x932 is portrait geometry, not a live reader measurement. Each page is aspect-fitted. Supply actual reader geometry when comparing devices. `--layout-fixture FILE` emits native layout JSON for a neutral fixture without OCR, provider calls or `.env` loading.

## Processing and output

Default output is `../output/image-translation/run-<UUID>/`. `--output DIR` changes the parent. Each run gets a fresh directory; numbered image subfolders prevent basename collisions. Canonical duplicate inputs are processed once. Folder entries are naturally sorted, `--recursive` includes child folders and `--limit N` bounds the list. EXIF orientation is applied first; animated images use the first frame. Per-image failures create `error.json` and allow subsequent inputs to continue. Invalid configuration or missing inputs fail before model loading.

Numbered diagnostics record input/settings, detector maps/polygons, recognizer confidence and recovery candidates, grouping and balloon evidence, reading order, filtered translation batches, HTTP bodies/status/metrics and native render diagnostics. Authentication headers and credential values are excluded. `--quiet` reduces console messages while preserving files. These are stage outputs, not every internal neural-network activation.

Each image has `input.png`, `ocr-boxes.png` and `final.json`. Translation mode also writes `native-layout.json`, `final-layers.json`, `final-typography.pdf`, `final.png` and `final.html`. The HTML is a static self-contained PNG preview: opening it does not rerun OCR, translation or rendering. Final composites are also collected as numbered files in `RUN_DIRECTORY/final/`. `summary.json` preserves input order, outcome, timing and errors.

`native-render-diagnostics` replaces the old DOM/style diagnostic. Native restoration capture records initial/final repair-alpha masks, patch crops and actual repaired pixels; these are not historical JavaScript glyph bitmasks. An initial/candidate patch does not establish final adoption. Captures retain their bounds and report omitted entries. OCR-only runs have no translated PNG or renderer masks.

Native rendering uses the app's layout/settings normalization and bounded background/export sizing policies. Bundled fonts are registered with Core Text; export composes in-memory repair images and PDF text with the native compositor. The portable `final-layers.json` still stores PNG/Base64 masks, but composition does not decode that transport. `final.png` and the self-contained HTML share one PNG encoding. Translation attachments use white-backed JPEG preparation with a 2048-pixel maximum side. Image-attached provider calls are limited to three.

`--jobs N` / `AIDOKU_IMAGE_JOBS` controls 1...64 image workers (default 8). Translation overlaps across images; OCR and native rendering each hold one admission slot, bounding shared Core ML and raster work. Output numbering and summary order remain stable when requests finish out of order. Throughput depends on provider and stage costs.

## Replay and analysis

```sh
# Recompose saved results with the current native renderer; no OCR/API calls.
swift Scripts/image-translation.swift --render-run /path/to/run-UUID

# Continue the same input list/order/settings; completed results are retained.
swift Scripts/image-translation.swift --resume-run /path/to/run-UUID /path/to/images

# Rebuild reports from saved JSON and pixels; no OCR/models/server.
swift Scripts/image-translation.swift --visualize-run /path/to/run-UUID
```

Replay accepts saved native payloads and migrates supported historical items/appearance payloads into native layout/settings. Recomposition retains saved translation and geometry; rerun source images to regenerate OCR/layout inputs. Replays preserve distinct diagnostic captures. Completed native items have `renderEngine: "native-coretext-coregraphics"`; OCR-only items use `"none"`. Resuming a completed historical translation without the native marker recomposes its saved image/payload natively without OCR/API calls before updating its metadata.

Each run includes `analysis-index.html`; each image has `analysis.html`, `analysis.json` and `analysis/*.png`. These offline reports show OCR confidence, recovery, merging, reading orientation, detector probability maps, balloon interiors, native repair masks and final output. Coordinates use source-image pixels with a top-left origin. Angles come from polygon geometry, not an OCR orientation classifier. Detector maps retain PNG and little-endian float32 `.f32` data. Geometric deskew crops are previews, not exact recognition tensors. Historical outputs show only diagnostics they saved.

## Verification

```sh
python3 Scripts/tests/run-image-environment-smoke.py
python3 Scripts/tests/run-image-analysis-smoke.py
python3 Scripts/tests/run-image-layout-parity.py
python3 Scripts/tests/run-image-letter-fonts-smoke.py
python3 Scripts/tests/run-image-export-compositor-smoke.py
python3 Scripts/tests/run-image-composite-smoke.py
python3 Scripts/tests/run-image-translation-smoke.py
```

The last command uses real host Core ML OCR, native rendering and a loopback mock provider, including offline replay, folder/list selection, failure continuation, concurrent translation and credential exclusion. It builds once and runs all cases against that executable. `--reuse-built` checks an existing successful executable only; it does not validate changed sources. Follow the affected-test policy unless full verification is explicitly requested.

Native host tests validate the production CLI and renderer. Saved color/component counts are diagnostic evidence, not labelled OCR accuracy or mask-IoU scores. The previous browser-renderer comparison harness has been removed.

Exit codes: `0` all inputs succeeded, `1` preparation or per-image failures, `2` invalid CLI/configuration/input selection. Provider errors remain failures; the runner does not fabricate translations.
