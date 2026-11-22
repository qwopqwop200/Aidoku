# CLAUDE.md

Guidance for coding agents in this repository (`AGENTS.md` points here). The parent directory holds datasets and
generated reports.

Aidoku is an iOS/iPadOS/macOS manga reader (UIKit + SwiftUI, Core Data). This fork adds on-device PP-OCRv6 (Core ML)
OCR and OpenAI / custom OpenAI-compatible page translation with native UIKit/Core Graphics/Core Text overlays.

## Build & test

`Aidoku.xcodeproj` has three targets: `Aidoku` (app, iOS 15+), `AidokuShare` (share extension) and `AidokuTests`
(hosted in `Aidoku.app`, deployment target 26.0). Use the shared `Aidoku` scheme (Cmd-U runs AidokuFast). SwiftLint
runs as an SPM build plugin.

```sh
python3 Scripts/test_quick.py                                      # host checks: Python tooling, localization, V2 settings
python3 Scripts/test_quick.py --fast-ios --device <UDID>           # Swift checks (Release, AidokuFast)
python3 Scripts/test_quick.py --ios TrackerSyncTests --device <UDID> --configuration Release   # one affected suite
python3 Scripts/test_quick.py --full-ios --device <UDID>           # complete plans, only when justified (below)
python3 Scripts/test_quick.py --full-host                          # Scripts/tests/full-host-matrix.json
swiftlint lint
python3 -m unittest discover -s Scripts -v && python3 Scripts/validate_localizations.py   # CI; see Scripts/LOCALIZATION.md
# Unsigned archive (CI nightly)
xcodebuild -scheme Aidoku -configuration Release archive -archivePath build/Aidoku.xcarchive \
  -skipPackagePluginValidation CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
```

### Verification scope (mandatory)

- Run only the relevant fast checks (host or `--fast-ios`, not both by default) and stop once they pass: no extra
  full tests, benchmarks or repeated runs for reassurance. A host-only pass is not evidence for Swift, OCR, WebKit
  or device behavior.
- If the change is outside AidokuFast, run only the affected AidokuFull suite (`--ios <suite>`, Release).
- Run the complete AidokuFull plan only when explicitly requested, required by a concrete release/CI check, or to
  investigate a demonstrated cross-cutting regression; state the reason first (no extra approval question needed).
- Compile only to validate changed compiled sources/build settings or to produce a requested app. Documentation-only
  changes need no build or test run.
- iOS builds and tests have no default deadline (`--seconds` sets an explicit one). The host runner has a 55-second
  default; a timeout (exit 124) is incomplete, never a pass, and zero executed iOS tests never pass.
- `test_quick.py` uses `xcodebuild test`, so sources are rebuilt; never substitute an old `test-without-building`
  result for new changes.

### Incremental builds (mandatory)

- Use `SWIFT_COMPILATION_MODE=singlefile`, keep Release `-O`, and `ONLY_ACTIVE_ARCH=YES` for simulator and
  single-device builds unless multiple architectures are required.
- Reuse fixed DerivedData per platform/configuration (`build/device-fast`, `build/simulator-fast-{debug,release}`)
  with consistent compiler/signing options; never run concurrent builds on one cache.
- Never `clean`, delete DerivedData or force a full rebuild by default; do so only for demonstrated cache corruption,
  an explicit clean-build request or a reproducibility requirement, stating the reason first. Use `wholemodule` only
  for mode-specific diagnosis, representative performance validation or a distribution requirement.
- Device Release builds: `Scripts/build_device_release.py` (`--full-optimization` is an exception with its own cache).
- Report build and test times separately, distinguishing no-change builds from incremental ones.

### Tests

Follow `Scripts/TESTING.md`: keep condition-based waits, controlled retry clocks, fresh documents in reusable
browser fixtures and isolated VM contexts with cached compilation. Heavy integration, benchmark and external-fixture
suites stay in opt-in AidokuFull. Do not weaken assertions, change production retry delays or silently omit
requested tests. Use Swift Testing (`import Testing`, `@Test`), `*Tests.swift` files, descriptive behavior names,
and add regression coverage for behavior fixes.

Patched packages: run `swift test --jobs 2` in a checkout of the Nuke or AidokuRunner fork; hoshidicts' sanitizer
regressions are in its `Tests/AidokuRegression`. Blocking-task priority: `Scripts/tests/run-blocking-priority-regression.py`.

## Lint conventions (`.swiftlint.yml`)

- Indent with 4 spaces, never tabs. Comments start with `// `.
- Float literals without a trailing `.0` (`1`, not `1.0`; the `point_zero` rule).
- Prefer implicit returns. Lines warn at 150 characters and error at 200.
- `Aidoku/Core/Translation/NativeEngine` and `AidokuTests/Translation/NativeEngine` are excluded from linting.
- `UpperCamelCase` types, `lowerCamelCase` members; name files after their primary type or extension.

## Architecture

- `Aidoku/App`: delegates, navigation, resources (localization in `App/Resources/Localization`).
- `Aidoku/Core`: non-UI services by domain (Sources, Database, Downloads, Tracking, Backup, Library, Settings,
  Dictionary, Translation, Network). `Aidoku/Features`: screens. `Aidoku/Extensions`: framework extensions.
