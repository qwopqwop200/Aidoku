# Local regression tests

## Scope

Use relevant fast checks by default. Broaden only for explicitly requested full
verification, a release/CI requirement, or a demonstrated regression that focused
suites cannot resolve. The shared Aidoku scheme defaults to AidokuFast;
AidokuFull has no suite filter. No skipped tests or zero-execution passes are
accepted. A timeout is incomplete, never a pass.

The previous Web renderer and its JS/WASM comparison runners, captures and
pixel-acceptance gates have been removed. Native correctness, restoration,
export, cache, cancellation and memory-lifetime tests remain. The interactive
CLI report still uses JavaScript to inspect saved native outputs.

## Commands

```sh
# Host tooling smoke checks
python3 Scripts/test_quick.py

# Default native simulator selection (Release)
python3 Scripts/test_quick.py --fast-ios --device <UDID>

# Explicit affected suites
python3 Scripts/test_quick.py --ios NativeDirectExportTests NativeTranslationPixelKernelBridgeTests \
  --device <UDID> --configuration Release --jobs 2

# Full plans, only when the broader scope is required
python3 Scripts/test_quick.py --full-ios --device <UDID>
python3 Scripts/test_quick.py --full-host
```

The full-host command manifest is `Scripts/tests/full-host-matrix.json`.
It contains native CLI, graphics, layout, OCR-merger, Hoshi boundary and host
tooling checks. Native restoration quality matrices also run in
`.github/workflows/source-color.yml`, with executed-case verification through
`Scripts/verify_native_quality_result.py`.

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
credentials and private `.env` values out of logs and reports. Reader and CLI
OCR limits are detector 1184 and recognizer 48 × 1184; explicit historical replay
inputs can retain their recorded geometry independently of these defaults.
