# Local regression tests

Use relevant fast checks by default; broaden only for explicitly requested full
verification, a release/CI requirement, or a regression focused suites cannot resolve.
The Aidoku scheme defaults to AidokuFast; AidokuFull has no suite filter. Skipped tests,
zero-execution passes and timeouts are never passes.

```sh
python3 Scripts/test_quick.py                                   # host tooling smoke checks
python3 Scripts/test_quick.py --fast-ios --device <UDID>        # AidokuFast (Release)
python3 Scripts/test_quick.py --ios V2StageTests --device <UDID> --configuration Release --jobs 2
python3 Scripts/test_quick.py --full-ios --device <UDID>        # only when required
python3 Scripts/test_quick.py --full-host
```

The default host run is `unittest discover -s Scripts`, localization validation and the
model-free V2 settings check (`Scripts/tests/run-image-environment-smoke.py`).
`--full-host` runs `Scripts/tests/full-host-matrix.json`:

- V2 host: `run-image-environment-smoke.py` (.env < shell < CLI, `AIDOKU_ENV_FILE`,
  validation without secret output, input lists, phone import) and
  `run-image-translation-smoke.py` (real Core ML OCR in `--ocr-only`, production
  `RemoteTranslationClient` against a loopback mock, replay without provider calls, exit
  codes, credential exclusion). It uses `Scripts/tests/fixtures/v2-host/VerticalSingleGlyphBalloon.png`.
- Contracts over files the V2 host compiles: CTC collapse and n-gram correction, detector
  padding, codec source fidelity and excluded-source preservation.
- Blocking-task priority.

Score a V2 run on the private GT split with `python3 Scripts/v2/eval.py RUN_DIR --split dev`.

## Resource policy

One simulator and two compiler jobs; Release `-O`, `SWIFT_COMPILATION_MODE=singlefile`,
`ONLY_ACTIVE_ARCH=YES`; reuse `build/simulator-fast-release` (`build/device-fast` for
device builds); no concurrent builds on one cache, no routine cleaning. iOS runs have no
default deadline; the 55-second default applies only to host smoke checks (`--seconds`
overrides). Report build, test and test-body timings separately. Keep controlled clocks,
condition-based waits and fixture assertions. Host smokes never read the developer's
`.env` (`AIDOKU_ENV_FILE=`), never call a real provider and keep credentials out of logs.
