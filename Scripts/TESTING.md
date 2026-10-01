# Local regression tests

## Native efficiency verification (2026-10-02)

Eight agents worked in `codex/native-render-efficiency`, based on `24e9dfb7`.
The focused simulator evidence contains **211 distinct test declarations / 343
expanded cases, all passed, zero skipped**, taking the latest result for each
declaration across `focused1`, `focused2`, `after3`, and `pixels2`. This is an
aggregation of affected-suite runs, not a new execution of the full plan.
`focused1` initially found a mixed-stroke ligature mismatch; the guarded fallback
and all seven affected glyph/export suites passed in `focused2`.

| Run | Build activity | Test body | Command wall time | Scope |
| --- | ---: | ---: | ---: | --- |
| baseline2 | 21.024 s | 11.179 s | 37.571 s | Baseline measurement harness, incremental build |
| focused1 | 2.983 s | 21.003 s | 37.667 s | No source-change build; 202 pass, 1 subsequently fixed failure |
| after3 | 83.148 s | 9.877 s | 98.038 s | Final production measurement, incremental build |
| focused2 | 2.777 s | 14.213 s | 21.552 s | No source-change build; 60 affected declarations passed |
| pixels2 | 20.626 s | 121.412 s | 146.704 s | Incremental test-only build; all 6 selected declarations passed |

One iPhone 17 Pro iOS 26.5 simulator, Release `-O`, `singlefile`, two build jobs,
serialized execution, and the existing `build/simulator-fast-release` cache were
used. Every run records source hashes before/after. Direct method selections in
`pixels2` were checked against the actual result-tree identifiers, including
Swift Testing parentheses; all requested methods executed. Build activity and
test body exclude some startup/result collection, so they do not sum to wall time.

Final-export fixtures passed **16/16** (15 exact, one maximum channel delta 3).
Recorded-page exports passed **22/22** using their existing documented reference
contracts. Source-canvas captures passed **7/7** under the explicit bounded native
resampling policy; **28/28** shifted/missing/flipped/alpha-damaged controls were
rejected. Raw pixel differences and frozen references remain intact. The eight
baseline/candidate measurement PNGs have exactly equal decoded pixels, and both
layout JSONs are unchanged.

The source-canvas six-patch microbenchmark fell from 247.061 to 0.643 ms median;
the tall uncached loaded-image path fell from 452.891 to 434.025 ms and its sampled
physical-footprint peak from 121.38 to 109.53 MiB. Three samples follow one warmup
per phase. RSS is mixed and some phase footprints increased. The 2 ms sampler can
miss short peaks. These are descriptive simulator results, not whole-app or
physical-device performance claims.

Host checks passed `run-image-native-graphics-smoke.py` (1.454 s) and
`run-image-export-compositor-smoke.py` (1.229 s), each including its standalone
compile. The actual current-source `run-image-translation-smoke.py` passed in
147.061 s, including incremental Release compilation, Core ML OCR, local provider,
render/save/replay/resume and concurrency/error checks. That combined host timer
does not separate compilation from execution. An earlier `--help`/`--reuse-built`
attempt is explicitly invalidated as current-source integration evidence because
help bypasses compilation; its two standalone compile checks remain valid.

Evidence: `../../output/native-efficiency/final-validation.json`,
`REPORT.ko.md`, `affected-final-coverage.json`, `comparison-final.json`,
`image-comparison.html`, and `runs/` in that output directory. No fixture baseline
was replaced and no skipped/disabled test was added for this change.

## Default iOS tests: AidokuFast

The Aidoku scheme now defaults to **AidokuFast** with Release optimization.
Normal Xcode Test / Cmd-U uses this plan. Its selected suites are declared in `AidokuFast.xctestplan` and cover codecs,
native source adapters, cache bounds, cancellation, scheduling, storage, geometry
and native rendering. Historical measured suite counts below apply to their
recorded snapshots, not the current plan. The previous approximately three-minute exhaustive
scope is retained as **AidokuFull**, explicitly selected when needed.

```sh
python3 Scripts/test_quick.py --fast-ios --device <simulator-UDID>
```

This rebuilds current sources, uses `build/simulator-fast-release`, and then runs
the fast plan. The target is under one minute on a booted simulator with a warm
incremental cache, including normal command startup. A first build, dependency
change, or large source rebuild can exceed that; compilation is never secretly
skipped or killed to manufacture a pass. iOS has no automatic timeout. The
existing optional `--seconds` limit still reports incomplete on timeout.

