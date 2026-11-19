# Page translation host (V2)

`Scripts/image-translation.swift` runs the app's only page-translation pipeline,
V2 (`Aidoku/Core/Translation/V2`, described in `Docs/translation-v2.md`), on an
Apple Silicon Mac with macOS 15+ and the Xcode command-line tools. It compiles
the same Swift stage files the app ships, so host output tracks the app.

```sh
swift Scripts/image-translation.swift /path/to/page.png            # live translation
swift Scripts/image-translation.swift /path/to/folder --jobs 3
swift Scripts/image-translation.swift --list pages.json
swift Scripts/image-translation.swift --ocr-only /path/to/page.png  # S1-S4 only
swift Scripts/image-translation.swift --split dev --limit 20 \
  --replay-translations ../release-830-live-20261119/full-d          # no LLM
swift Scripts/image-translation.swift --help
```

## Modes

| Mode | Stages | Provider |
|---|---|---|
| live (default) | S1-S10 | One request per page through `V2Translation.translate` and the production `RemoteTranslationClient`, with the app's mandatory page settings: page JPEG attached (long side 2048, q 0.85), SFX and background role filtering on. At most three page requests run at once, like the app. |
| `--replay-translations DIR` | S1-S10 | None. Translations come from a saved legacy run (`page-index.json`) or a V2 run (`pages/*.json`), matched with `V2TranslationReplay`. `--replay-fill-unmatched` and `--translate-delay-ms` support evaluation. |
| `--ocr-only` | S1-S4 (plus the cheap S8 style estimate) | None. No mask, inpaint, layout or paint; no PNG. |

Differences from the app: the host does not apply the reader's source-language
eligibility filter before S5 (`ReaderTranslationV2Service`), has no disk cache,
and draws with macOS Core Text metrics.

## Settings and credentials

Precedence is CLI arguments > shell environment > the repository's ignored
`.env` > defaults. `AIDOKU_ENV_FILE=PATH` reads another file and an empty
`AIDOKU_ENV_FILE=` disables dotenv (the smokes do this). The dotenv reader is
data only: no shell execution or variable expansion. `.env.example` lists the
keys and contains no credential. The API key (`AIDOKU_TRANSLATION_API_KEY`, or the
variable named by `--key-env`) is passed to the client at request time and is
never printed, logged or written to output; `--print-settings` reports only
whether it is present.

To copy the installed app's provider and language settings from a connected
iPhone into `.env` (the API key and Keychain are not touched):

```sh
python3 Scripts/image-translation/sync-iphone-settings.py --device <DEVICE_ID> --bundle-id <INSTALLED_AIDOKU_BUNDLE_ID>
```

It also removes keys only the removed legacy host read (OCR tier/thresholds,
overlay, viewport, panel order).

## Output

Default output is `../output/image-translation/run-<UUID>/` (`--output DIR`):

- `pages/<page>.json`: mode, size, blocks (lines with polygons, recognized text
  and confidence, reading order, role, translation, style), placed text, per-stage
  timings, failure, and replay matching counts in replay mode.
- `pages/<page>.png`: the final page (live and replay; `--no-png` skips it).
- `summary.json`: mode, input-ordered `pageResults`, failed pages, stage timing
  percentiles, model load and wall times, and non-secret provider settings.

Page ids come from file names (`input.png` uses its folder name); repeated files
run once and repeated ids get `-2`, `-3`, ... Exit status is 0 when every page
finished cleanly, 1 when a page failed (it is still recorded), and 2 for invalid
settings, which are rejected before any model loads.

`python3 Scripts/v2/eval.py RUN_DIR --split dev` scores a run against the
private GT split.

## Build

The launcher compiles `Aidoku/Core/Translation/V2`, an explicit list of shared
app files (detector, recognizer, translation client, simple grouping, painters,
OCR settings, process memory) and `Scripts/image-translation-v2` into one `-O`
binary with incremental state in `build/image-translation-v2` (`AIDOKU_V2_CACHE`
overrides it; `AIDOKU_HOST_BUILD_ONLY=1` builds and exits). Core ML models are
compiled once into `Models.bundle` in the same cache. Update the list in the
launcher when one of those app files moves.

## Checks

```sh
python3 Scripts/tests/run-image-environment-smoke.py   # settings/.env, no models
python3 Scripts/tests/run-image-translation-smoke.py   # real OCR, loopback mock provider
```

Never view or describe page images; process pixels in code only. Keep page
images, provider payloads and run output outside Git.
