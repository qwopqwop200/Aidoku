# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Aidoku is an iOS/iPadOS/macOS manga reader (UIKit + SwiftUI, Core Data). This fork adds on-device PP-OCRv6 (Core ML) OCR and OpenAI / custom OpenAI-compatible page translation with native UIKit/Core Graphics/Core Text overlays.

## Build & test

The Xcode project `Aidoku.xcodeproj` has three targets: `Aidoku` (app, iOS 15+), `AidokuShare` (share extension), and `AidokuTests` (a hosted unit test bundle that runs inside `Aidoku.app`, deployment target 26.0). Use the shared `Aidoku` scheme. SwiftLint runs as an SPM build plugin.

### Default verification scope (mandatory)

- Run only fast tests by default: `python3 Scripts/test_quick.py` for relevant host checks, or `python3 Scripts/test_quick.py --fast-ios --device <UDID>` for Swift/iOS checks. Do not automatically run both when only one is relevant.
- Once relevant fast checks pass, stop verification. Do not append full tests, benchmarks, or repeated runs merely for reassurance or task completion.
- If changed behavior is outside AidokuFast, first run only the affected suite with `--ios <suite> --device <UDID> --configuration Release`. Selecting a suite from AidokuFull does not require running the entire plan.
- Run the complete AidokuFull plan only when explicitly requested, required by a concrete release/CI check, or necessary to investigate a demonstrated cross-cutting regression that focused tests cannot resolve. State the concrete reason before running it; ordinary edits and routine installs are not sufficient reasons. This does not require an extra approval question for already authorized work.
- Compile only when needed to validate changed compiled sources/build settings or produce a requested app. Documentation-only changes do not require app compilation or iOS tests.
- When compilation is needed, use incremental builds and existing caches. Never run `clean`, delete DerivedData, or force a full rebuild by default. Use a clean/full rebuild only for demonstrated cache corruption, an explicitly requested clean-build check, or a concrete reproducibility requirement, and state the reason first. Dependency/settings changes may naturally rebuild affected targets; do not proactively wipe caches.

### Mandatory incremental-build policy

Use incremental compilation by default for all development builds, tests, and Release installations.

- Set `SWIFT_COMPILATION_MODE=singlefile`; retain Release `-O`. Use `ONLY_ACTIVE_ARCH=YES` for simulator and single-device validation, except when multiple architectures are explicitly required.
- Reuse fixed DerivedData directories per platform/configuration and keep compiler/signing options consistent. Do not routinely clean, delete caches, create dated DerivedData directories, or force full recompilation after ordinary edits or installations. Never run concurrent builds against the same cache.
- Build current sources incrementally, then test or install that output. Use `test-without-building` only after confirming a successful build of the same sources/settings and no subsequent relevant changes.
- Do not impose an arbitrary iOS compilation, launch, or test deadline. An explicit user-requested deadline may be used; timeout is incomplete, never a pass. The host smoke runner's separate 55-second default does not apply to iOS.
- Use a clean/full rebuild only for a demonstrated need such as confirmed cache corruption or a reproducibility requirement. Use `wholemodule` only for mode-specific diagnosis, representative performance validation, or an explicit distribution requirement. Explain the concrete reason before taking the exception; Release installation alone is not a reason.
- Report build and test times separately, distinguishing no-source-change builds from incremental builds after edits.

Use `Scripts/build_device_release.py` for device Release builds and install its resulting app. Its `--full-optimization` option is an exception with a separate cache. Use `Scripts/test_quick.py --ios <suite> --device <UDID>` for focused tests; add `--configuration Release` when Release behavior matters. Default caches are `build/device-fast` and `build/simulator-fast-{debug,release}`.

Test-time optimization is also mandatory by default. Follow the optimized fixture
contracts and measured scope in `Scripts/TESTING.md` and `AGENTS.md`. Preserve
controlled retry clocks, condition-based waits, fresh documents in reusable browser
fixtures, and isolated VM contexts with cached compilation. The default AidokuFast plan intentionally excludes heavy integration, benchmark, and
external-fixture suites; keep their full coverage in opt-in AidokuFull. Do not
weaken assertions or silently omit explicitly requested tests.

For routine edits, start with `python3 Scripts/test_quick.py`. This runs the Python
tooling tests, localization validation and the model-free V2 host settings check with a **55-second
host-only deadline**. iOS compilation and testing have no default deadline. It does not compile or validate Swift/iOS behavior. A timeout is
an incomplete run (exit 124), never a pass. Full tests remain available below.