The expensive network-contention experiment, live CoreML inference, native/frozen-Web image
matrices, render/page-turn benchmarks, and external/opt-in fixtures have been
removed from the routine plan. They remain in AidokuFull. Existing test assertions
and input matrices are unchanged. Add new lightweight suites to AidokuFast's
`selectedTests.suites` as `{"name": "SuiteName"}` (the legacy string array
selects XCTest classes, not Swift Testing suites); new suites are always included in the unfiltered AidokuFull.

Explicit `--ios <suite>` runs against AidokuFull so a focused slow test is not
silently filtered by the default plan. It retains its Debug configuration default.
Pass bare suite names, without an `AidokuTests/` prefix or `/method` suffix.
Method filters are rejected before building because they can silently select zero
Swift Testing tests even when other requested suites run; select the whole affected suite.

Measured on 2026-09-25 with the booted Test-Optimization simulator and warm
Release cache: **788 tests / 153 suites passed, 0 failures, 0 skips**,
**24.20 seconds** for the current-source default `xcodebuild test` command
(including incremental build, launch, test execution, and result collection);
Swift Testing body time was **15.54 seconds**. The documented `--fast-ios`
runner independently passed in **30.1 seconds**. This is the reduced routine scope,
not an under-one-minute claim for AidokuFull or a clean build.

## Short host feedback loop

Run `python3 Scripts/test_quick.py` for the explicit host smoke scope. It has a
55-second host-only deadline. iOS runs have no default timeout; zero executed
iOS tests is a failure, not a pass.
For a focused current-source simulator run:

```sh
python3 Scripts/test_quick.py --ios ReaderTranslationSessionTests \
  --device <simulator-UDID> --configuration Release
```

Compilation, launch, and iOS tests run until completion by default. The focused
runner uses `ONLY_ACTIVE_ARCH=YES` to avoid compiling unused simulator architectures. Reuse
`build/simulator-fast-release`. An optional `--seconds <positive-number>` sets an
explicit total deadline; a timeout is incomplete, never a pass. This command does
not represent full-suite coverage.

## Full opt-in simulator suite

Use a dedicated simulator with disposable app data. The mixed-network A/B test
requires the deterministic loopback fixture in a separate terminal:

```sh
python3 Scripts/tests/network-fixture.py --port 8766 --rate 1048576 --sharing aggregate
```

Keep the rate and aggregate sharing mode: they define the contention workload.
Stop that fixture process after the test run. Then run the current sources:

```sh
python3 Scripts/test_quick.py --full-ios --device <simulator-UDID> \
  --result-bundle build/full-native-main.xcresult
```

Retain the project development team and entitlements. Disabling signing loses
simulator Keychain access (`errSecMissingEntitlement`, -34018). Let Xcode generate
the simulator entitlements; manually signing the finished app is not equivalent.
Do not clean the stable cache between normal runs.

The full runner defaults to Release `-O`, `singlefile`, active architecture,
two build jobs and one test worker/simulator. It has no default deadline. It
rebuilds current sources incrementally and reads the resulting xcresult summary:
nonzero executed tests, passed count equal to total, zero failures, zero skips
and zero expected failures are required for success. A filtered or zero-test run
is not a full pass. Choose a new result-bundle path; existing evidence is not
overwritten. The persistent `.log` and `.summary.json` accompany the bundle.
Wall time, build activity and Swift Testing body time are reported separately;
unavailable body timing stays unknown.

The AidokuFull plan includes real CoreML, native rendering, frozen WebKit
reference captures, network contention and negative observation windows. It is not guaranteed to finish in a minute. On 2026-09-28,
105 prerequisite-dependent test declarations were removed at the user's request.
That cleanup described the suite at its recorded revision. Later work restored
additional native fixture/device declarations; current prerequisites are asserted
by those tests and cannot be silently converted into skips or empty successes.
The older timing snapshots below describe their historical suite.
Four removed declarations silently continued past missing image fixtures; their
empty successful runs are no longer included in the full-suite count. The 50
resulting empty suite files and their unreachable fixture/benchmark helpers were
also removed; this cleanup does not remove additional executable tests.

