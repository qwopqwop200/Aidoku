# Native Swift image translation runner

Run from the Aidoku Git root on Apple Silicon macOS 15+ with Xcode command-line tools and Rust (`rustc`):

```sh
swift Scripts/image-translation.swift /path/to/page.png
swift Scripts/image-translation.swift /path/to/images
swift Scripts/image-translation.swift --list /path/to/images.json
swift Scripts/image-translation.swift --help
```

The launcher compiles current repository sources, including uncommitted changes, into a native host executable. It shares production Core ML OCR, recovery/grouping, provider translation, source-style inference, segmentation, AOT inpainting and native layout. Core Graphics and Core Text compose the final bitmap and PDF output. Original Rust pixel kernels compile into a native static library. Rendering does not execute WebKit, JavaScript or WebAssembly. The macOS graphics adapter supplies UIKit-shaped drawing operations; source-canvas composition uses the same worker-side Core Graphics implementation as the app.

The executable, object files and compiled Core ML models are reused under `build/image-translation-host`. Source, native-library and model changes invalidate affected cache entries. The command does not build or launch the iOS app or a simulator. Core Text/AppKit font metrics, spelling dictionaries, color management and Core ML execution may differ from iOS; host success does not establish iPhone pixel parity or performance.

## Production rendering

The renderer uses source-bound OCR and RF evidence to identify the text to remove. It extracts source style, builds the erasure mask, restores the background with AOT and paints the translated items at the admitted positions. Pages with no retained translation can pass through with the original pixels. PNG and PDF exports use the same composed page.

## Configuration

The repository's ignored `.env` loads automatically, including when the launcher is invoked by absolute path from another directory. Precedence is **CLI > shell environment > .env > built-in defaults**. `.env.example` contains no credential. Credentials are excluded from printed settings and artifacts. Dotenv supports `KEY=value`, quoted literals, comments and optional `export`; it does not evaluate shell expressions.

The default Manga v0.3 detector uses a 1120-pixel maximum side. The recognizer accepts crops up to 2400 pixels wide at height 48. Detector sides are clamped to 32–1184 pixels. Recognizer widths are clamped to 32–2400 for Manga and 32–1184 for the other tiers. The input and runtime settings diagnostics record the effective values after overrides.

For the fixed 836-page corpus, `python3 Scripts/manga_ocr_search.py prepare`
creates a source-hash-bound request under `build/manga-ocr-search-current`.
Run `swift Scripts/image-translation.swift --manga-detector-search REQUEST`,
then `python3 Scripts/manga_ocr_search.py evaluate-text`. This Manga-only mode caches
raw float32 probability maps at 512/768/960/1184 and runs the production DB
postprocessor with pixel thresholds down to 0.01, box-score floor 0.01 and
multiple expansion ratios. It does not invoke RF, translation or rendering.
`prepare-text-recognition` creates a request for the DEV-selected detector geometry;
`--manga-recognizer-search REQUEST` reuses those detector boxes with the Manga
recognizer at confidence floor 0.01. `evaluate-text-recognition` searches box and
recognition confidence without rerunning models. Reports call their metric a
silver paragraph-envelope F1 **proxy**, not word-box F1 or transcription
accuracy. Existing DEV100 selects parameters; historical validation40 and all836
are reported separately. This workflow does not change production defaults or
claim newly unseen validation, visual inspection, or mobile performance.
The `evaluate`/`evaluate-recognition` phases retain the older translation-target
metric for comparison only: they score only `must_cover` and incorrectly count
preserved source lettering as outside OCR targets. The `*-text` phases include
source `must_cover` and `protected` dialogue/caption/SFX/background lettering,
exclude `allowed` placement envelopes, and count art as protected overlap.

`Scripts/manga_ocr_upstream.py` compares the publisher's pinned v0.2 ONNX weights
and source numeric recipes with this native screening. Its `infer` phase runs
the original standalone 960 recipe, actual demo 960 (white margin, rotated and
cleaned crops), and demo 1120 (only the 960 resize-budget constants changed).
The reference uses ONNX Runtime CPU FP32 instead of publisher OpenVINO FP16;
record that backend distinction when interpreting timings or output differences.
`evaluate` scores saved outputs, including optional furigana filtering, against
the same source-text labels. `ablate-postprocessing` reuses existing native960
and native1184 probability tensors with the original example DB decoder to
isolate postprocessing without another model call. Reference sources, weight
hashes, environment and reports live in `build/manga-ocr-search-current/upstream`.

Import a phone's saved settings with:

```sh
python3 Scripts/image-translation/sync-iphone-settings.py \
  --device <DEVICE_ID> --bundle-id <INSTALLED_AIDOKU_BUNDLE_ID>
```

