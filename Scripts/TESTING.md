# Local regression tests

## Default iOS tests: AidokuFast

The Aidoku scheme now defaults to **AidokuFast** with Release optimization.
Normal Xcode Test / Cmd-U uses this plan. It selects 153 measured fast regression
suites covering codecs, source pagination, cache bounds, cancellation, scheduling,
storage, and basic geometry. The previous approximately three-minute exhaustive
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

The expensive network-contention experiment, live CoreML inference, WebKit image
matrices, render/page-turn benchmarks, and external/opt-in fixtures have been
removed from the routine plan. They remain in AidokuFull. Existing test assertions
and input matrices are unchanged. Add new lightweight suites to AidokuFast's
`selectedTests.suites` as `{"name": "SuiteName"}` (the legacy string array
selects XCTest classes, not Swift Testing suites); new suites are always included in the unfiltered AidokuFull.

Explicit `--ios <suite>` runs against AidokuFull so a focused slow test is not
silently filtered by the default plan. It retains its Debug configuration default.

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
xcodebuild test -project Aidoku.xcodeproj -scheme Aidoku -testPlan AidokuFull \
  -configuration Release -destination 'platform=iOS Simulator,id=<simulator-UDID>' \
  -derivedDataPath build/simulator-fast-release -skipPackagePluginValidation \
  -parallel-testing-enabled NO -jobs 4 SWIFT_COMPILATION_MODE=singlefile \
  ENABLE_TESTABILITY=YES ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES CODE_SIGN_IDENTITY=-
```

Retain the project development team and entitlements. Disabling signing loses
simulator Keychain access (`errSecMissingEntitlement`, -34018). Let Xcode generate
the simulator entitlements; manually signing the finished app is not equivalent.
Do not clean the stable cache between normal runs.

The AidokuFull plan includes real CoreML, WebKit, network contention, and negative
observation windows. It is not guaranteed to finish in a minute. Dataset,
provider, soak, populated-library, and physical-device tests have explicit opt-in
prerequisites; default skips do not validate those paths. Supply each original
fixture/marker and service only when running that test's documented scenario.
Some older fixture loops return early when images are absent, so even a default
pass is not evidence of real-image coverage for those cases.

## Broader host and package checks

The complete source-color matrix is in `.github/workflows/source-color.yml`;
keep its fixture arguments. Additional browser regressions can use
`PLAYWRIGHT_MODULE` pointing to an installed Playwright package. Native storage
and boundary regression scripts retain ASan/UBSan. Package suites:

```sh
swift test --package-path Vendor/Nuke --jobs 2
swift test --package-path Vendor/Wasm3 --jobs 2
swift test --package-path Vendor/AidokuRunner --jobs 2
```

AidokuRunner resolves package dependencies and its JavaScript test loads a live
image from aidoku.app. Report network/environment failures explicitly.

## Test optimization contracts

- Retry tests inject a controllable wait and assert the original retry delays;
  production delays and cancellation guards remain unchanged.
- Browser fixtures share at most one idle WKWebView, load a fresh document per
  case, fence attached viewport presentation before measurement, and restore
  native appearance on release. Concurrent checkouts stay
  separate. Do not add persistent scripts/message handlers to pooled views.
- Source-color Node tests reuse compiled scripts, but each harness gets a fresh
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
