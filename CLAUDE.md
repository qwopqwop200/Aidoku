# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Aidoku is an iOS/iPadOS/macOS manga reader (UIKit + SwiftUI, Core Data). This fork adds on-device PP-OCRv6 (Core ML) OCR and OpenAI / custom OpenAI-compatible page translation with WebKit-rendered overlays.

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

For routine edits, start with `python3 Scripts/test_quick.py`. This runs the host
smoke regressions (core source-color/readability, inpainting, column layout,
typography, inferred ruby, dictionary popup, Python tests and localization validation) with a **55-second
host-only deadline**. iOS compilation and testing have no default deadline. It does not compile or validate Swift/iOS behavior. A timeout is
an incomplete run (exit 124), never a pass. Full tests remain available below.

For routine Swift checks, use `python3 Scripts/test_quick.py --fast-ios --device <UDID>`
(Release, default AidokuFast). Xcode Cmd-U also uses AidokuFast. For targeted changes,
select affected suites explicitly from AidokuFull and reuse the same simulator
and DerivedData path; do not launch the entire suite for every small edit:

```sh
python3 Scripts/test_quick.py --ios TrackerSyncTests --device <simulator-UDID>
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
- **Overlay source color and inpainting regressions** (CI, Node 18+, no npm deps): `node Scripts/tests/<name>.cjs`. The full list with fixture arguments is in `.github/workflows/source-color.yml`. These runners **extract the JavaScript embedded in Swift string literals** (for example `static let script = """ ... """` in `BrowserSourceTextColor.swift`). If you change that JS, run them. If you reformat the literal's delimiters, the extraction regex breaks. Background and methodology are in `Scripts/tests/README-*.md`. `typography-clusters-regression.cjs` runs with `node --test`.
- **Webtoon screen tests** (real simulator screenshots): `python3 Scripts/run_webtoon_screen_tests.py --device <booted UDID> --bundle app.aidoku.Aidoku -- -project Aidoku.xcodeproj -scheme Aidoku -only-testing:AidokuTests/ReaderWebtoonLifecycleTests test`
- **Vendored packages**: `swift test --package-path Vendor/Wasm3` and `swift test --package-path Vendor/AidokuRunner`. Hoshi native regressions are `Scripts/tests/run-hoshi-*.py`. The blocking-task priority check is `python3 Scripts/tests/run-blocking-priority-regression.py`.

## Lint conventions (`.swiftlint.yml`)

- Indent with 4 spaces, never tabs. Comments start with `// ` (a space after the slashes).
- Write float literals without a trailing `.0` (`1`, not `1.0`). The `point_zero` custom rule enforces this.
- Prefer implicit returns. Lines warn at 150 characters and error at 200.
- `Aidoku/Core/Translation/NativeEngine` and `AidokuTests/Translation/NativeEngine` are excluded from linting.

## Architecture

- `Aidoku/App`: app and scene delegates, navigation, and shared resources. Localization tables live in `App/Resources/Localization`.
- `Aidoku/Core`: non-UI services, grouped by domain (Sources, Database, Downloads, Tracking, Backup, Library, Settings, Dictionary, Translation, Upscaling, Network).
- `Aidoku/Features`: screens (Reader, Library, Browse, Manga, Settings, and so on).
- `Aidoku/Extensions`: extensions to Apple and third-party types, organized by framework.

**Sources.** `SourceManager` (`Core/Sources/SourceManager.swift`) owns every installed source as an `AidokuRunner.Source`. External sources are WASM modules executed by `Vendor/AidokuRunner` on top of `Vendor/Wasm3`. `Core/Sources/Legacy` adapts the older source ABI. Built-in providers (Local CBZ, Komga, Kavita, Suwayomi) live in `Core/Sources/BuiltIn`.

**Persistence.** Core Data lives behind `CoreDataManager`, with one extension file per entity (`CoreDataManager+Chapter.swift` and so on). The model is `Aidoku.xcdatamodeld`.

**Vendored dependencies.** `Vendor/` contains AidokuRunner, Wasm3, and HoshiDicts (a native dictionary library). These are **locally patched forks**, not pristine upstream copies. Read `Vendor/README.md` before editing or updating them. Keep C headers and implementations in sync. For changes to a vendored package, run its affected package tests and relevant fast app checks. Run full app tests only under the verification-scope exceptions above.

**Translation pipeline** (`Core/Translation`, `Features/Reader/Translation`):
- `ReaderTranslationService` orchestrates per-page work: image preparation, OCR, balloon merging and panel ordering, remote translation, and disk caching (`ReaderTranslationDiskCache`, `ReaderTranslationCacheCodec`). `TranslationImageWorkBudget` bounds the image work.
- `NativeEngine/OCR` runs PP-OCRv6 Core ML detection and recognition. The models and character dictionaries are in `Aidoku/Resources/Translation`.
- `NativeEngine/Translation` handles remote OpenAI-compatible clients, batching, reuse identity, endpoint policy, and Keychain-stored credentials.
- `NativeEngine/Overlay` renders translated text in a WebKit view (`BrowserOverlayView`). Much of the source-color estimation, text erasure and inpainting, slanted-text restoration, and typography logic is **JavaScript embedded in Swift strings**. The Node regressions above test that JavaScript. The reader WebKit view, exported images (`ReaderTranslationImageExporter`), and native overlays share the same geometry (for example `BrowserOverlayRotation`).

**Share extension.** `AidokuShare` hands images to the app through an app group and URL scheme defined in `Aidoku/Aidoku.xcconfig`. The xcconfig also sets bundle IDs and the `CANONICAL_BUILD` Swift flag.

## Localization rules

Any new UI string must use `NSLocalizedString`, with an English entry in `en.lproj` and a translation in **every** locale listed in the project's `knownRegions`. This applies to both `Localizable.strings` and `InfoPlist.strings`. `AidokuShare` has its own `Localizable.strings`. Do not localize stored setting values, provider names, API protocol names, or font family identifiers; localize only their display labels. When a translation reorders format arguments, use positional arguments (`%1$@`). The validator fails on missing or extra keys, English left untranslated, and incompatible format arguments.