This reads installed preferences and preserves the local API key; it does not read the phone's Keychain. Imported values are a saved snapshot, not a live query at each run. Scheduling/cache settings are provenance: the CLI uses its own bounded workers. Credential-free effective settings are recorded in `runtime-settings.json`. Page translation includes an image attachment and applies SFX/background filtering. Use `--rtl` or `--no-rtl` to override reading direction.

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

## Exact provider response reuse

The normal image pipeline uses the app's shared translation service and exact memory/disk cache. Identical ordered text, bounds, image identity, provider/model, prompt policies/instructions, languages and sampling settings can reuse the raw response. Tracker IDs are rebound to each caller. Changed source candidates or context remain cache misses; rendering and current downstream filters still run. A cache hit is reported as cached provenance, not fresh inference or a translation-quality pass.

Automatic provider disk caching requires a nonsecret credential generation:

```sh
swift Scripts/image-translation.swift --credential-generation 1 /path/to/page.png
```

`AIDOKU_TRANSLATION_CREDENTIAL_GENERATION=1` is the equivalent environment setting; the CLI option takes precedence. Increment this unsigned integer whenever the API key, account, project or tenant binding changes. Never pass an API key or a key hash as the generation. If the generation is absent, reuse is process-local memory only and no provider response disk cache is enabled. The bounded shared disk store lives under `build/translation-provider-cache`, independently of run output and render settings. Identical concurrent requests within the same process share one provider attempt.

This setting scopes automatic provider-response reuse. Explicitly selected completed artifacts retain the existing `--resume-run` and `--render-run` behavior; missing generation must not silently rerun or overwrite a completed page. Internal saved-LLM diagnostics remain a separate path and are not covered by this normal-pipeline cache contract.

## Processing and output

Default output is `../output/image-translation/run-<UUID>/`. `--output DIR` changes the parent. Each run gets a fresh directory; numbered image subfolders prevent basename collisions. Canonical duplicate inputs are processed once. PNG, JPEG/JPG, AVIF, WebP, HEIC/HEIF, TIFF, BMP and GIF are collected, together with other extensions supported by the host ImageIO decoders. Files with missing or unexpected extensions are probed by content; metadata sidecars are excluded. Recognized image files that cannot decode produce per-image errors instead of being silently skipped. Folder entries are naturally sorted, `--recursive` includes child folders and `--limit N` bounds the list. EXIF orientation is applied first; animated images use the first frame. Per-image failures create `error.json` and allow subsequent inputs to continue. Invalid configuration or missing inputs fail before model loading.

Numbered diagnostics record input/settings, detector maps/polygons, recognizer confidence and recovery candidates, grouping and balloon evidence, reading order, filtered translation batches, HTTP bodies/status/metrics and native render diagnostics. Authentication headers and credential values are excluded. `--quiet` reduces console messages while preserving files. These are stage outputs, not every internal neural-network activation.

Each image has `input.png`, `ocr-boxes.png` and `final.json`. Translation mode also writes `native-layout.json`, `final-layers.json`, `final-typography.pdf`, `final.png` and `final.html`. The HTML is a static preview referencing the adjacent `final.png`: opening it does not rerun OCR, translation or rendering. Keep those two files together when copying a preview. Final composites are also collected as numbered files in `RUN_DIRECTORY/final/`. `summary.json` preserves input order, outcome, timing and errors.

`native-render-diagnostics` records the native renderer output. Inspect the complete original and final composite to assess text-box coverage, surrounding-color fill, placement and readability. Historical outputs may retain segmentation masks and repaired crops; these describe the older renderer and are not required by the current text-box path. OCR-only runs have no translated PNG.

Native rendering uses the app's layout/settings normalization and bounded background/export sizing policies. Bundled fonts are registered with Core Text. The native compositor supplies the finished page for export. `final.png` is encoded once and the HTML references that saved file. The CLI vector export avoids creating a second full-page typography raster before final composition. Translation attachments use white-backed JPEG preparation with a 2048-pixel maximum side. Image-attached provider calls are limited to three.

`--jobs N` / `AIDOKU_IMAGE_JOBS` controls 1...64 image workers (default 8). Translation overlaps across images; OCR and native rendering each hold one admission slot, bounding shared Core ML and raster work. Output numbering and summary order remain stable when requests finish out of order. Throughput depends on provider and stage costs.

For large fresh runs, `--compact-output` retains the source, OCR boxes, detector/recognizer logs, replay payload, final JSON and rendered PNG, but removes duplicate stage reports, the self-contained analysis payload, and the optional typography PDF after each successful page. The per-page `analysis.html` becomes a lightweight one-column image review; `compact-output.json` records the exact generated files retired. Failed or incomplete pages retain their diagnostics.

## Replay and analysis

