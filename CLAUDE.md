# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Aidoku is an iOS/iPadOS/macOS manga reader (UIKit + SwiftUI, Core Data). This fork adds on-device PP-OCRv6 (Core ML) OCR and OpenAI / custom OpenAI-compatible page translation with WebKit-rendered overlays.

## Build & test

The Xcode project `Aidoku.xcodeproj` has three targets: `Aidoku` (app, iOS 15+), `AidokuShare` (share extension), and `AidokuTests` (a hosted unit test bundle that runs inside `Aidoku.app`, deployment target 26.0). Use the shared `Aidoku` scheme. SwiftLint runs as an SPM build plugin.

```sh
# Build (CI nightly builds an unsigned archive this way)
xcodebuild -scheme Aidoku -configuration Release archive -archivePath build/Aidoku.xcarchive \
  -skipPackagePluginValidation CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Run all tests / one class / one method on a simulator
xcodebuild test -project Aidoku.xcodeproj -scheme Aidoku -destination 'platform=iOS Simulator,name=<device>' -skipPackagePluginValidation
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

**Vendored dependencies.** `Vendor/` contains AidokuRunner, Wasm3, and HoshiDicts (a native dictionary library). These are **locally patched forks**, not pristine upstream copies. Read `Vendor/README.md` before editing or updating them. Keep C headers and implementations in sync. Run the package tests and the app tests after any change.

**Translation pipeline** (`Core/Translation`, `Features/Reader/Translation`):
- `ReaderTranslationService` orchestrates per-page work: image preparation, OCR, balloon merging and panel ordering, remote translation, and disk caching (`ReaderTranslationDiskCache`, `ReaderTranslationCacheCodec`). `TranslationImageWorkBudget` bounds the image work.
- `NativeEngine/OCR` runs PP-OCRv6 Core ML detection and recognition. The models and character dictionaries are in `Aidoku/Resources/Translation`.
- `NativeEngine/Translation` handles remote OpenAI-compatible clients, batching, reuse identity, endpoint policy, and Keychain-stored credentials.
- `NativeEngine/Overlay` renders translated text in a WebKit view (`BrowserOverlayView`). Much of the source-color estimation, text erasure and inpainting, slanted-text restoration, and typography logic is **JavaScript embedded in Swift strings**. The Node regressions above test that JavaScript. The reader WebKit view, exported images (`ReaderTranslationImageExporter`), and native overlays share the same geometry (for example `BrowserOverlayRotation`).

**Share extension.** `AidokuShare` hands images to the app through an app group and URL scheme defined in `Aidoku/Aidoku.xcconfig`. The xcconfig also sets bundle IDs and the `CANONICAL_BUILD` Swift flag.

## Localization rules

Any new UI string must use `NSLocalizedString`, with an English entry in `en.lproj` and a translation in **every** locale listed in the project's `knownRegions`. This applies to both `Localizable.strings` and `InfoPlist.strings`. `AidokuShare` has its own `Localizable.strings`. Do not localize stored setting values, provider names, API protocol names, or font family identifiers; localize only their display labels. When a translation reorders format arguments, use positional arguments (`%1$@`). The validator fails on missing or extra keys, English left untranslated, and incompatible format arguments.