For routine Swift checks, use `python3 Scripts/test_quick.py --fast-ios --device <UDID>`
(Release, default AidokuFast). Xcode Cmd-U also uses AidokuFast. For targeted changes,
select affected suites explicitly from AidokuFull and reuse the same simulator
and DerivedData path; do not launch the entire suite for every small edit:

```sh
python3 Scripts/test_quick.py --ios TrackerSyncTests --device <simulator-UDID>

# Explicitly requested complete plans
python3 Scripts/test_quick.py --full-ios --device <UDID>
python3 Scripts/test_quick.py --full-host
```

This uses `xcodebuild test` so source changes are rebuilt before execution. iOS
runs have no default timeout: compilation, launch, and tests continue until completion.
Use `--seconds <positive-number>` only when an explicit total deadline is wanted. Never substitute
an old `test-without-building` result for validation of new source changes.
Use focused specialized suites for affected functionality; run the complete plan
only under the mandatory verification-scope exceptions above; a host-only pass is not evidence for Swift, OCR, WebKit or device behavior.

```sh
# Build (CI nightly builds an unsigned archive this way)
xcodebuild -scheme Aidoku -configuration Release archive -archivePath build/Aidoku.xcarchive \
  -skipPackagePluginValidation CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Exception only: full tests when justified by the policy above
# Prefer the fast runner or an affected suite for routine work
xcodebuild test -project Aidoku.xcodeproj -scheme Aidoku -testPlan AidokuFull -destination 'platform=iOS Simulator,name=<device>' -skipPackagePluginValidation
xcodebuild test ... -only-testing:AidokuTests/TrackerSyncTests
xcodebuild test ... -only-testing:AidokuTests/TrackerSyncTests/testSomething

# Lint (CI runs this on PRs)
swiftlint lint
```

Other test suites, each run from the repository root:

- **Localization** (CI): `python3 -m unittest discover -s Scripts -v` and `python3 Scripts/validate_localizations.py`. See `Scripts/LOCALIZATION.md`.
- **Host matrix**: `python3 Scripts/test_quick.py --full-host` runs `Scripts/tests/full-host-matrix.json` (V2 host smokes, OCR/translation contracts, blocking priority); see `Scripts/TESTING.md`.
- **Patched packages**: run `swift test --jobs 2` in a checkout of the Nuke or AidokuRunner fork; hoshidicts' sanitizer regressions are in its `Tests/AidokuRegression`. The blocking-task priority check is `python3 Scripts/tests/run-blocking-priority-regression.py`.

## Lint conventions (`.swiftlint.yml`)

- Indent with 4 spaces, never tabs. Comments start with `// ` (a space after the slashes).
- Write float literals without a trailing `.0` (`1`, not `1.0`). The `point_zero` custom rule enforces this.
- Prefer implicit returns. Lines warn at 150 characters and error at 200.
- `Aidoku/Core/Translation/NativeEngine` and `AidokuTests/Translation/NativeEngine` are excluded from linting.

## Architecture

- `Aidoku/App`: app and scene delegates, navigation, and shared resources. Localization tables live in `App/Resources/Localization`.
- `Aidoku/Core`: non-UI services, grouped by domain (Sources, Database, Downloads, Tracking, Backup, Library, Settings, Dictionary, Translation, Network).
- `Aidoku/Features`: screens (Reader, Library, Browse, Manga, Settings, and so on).
- `Aidoku/Extensions`: extensions to Apple and third-party types, organized by framework.

**Sources.** `SourceManager` (`Core/Sources/SourceManager.swift`) owns every installed source as an `AidokuRunner.Source`. Installed `.aix` packages run their `main.wasm` on the AidokuRunner interpreter; 0.6-API packages run on the legacy runtime in `Core/Sources/Legacy`. Packages are unpacked by `SourcePackageExtractor` with entry and size limits, and source requests use `NativeSourceNetwork` (shared source session, bounded bodies, Cloudflare handling). Built-in providers in `Core/Sources/BuiltIn` include Local CBZ, Komga, Kavita and Suwayomi. WebKit remains for browser-dependent authentication, interactive challenges and user-agent discovery; see `Docs/native-source-auth.md`.

**Persistence.** Core Data lives behind `CoreDataManager`, with one extension file per entity (`CoreDataManager+Chapter.swift` and so on). The model is `Aidoku.xcdatamodeld`.