- `Aidoku/Resources/Translation`: V2 Core ML models, dictionaries and the serif font.

**Sources.** `SourceManager` owns every installed source as an `AidokuRunner.Source`. `.aix` packages run their
`main.wasm` on the AidokuRunner interpreter; 0.6-API packages run on the legacy runtime in `Core/Sources/Legacy`.
`SourcePackageExtractor` unpacks packages with entry and size limits; requests use `NativeSourceNetwork`. Built-in
providers (`Core/Sources/BuiltIn`): Local CBZ, Komga, Kavita, Suwayomi. WebKit remains only for browser-dependent
authentication, challenges and user-agent discovery (`Docs/native-source-auth.md`).

**Persistence.** Core Data behind `CoreDataManager`, one extension file per entity; model `Aidoku.xcdatamodeld`.

**Patched dependencies.** AidokuRunner, Nuke and hoshidicts are patched forks on the `aidoku` branch of
`github.com/qwopqwop200/{AidokuRunner,Nuke,hoshidicts}`, each with an `AIDOKU_PATCHES.md`. Change them in the fork,
push, then update `Package.resolved`; keep C headers and implementations in sync.

**Translation** (`Core/Translation`, `Features/Reader/Translation`) has one pipeline, V2 (`Core/Translation/V2`,
`Docs/translation-v2.md`). `ReaderTranslationV2Service` runs pages and translated downloads through `V2Pipeline`
(S1 RF-DETR layout || S2 PP-OCRv6 detection, S3 recognition, S4 grouping, S5 one provider request per page,
S6 removal mask, S7 AOT inpainting, S8 style, S9 layout, S10 Core Text paint); results are cached under `v2-` keys in
`ReaderTranslationDiskCache`. `NativeEngine/OCR` supplies the detector and recognition helpers; `NativeEngine/Translation`
the OpenAI-compatible clients, endpoint policy and Keychain credentials, also used for metadata translation. The
dictionary popup is upstream's `PopupWebView`. The old Web renderer and JS/WASM comparison harnesses were removed;
do not restore them as oracles. Verify paint at source coordinates and keep pixels outside the removal mask intact.

**Share extension.** `AidokuShare` hands images to the app via an app group and URL scheme set in
`Aidoku/Aidoku.xcconfig`, which also sets bundle IDs and the `CANONICAL_BUILD` flag.

Check reachability from the app, host tools, asset packaging and validation commands before removing code.

## Localization rules

New UI strings use `NSLocalizedString` with an English entry in `en.lproj` and a Korean one in `ko.lproj`, in both
`Localizable.strings` and `InfoPlist.strings`; `AidokuShare` has its own en/ko `Localizable.strings`. Leave other
locales as upstream ships them (missing keys fall back to English). Do not localize stored setting values, provider
or API protocol names, or font identifiers, only their display labels. Use positional arguments (`%1$@`) when a
translation reorders them. The validator fails on missing or extra keys, untranslated English and incompatible
format arguments.

## Image translation pipeline CLI

`swift Scripts/image-translation.swift` runs V2 on Apple Silicon macOS 15+, compiling the app's V2 stage files and
listed shared files into an incremental `-O` binary in `build/image-translation-v2`:

```sh
swift Scripts/image-translation.swift /path/to/page.png                 # live translation (default)
swift Scripts/image-translation.swift /path/to/images --jobs 3
swift Scripts/image-translation.swift --list /path/to/images.json
swift Scripts/image-translation.swift --ocr-only /path/to/page.png       # S1-S4, recognized blocks only
swift Scripts/image-translation.swift --split dev --limit 5 --replay-translations RUN_DIR   # no LLM
```

Live mode uses `V2Translation`/`RemoteTranslationClient` with the app's page settings (page image attached,
SFX/background filtering on, at most three concurrent requests); replay reads a legacy `page-index.json` run or a
V2 run. Settings come from the ignored `.env` (CLI > shell environment > `.env` > defaults; `AIDOKU_ENV_FILE=`
disables it). Never commit, print or copy credentials. `Scripts/image-translation/sync-iphone-settings.py --device
<DEVICE_ID> --bundle-id <BUNDLE_ID>` copies the installed app's provider/language settings into `.env`.

Runs write `pages/<page>.json`, `pages/<page>.png` (not with `--ocr-only`) and `summary.json` under
`../output/image-translation/run-<UUID>/`; exit 1 means a page failed, 2 invalid settings. Score with
`python3 Scripts/v2/eval.py RUN_DIR --split dev`. Never view page images; process pixels in code only, and keep
generated images, provider payloads and experiment logs out of Git. See `Scripts/image-translation/README.md`;
focused checks: `Scripts/tests/run-image-environment-smoke.py` (no models) and
`Scripts/tests/run-image-translation-smoke.py` (Core ML OCR, loopback mock provider).

## Commits

Use specific imperative subjects (e.g. `Stop cached translation renders from delaying visible pages`) and focused
commits. PRs describe the problem, resulting behavior, validation and limitations, with screenshots for UI changes.