The obsolete `run_webtoon_screen_tests.py` screenshot wrapper was retired: no
current test produces its `AuditWebtoon/capture-ready` protocol, so it could only
fail after a valid lifecycle run. `ReaderWebtoonLifecycleTests` remains in the
app test target and full plan; it does not claim external screenshot coverage.

## Broader host and package checks

For an explicitly requested full host run:

```sh
python3 Scripts/test_quick.py --full-host --host-result-directory build/full-host-results
```

The manifest in `Scripts/tests/full-host-matrix.json` specifies every command
and required fixture argument. This mode has no 55-second smoke deadline, runs
all listed commands even after failures and rejects skipped tests. Do not replace
the manifest with a file glob: corpus and browser scripts have different input
contracts. `--host-result-directory` must name a new directory; it preserves a
log and JSON result for each command plus aggregate `results.json`. Host execution
and AidokuFull are separate validation scopes.


The 107-command host matrix and the following three iOS suites form the
maintained translation quality gates. The native suites execute 418 original
scenario groups from 394 immutable fixture records. They preserve the reviewed
admission, glyph/ruby coverage, artwork/neighbor protection, ownership, input
immutability and budget contracts, with the explicit assertion changes below. Host results alone do not establish native
quality; run unfiltered AidokuFull for a requested full iOS verification.

| Historical offline diagnostic | Native production suite | Scenario groups |
| --- | --- | ---: |
| `source-inpainting-segmentation.cjs` | `NativeSourceSegmentationMatrixTests` |147 |
| `slanted-artwork-regression.cjs` | `NativeSlantedRestorationMatrixTests` |44 |
| `slanted-ruby-regression.cjs` | `NativeSlantedRestorationMatrixTests` |202 |
| `slanted-dense-recovery-guard.cjs` | `NativeSlantedRestorationMatrixTests` |4 |
| `slanted-native-outlines.cjs` | `NativeSlantedRestorationMatrixTests` |2 |
| `source-body-art-evidence-regression.cjs` | `NativeSourceOwnershipMatrixTests` |12 |
| `source-segmented-restoration-regression.cjs` | `NativeSourceOwnershipMatrixTests` |7 |

The suite totals are 147 segmentation scenarios, 252 slanted restoration
scenarios and 19 ownership scenarios. Xcode reports 219 case executions across
22 declarations: the 200 ruby records run inside one aggregate test. The CI
result verifier requires the exact per-suite declarations and argument counts.

The original Web scripts, source captures and fixture hashes remain frozen. The
native tests deliberately replace two painted-area contracts with source-derived
semantic checks; they do not claim every old numeric assertion is unchanged:

- Dense lettering formerly required exactly 2,798 painted pixels. Native checks
  require all 500 annotated owned letter pixels to be erased and all 20,652
  protected artwork pixels to remain unpainted, with the original admission and
  restoration-method checks retained.
- The two outlined captures formerly required at least 54,000 and 57,000 painted
  pixels. Native checks require every annotated owned colored core and white band
  to be removed and every protected artwork pixel to remain unpainted. Painting
  extra padding is not a quality criterion. Exact source hashes, immutable inputs
  and unpainted crop borders remain required.

The outline annotations come from the original RGB components and immutable OCR
quad, never from the candidate renderer output. Capture 0 protects two punctuation
components outside that quad with no auxiliary ownership; ambiguous mixed
fringe/backing is unannotated. All six owned components retain their full core and
white-band checks. The precise counts, ownership reasoning and mask hashes are in
`Scripts/tests/fixtures/slanted-native-outlines.semantic-provenance.json` and
`full-host-matrix.json`. Capture 1 retains its original semantic mask.