`--retranslate-run RUN_DIRECTORY --list RUN_DIRECTORY/input-manifest.json` reuses saved primary OCR evidence and original page images, **runs the current paragraph merger before translation**, and renders fresh provider translations into a new `--output` parent. It does not rerun detection or recognition. Original primary tables and RF evidence are restored only through the snapshot's recorded replay ancestry; missing/mismatched evidence fails explicitly instead of silently reusing old grouping. The retained `saved-ocr-replay` receipt records the grouping policy, restored lineage count, merged IDs, splits and evidence directory. OCR-box previews are redrawn from actual regrouped inputs. Keep the complete original input order: numbered saved page directories must match the manifest. The v34 page prompt uses the user-approved explicit SFX/background/dialogue/narration/story-text/error definitions; both provider protocols are checked against its exact text. Its new lettering/background policy identities invalidate previous translation cache entries. SFX/background roles still filter rendering, not the provider's obligation to translate every input ID.

While processing, open `progress.html` for a result gallery that refreshes every five seconds. Each completed page immediately publishes its analysis report and final image. `summary.json` and `progress.json` are updated atomically after every completion, including failures; `input-manifest.json` preserves the selected input order for resuming. Numbered OCR, partial translation, HTTP and renderer files are saved as their stages finish. Console milestones report OCR, translation and aggregate completion even with `--quiet`. The gallery stops refreshing when the run finishes.

```sh
# Recompose saved results with the current native renderer; no OCR/API calls.
swift Scripts/image-translation.swift --render-run /path/to/run-UUID

# Identical composition/PNG and audits; do not persist auxiliary typography PDFs.
# Exact source-size main output skips PDF creation; other geometry keeps PDF composition.
# Portable PDF-layer replay needs a normal rerender. AIDOKU_PNG_DIRECT_MAIN=0 rolls back.
AIDOKU_REPLAY_PNG_ONLY=1 swift Scripts/image-translation.swift --render-run /path/to/run-UUID /path/to/fresh-png-output

# Continue the same input list/order/settings; completed results are retained.
swift Scripts/image-translation.swift --resume-run /path/to/run-UUID /path/to/images

# Rebuild reports from saved JSON and pixels; no OCR/models/server.
swift Scripts/image-translation.swift --visualize-run /path/to/run-UUID
```

New rendered pages include `render-provenance.json`, binding the launcher build fingerprint,
encoded source and saved payload bytes (when available), parameter-file identity and final PNG.
Replay galleries show the generating build identifier rather than implying every saved gallery
uses today's source. A build identity is not a quality, model-weight or physical-device pass.
Missing provenance in historical outputs remains unmeasured; it is never added retroactively
to claim they were regenerated. The ensemble collector CLI defaults to `--require-current-build`,
rejecting missing/mismatched identity and outputs from a different currently built executable.
Use `--allow-historical-build` only for explicit historical evaluation; it does not label old
outputs current. Python helper callers retain their explicit historical-compatible behavior.

Replay accepts saved native payloads and migrates supported historical items/appearance payloads into native layout/settings. Recomposition retains saved translation and geometry; rerun source images to regenerate OCR/layout inputs. Replays preserve distinct diagnostic captures. Completed native items have `renderEngine: "native-coretext-coregraphics"`; OCR-only items use `"none"`. Resuming a completed historical translation without the native marker recomposes its saved image/payload natively without OCR/API calls before updating its metadata.

Each run includes `analysis-index.html`; each image has `analysis.html`, `analysis.json` and `analysis/*.png`. These offline reports show OCR confidence, recovery, merging, reading orientation, detector probability maps, balloon interiors and final rendered output. Available inpainting diagnostics depend on the producing run. Coordinates use source-image pixels with a top-left origin. Angles come from polygon geometry, not an OCR orientation classifier. Detector maps retain PNG and little-endian float32 `.f32` data. Geometric deskew crops are previews, not exact recognition tensors. Historical outputs show only diagnostics they saved.

## Post-recognition evidence filtering

The saved-evidence host route `--post-rec-joint-dedup OUTPUT_DIRECTORY` reads
NDJSON requests from stdin. Each request binds `page`, `sourceSHA256`,
`preRecCache`, `preRecCacheSHA256`, `recognition`, `recognitionSHA256`,
`recognitionRequest` and `recognitionRequestSHA256`. Cache files must be plain
JSON; recognition must have used exactly the cache's admitted polygons.

This route preserves the immutable pre-recognition RF/DET feature context and
joins actual recognition confidence by source index. It keeps the higher-REC
candidate only when polygon IoU is at least 0.85, its bbox confidence is within
0.05, RF text support within 0.05 and weighted RF text support within 0.02 of
the discarded candidate. Every discarded candidate has a directly retained
witness; suppression never follows a chain. Missing evidence keeps candidates.
Surviving polygons, confidence, provenance and recognized text are unchanged.
No GT, recognized text content, pixel texture or absolute shape feature drives
the rule. This route is explicit and does not change the normal image command
or install an application on a device.