**Patched dependencies.** AidokuRunner, Nuke, and hoshidicts (a native dictionary library) are **patched forks**, not pristine upstream: SwiftPM packages on the `aidoku` branch of `github.com/qwopqwop200/{AidokuRunner,Nuke,hoshidicts}`, each with an `AIDOKU_PATCHES.md`. Change them in the fork, push, then update `Package.resolved`. Keep C headers and implementations in sync. For changes to a patched package, run its package tests and relevant fast app checks. Run full app tests only under the verification-scope exceptions above.

**Translation pipeline** (`Core/Translation`, `Features/Reader/Translation`): page translation has one pipeline, V2 (`Core/Translation/V2`, `Docs/translation-v2.md`).
- `ReaderTranslationV2Service` runs pages and translated downloads through `V2Pipeline`: S1 RF-DETR layout || S2 PP-OCRv6 manga detection, S3 recognition, S4 grouping/roles, S5 one provider request per page, S6 removal mask, S7 AOT inpainting, S8 style, S9 layout, S10 Core Text paint. Models load lazily and are released on memory warnings; results are cached under `v2-` keys in `ReaderTranslationDiskCache`.
- `NativeEngine/OCR` supplies the Core ML detector and the recognition helpers (preprocessing, CTC decoding, n-gram) V2 reuses; models and dictionaries are in `Aidoku/Resources/Translation`.
- `NativeEngine/Translation` handles remote OpenAI-compatible clients, batching, endpoint policy and Keychain-stored credentials; `ReaderTranslationService.translateV2` applies the mandatory page settings and shared provider limit. Metadata (title/description/menu) translation uses the same client.
- The dictionary popup is upstream's web popup (`PopupWebView`, independent of page translation).

**Share extension.** `AidokuShare` hands images to the app through an app group and URL scheme defined in `Aidoku/Aidoku.xcconfig`. The xcconfig also sets bundle IDs and the `CANONICAL_BUILD` Swift flag.

## Localization rules

Any new UI string must use `NSLocalizedString`, with an English entry in `en.lproj` and a translation in **every** locale listed in the project's `knownRegions`. This applies to both `Localizable.strings` and `InfoPlist.strings`. `AidokuShare` has its own `Localizable.strings`. Do not localize stored setting values, provider names, API protocol names, or font family identifiers; localize only their display labels. When a translation reorders format arguments, use positional arguments (`%1$@`). The validator fails on missing or extra keys, English left untranslated, and incompatible format arguments.

## Image translation pipeline CLI

`swift Scripts/image-translation.swift` runs the app's only page-translation pipeline, V2 (`Aidoku/Core/Translation/V2`, `Docs/translation-v2.md`), on Apple Silicon macOS 15+ with the Xcode command-line tools. It compiles the same V2 stage files as the app plus an explicit list of shared app files into an incremental `-O` binary in `build/image-translation-v2`:

```sh
swift Scripts/image-translation.swift /path/to/page.png                 # live translation (default)
swift Scripts/image-translation.swift /path/to/images --jobs 3
swift Scripts/image-translation.swift --list /path/to/images.json
swift Scripts/image-translation.swift --ocr-only /path/to/page.png       # S1-S4, recognized blocks only
swift Scripts/image-translation.swift --split dev --limit 5 --replay-translations RUN_DIR   # no LLM
```

Live mode calls the real provider through `V2Translation` and `RemoteTranslationClient` with the app's mandatory page settings (page image attached, SFX/background filtering on, at most three concurrent page requests). Replay reads saved translations from a legacy `page-index.json` run or a V2 run. The runner reads this repository's ignored `.env`; precedence is CLI arguments > shell environment > `.env` > defaults (`AIDOKU_ENV_FILE=` disables it). Keep credentials in `.env`; never commit, print, or copy them into reports. `.env.example` contains no credential. `python3 Scripts/image-translation/sync-iphone-settings.py --device <DEVICE_ID> --bundle-id <BUNDLE_ID>` copies the installed app's provider/language settings into `.env` and preserves the key.

Each run writes `pages/<page>.json` (blocks, lines, translations, placement, timings, failure), `pages/<page>.png` (not in `--ocr-only`) and `summary.json` under `../output/image-translation/run-<UUID>/`. Exit status 1 means a page failed; 2 means invalid settings. Score runs with `python3 Scripts/v2/eval.py RUN_DIR --split dev`. Never view page images; process pixels in code only.

See `Scripts/image-translation/README.md` and `swift Scripts/image-translation.swift --help`. Focused checks are `python3 Scripts/tests/run-image-environment-smoke.py` (settings, no models) and `python3 Scripts/tests/run-image-translation-smoke.py` (real Core ML OCR and a loopback mock provider). Apply the existing verification-scope rules; documentation-only changes need no build or test run.
