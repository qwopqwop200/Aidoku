# Local regression tests

## Scope

Use relevant fast checks by default. Broaden only for explicitly requested full
verification, a release/CI requirement, or a demonstrated regression that focused
suites cannot resolve. The shared Aidoku scheme defaults to AidokuFast;
AidokuFull has no suite filter. No skipped tests or zero-execution passes are
accepted. A timeout is incomplete, never a pass.

Page translation has one pipeline, V2 (`Docs/translation-v2.md`). The legacy
page pipeline, its host CLI features (analysis report, render/resume runs) and
its smokes, quality matrices and research tooling have been removed.

## Commands

```sh
# Host tooling smoke checks
python3 Scripts/test_quick.py

# Default native simulator selection (Release)
python3 Scripts/test_quick.py --fast-ios --device <UDID>

# Explicit affected suites
python3 Scripts/test_quick.py --ios V2PipelineSchedulingTests --device <UDID> --configuration Release --jobs 2

# Full plans, only when the broader scope is required
python3 Scripts/test_quick.py --full-ios --device <UDID>
python3 Scripts/test_quick.py --full-host
```

`python3 Scripts/test_quick.py` runs the Python tooling tests
(`unittest discover -s Scripts`), localization validation and the model-free V2
host settings check (`Scripts/tests/run-image-environment-smoke.py`).

The full-host command manifest is `Scripts/tests/full-host-matrix.json`. Every
entry still applies to kept code and passes:

- V2 host: `run-image-environment-smoke.py` (.env < shell < CLI precedence,
  `AIDOKU_ENV_FILE`, validation without secret output, input lists, phone import)
  and `run-image-translation-smoke.py` (real Core ML OCR in `--ocr-only`, the
  production `RemoteTranslationClient` against a loopback mock: page image,
  text-role schema, segment ids, overlapping requests, input-ordered results,
  replay from a V2 run with no provider call, decode failures, exit codes and
  credential exclusion from every output file).
- OCR and translation contracts over files the V2 host compiles: CTC collapse,
  DB float digest, detector padding, DB child columns,
  multiline column recovery, geometry deduplication, ROI probability evidence,
  recognizer execution/observation/tensor identity, role verification planner,
  codec source fidelity and the language filter.
- Non-translation: Hoshi storage and sanitizer boundaries, blocking-task priority.

The V2 host smoke uses `Scripts/tests/fixtures/v2-host/VerticalSingleGlyphBalloon.png`
and the incremental host cache `build/image-translation-v2`. Score a V2 run on
the private GT split with `python3 Scripts/v2/eval.py RUN_DIR --split dev`.

## Resource and build policy

Use one simulator and two compiler jobs. Retain Release `-O`,
`SWIFT_COMPILATION_MODE=singlefile` and `ONLY_ACTIVE_ARCH=YES`. Reuse
`build/simulator-fast-release` (and `build/device-fast` for device builds).
Never run concurrent builds against the same cache. Do not clean or delete
DerivedData for routine edits. Rebuild current sources before testing; use
`test-without-building` only for the same successfully built sources/settings.

There is no default iOS compile, launch or test deadline. The 55-second default
applies only to host smoke checks; `--seconds` is an explicit override. Report
build, launch/test execution and test-body timings separately, and distinguish
simulator, device and host-only results. Passing host tests does not establish
identical macOS/iPhone font metrics or device performance.

Keep condition-based waits, controlled test clocks, fixture assertions and
parameter matrices. Production retry delays must remain unchanged. Keep
credentials and private `.env` values out of logs and reports. Host smokes never
read the developer's `.env` (`AIDOKU_ENV_FILE=` disables it) and never call a
real provider.