`--post-rec-joint-features OUTPUT_DIRECTORY` exports the authenticated signal
join without filtering. The experimental `--post-rec-joint-filter OUTPUT POLICY`
and `--post-rec-joint-filter-and-dedup OUTPUT POLICY` routes require an explicit
validated numerical policy. A policy file's existence does not establish GT
preservation; rejected calibration experiments must not be promoted.

## Post-merge owner filtering

The normal Reader pipeline applies `NativePostMergeSignalFilter` after merging
and final-owner deduplication, alongside existing content admission and before
LLM requests. Its 107-field contract combines merged RF text/SFX mask evidence,
body REC minimum/mean/maximum and measured detector confidence/overlap summaries.
The fixed global policy removes whole merged owners and preserves every kept
owner's geometry, recognized text and source membership. Missing or invalid
evidence stays admitted. The source-conservation guard also retains an owner
when the aggregate maxima cannot rule out a strongly supported member; maxima
from different members are not described as a joint source proof.

`--postmerge-signal-replay REQUEST_JSON OUTPUT_DIRECTORY [POLICY_JSON]` verifies
the same Core decision on saved native Reader results without new RF/OCR or
provider calls. Omitting `POLICY_JSON` selects the compiled default. The request
contains `pages`, each with `page`, `sourceSHA256`, `nativeInput`,
`nativeInputSHA256`, `nativeResult` and `nativeResultSHA256`. RF measurements are
bound to the native audit, and detector aggregates are rebuilt from its exact
input members. Each output includes feature and decision receipts, policy/binary
hashes and kept indices. Original numerical output fields use typed decoding.
GT annotations are used only by separate offline evaluation, never admission.

Focused regression check: `python3 Scripts/tests/run-postmerge-signal-filter-smoke.py`.

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

## Manga OCR model

`--tier manga` (the fresh-install and CLI default) selects Kellenok PP-OCRv6_manga v0.3 (Japanese/Chinese).
Without saved or explicit overrides, it uses detector side 1120, pixel threshold
0.85, box threshold 0.25, and recognition confidence 0.30. Recognition
width is capped at 2400. Saved `.env`/shell settings retain their normal
precedence; `--tier` alone does not erase explicit threshold or size overrides.
The iOS model picker applies the Manga detector thresholds when switching into
Manga and the selected model's defaults when switching out. Manual size limits
are retained unless they equal the previous model's default.

Manga source-language choices are `auto`, `ja`, `zh-Hans`/`zh`, and `zh-Hant`.
Automatic source filtering admits only Japanese/Chinese, retaining ambiguous
short Han text. Unsupported explicit CLI source/filter languages are rejected.
Translation target languages and metadata/title translation are independent of
this OCR restriction. Previously saved explicit model choices remain available.

### Shared source inference and RF reuse

The normal macOS source appearance/segmentation/font path now uses the same
`NativeOperationalSourceInference` graph and frozen assets as iOS. Explicit
`AIDOKU_OPERATIONAL_APPEARANCE_BACKEND=legacy-python` is a diagnostic comparison
only; unavailable native evidence is not silently replaced with historical output.
Native RF raw-output reuse is enabled by default, bounded to two tensor snapshots
and 64MiB retained payload (not peak RSS). Every consumer still uses its own mask
budget and retention flags. `AIDOKU_RF_RAW_CACHE=0` selects the original direct
inference route. Model weights are unchanged. These defaults do not enable the
experimental source-anchor geometry or same-owner outlined-gap relaxation.

The shared SOURCE default is `minimal-m1-p9-body64-presence95-v1`: actual primary62/M1,
five native44 style roles, physical member-aware font
geometry and one page-batched BODY180 role. It does not run rich209 appearance,
boundary/OCR-context, learned font/PCA/prototype graphs. RF remains upstream.
The outline and shadow classifiers use 95 inputs independent of the background
color selection. Use `AIDOKU_SOURCE_INFERENCE_POLICY=minimal-m1-p9-body64-v1`
to select the previous 151-input classifiers.
Use `AIDOKU_SOURCE_INFERENCE_POLICY=simple-font-accepted-style-body-v1` for the
explicit previous-path rollback; `accepted` selects the original full graph.
All policies are cache-isolated, including the primary sampling ABI
`primary62-adaptive-odd-half-even-4ulp-v2`. External style overrides remain
SHA-verified and fail closed rather than falling back to bundled models.
This is a cost/quality tradeoff with measured background, outline-presence and
width losses versus the accepted graph, not a generalization or E2E-quality pass.