The six body/art cases still require exact restored RGBA and ownership-mask hashes.
The test-only [final-export raster acceptance rules](native-render-parity/README.md#run)
do not relax glyph, artwork, ownership or admission assertions. Python regression modules, including
the native-quality result parser, run through the existing mandatory unittest
command; the native graphics adapter smoke remains an explicit host command.

For focused quality verification, select all three suites together:

```sh
python3 Scripts/test_quick.py --ios NativeSourceSegmentationMatrixTests NativeSlantedRestorationMatrixTests NativeSourceOwnershipMatrixTests --configuration Release --device <UDID> --jobs 2
```

The CI `native-quality` job resolves an available iOS simulator dynamically,
runs those suites on one simulator and rejects skipped or zero-execution
results. The seven original scripts and frozen Web sources remain unchanged
for offline diagnosis; invoke them explicitly with `node Scripts/tests/NAME.cjs`.
Their known historical failures are not production quality failures or hidden
passes. They are not entries skipped by `--full-host`. The exact mapping and
original script/archive hashes are recorded in `full-host-matrix.json`.

The maintained Hoshi boundary runner compiles and runs the source, reader and C
API assertion suites sequentially with AddressSanitizer and UndefinedBehaviorSanitizer:

```sh
python3 Scripts/tests/run-hoshi-boundaries-regression.py
```

It uses the vendored sources and the exact Zstd revision in `Package.resolved`,
reusing a verified checkout or fetching that revision. See
[`Scripts/tests/README-hoshi-boundaries.md`](tests/README-hoshi-boundaries.md) for
build-cache and prerequisite details.


The remaining frozen-Web reference gate is in `.github/workflows/source-color.yml`;
keep its fixture arguments. These Node regressions read test-only historical
overlay sources. They are a separate reference gate and cannot establish that
the native Swift/Rust renderer ran or matched an image. Additional browser regressions can use
`PLAYWRIGHT_MODULE` pointing to an installed Playwright package. Native storage
and boundary regression scripts retain ASan/UBSan. Package suites:

```sh
swift test --package-path Vendor/Nuke --jobs 2
swift test --package-path Vendor/AidokuRunner --jobs 2
```

AidokuRunner resolves package dependencies and tests native manifest registration,
models and partial-result ownership. Report network/environment failures explicitly.

## Native integration validation snapshot: 2026-10-01

These are completed runs of their recorded source snapshots. Static inventory
contains 520 Swift test files and 2,435 declarations; expanded parameter executions
are reported separately. Historical failures remain in their original evidence.

| Run | Recorded result | Build activity | Test body | Wrapper wall time |
| --- | --- | ---: | ---: | ---: |
| `full-host-3` | 107/107 commands passed; 2,715 inputs unchanged | Not separately reported | Not separately reported | 368.647 s |
| `full-ios-8` | 2,433 passed, 2 failed, 0 skipped; 3,982 expanded passes and 2 failures | 37.202 s | 582.570 s | 645.721 s |
| `focused-ios-27` | 14 declarations / 25 expanded executions passed, 0 skipped | 22.821 s | 0.270 s | 29.007 s |
| `full-ios-9` | 2,435/2,435 declarations and 3,984 expanded executions passed; 0 failures/skips/expected failures; 2,723 inputs unchanged | 2.279 s | 582.234 s | 593.854 s |

The two full-ios-8 failures were a synthetic rectangle's numeric JSON type and
an outdated expected render-cache revision. Both suites passed after those
fixture/oracle repairs in focused-ios-27. The failed full run stays failed.
The subsequent unfiltered Release AidokuFull run, `full-ios-9`, passed using
those unchanged compiled sources and the same cache. Its build-activity figure
is a no-source-change check, distinct from focused-ios-27's incremental build.
One iPhone 17 Pro iOS 26.5 simulator and two build jobs were used. These simulator
validation times are not renderer benchmarks or physical-device results.

The final run also passed 22 recorded-page comparisons across two preload depths
and all 16 final-export fixtures. Fifteen final fixtures were exact; the remaining
fixture differed by at most three channel values on 2,325 pixels. Saved PNGs were
independently decoded and checked against the recorded metrics.

Saved pixel/JSON/PDF verification independently accepted the bounded glyph/panel
contour evidence on focused26 pages 5 and 9 and rejected 17 malformed or
material-change controls. It preserves raw raster differences and does not
replace source-protection, kernel, typography or cache checks. The base final16
report policy is unchanged. See [the parity contract](native-render-parity/README.md#run)
and [the audit](test-skip-audit.json) for exact artifact paths, hashes, source
counts, original failures and the separate host, iOS and image-proof scopes.

## Test optimization contracts

- Retry tests inject a controllable wait and assert the original retry delays;
  production delays and cancellation guards remain unchanged.
- Frozen-reference browser fixtures share at most one idle WKWebView, load a fresh document per
  case, fence attached viewport presentation before measurement, and restore
  native appearance on release. Concurrent checkouts stay
  separate. Do not add persistent scripts/message handlers to pooled views.
- Frozen source-color Node tests reuse compiled scripts, but each harness gets a fresh
  VM context, intrinsics, canvas state, and image buffers.
- Keep fixture matrices, meaningful overlap/negative observation windows, and
  stress/soak workloads. Measure build, launch, and test body separately.

## Verified timing snapshot (2026-09-25)

Rechecked the existing full-suite evidence against the working tree: all 332 files
listed in `../output/all-test-optimization-20260925/verified-snapshot.json` matched
their recorded SHA-256 hashes. This is verification of that recorded snapshot,
not a new full-suite execution or a hash of every repository file.

| Scope | Observed time | Result |
| --- | ---: | --- |
| Host quick checks, rerun for this documentation check | 3.7 s | All 9 commands passed |
| Recorded full Release simulator execution | 179.32 s | Summary: 1,369 passed, 0 failed, 98 skipped |
| Swift Testing body within that recorded execution | 172.559 s | Included in 179.32 s; not additional |
| Recorded final build (`final-build.json`) | 25.66 s | Build succeeded; separate from test execution |

The simulator used Release `-O` / `singlefile` and a stable cache. The complete
suite is not a sub-minute test. The earlier 217.37-second comparison had signing
failures, so it does not establish a controlled full-suite speedup percentage.
Two opt-in dataset comparisons (column layout and background color) still have
failures also reproduced with the original tests; the default pass does not cover
all conditional datasets, physical-device checks, providers, or soak tests.

Evidence: `../output/all-test-optimization-20260925/verified-all-summary.json`,
`verified-all.json`, `verified-all.log`, `final-build.json`, and `REPORT.ko.md` in
that directory. The fresh host run is recorded at
`../output/test-speed-policy-check-20260925/quick-host.log`.

## Fresh full iOS rerun (2026-09-25)

A new current-source Release build and full default simulator run completed:
**1,369 passed / 0 failed / 98 prerequisite-dependent skips**. Build:
**200.67 s**; test execution: **181.42 s**, including **169.805 s** of Swift
Testing body time. Combined build/test time was **382.09 s**, excluding waiting
for another cache owner. This build included recompilation after configuration
changes and is not a warm no-change timing.

No suite filters were used. All 1,088 recorded source/configuration files matched
before/after. `build-for-testing` immediately preceded `test-without-building`,
so the run used the freshly compiled current sources. Evidence and scope limits:
`../output/ios-full-rerun-20260925/REPORT.md` and `tests.xcresult`.

The iOS runner has **no default compilation/test deadline**; only host smoke checks
retain the 55-second default. Three runner regression tests verify this policy.

## Eight-agent typesetting review verification (2026-09-28)

Reviewed local `main` (`0d22699e`) against `typesetting-quality-final`, including
the prior uncommitted repair work. Eight agents covered OCR, overlay layout,
kernels, restoration/color, typography, translation, cache/UI, and dead tests.

| Scope | Result | Build / execution |
| --- | --- | --- |
| Full Release simulator, AidokuFull, no suite filter | 1,460 passed, 0 failed, 0 skipped | 126.21 s / 184.93 s |
| iPhone 15 Pro Max, iOS 26.6.2, eight affected suites | 334 passed, 0 failed, 0 skipped | 383.13 s / 19.11 s |
| Device production Release build | Passed, signed and installed | 274.01 s |
| Host regression matrix | 49 commands passed, including 43 Python tests | Separate host scope |
| Package tests | Nuke 9, Wasm3 26, AidokuRunner 30 passed | Separate package scope |
| Native storage / blocking priority probes | Both passed | Separate host scope |

The first physical-device execution lost its remote runner connection after 159
test definitions passed. It did not record a test assertion failure. The same
compiled sources and same eight suites passed on retry; the initial interruption
is not counted as a successful run. Sources were unchanged between build and
test. Stable caches, Release `-O`, `singlefile`, and active architecture were used;
no clean or arbitrary iOS timeout was applied. These builds include recompilation
and are not warm no-change timings.

Installation preserved all 328 existing Documents, Application Support, and
Preferences files byte-for-byte before app launch. Physical execution covers the
selected OCR, translation, overlay-engine, and cache suites; it does not establish
whole-app latency, actual-reader visual quality, live-provider behavior, or
long-duration Jetsam safety. Helper microbenchmarks are not end-to-end speedups.
