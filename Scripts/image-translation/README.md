# Page translation host (V2)

`swift Scripts/image-translation.swift` runs the app's V2 page-translation pipeline
(`Docs/translation-v2.md`) on Apple Silicon macOS 15+, compiling the same stage files
the app ships. Usage and options: `--help` (`help.txt`); overview in `CLAUDE.md`.

| Mode | Stages | Provider |
|---|---|---|
| live (default) | S1-S10 | One request per page through `V2Translation` and `RemoteTranslationClient` with the app's mandatory page settings (page JPEG, SFX/background filtering), at most three at once. |
| `--replay-translations DIR` | S1-S10 | None: translations from a legacy `page-index.json` run or a V2 run, matched by `V2TranslationReplay`. |
| `--ocr-only` | S1-S4 (plus the S8 style estimate) | None; no PNG. |

Unlike the app, the host skips the reader's source-language eligibility filter, has no
disk cache and uses macOS Core Text metrics.

## Settings and output

Precedence is CLI > shell > the ignored `.env` > defaults; `AIDOKU_ENV_FILE=PATH` reads
another file and `AIDOKU_ENV_FILE=` disables it. The dotenv reader does no shell
execution or expansion. The API key (`AIDOKU_TRANSLATION_API_KEY` or `--key-env`) is
never printed or written. `sync-iphone-settings.py --device <DEVICE_ID> --bundle-id <BUNDLE_ID>`
copies the installed app's provider and language settings into `.env` without touching the
key, and removes keys only the legacy host read.

A run writes `pages/<page>.json`, `pages/<page>.png` (not with `--no-png`/`--ocr-only`) and
`summary.json` to `../output/image-translation/run-<UUID>/` (`--output DIR`). Page ids come
from file names (`input.png` uses its folder); repeated files run once, repeated ids get
`-2`, `-3`. Exit status: 0 clean, 1 a page failed, 2 invalid settings (before model load).

## Build and checks

The launcher compiles `Aidoku/Core/Translation/V2`, an explicit list of shared app files
and `Scripts/image-translation-v2` into one `-O` binary in `build/image-translation-v2`
(`AIDOKU_V2_CACHE` overrides it; `AIDOKU_HOST_BUILD_ONLY=1` only builds). Update that list
when a shared file moves. Checks: `Scripts/tests/run-image-environment-smoke.py`
(settings, no models) and `Scripts/tests/run-image-translation-smoke.py` (real OCR, mock
provider). Never view page images; keep images, payloads and output outside Git.
