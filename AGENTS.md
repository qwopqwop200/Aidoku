# Repository Guidelines

## Project Structure & Module Organization

Work from this directory, the Git root containing `Aidoku.xcodeproj`; the parent directory holds datasets and generated reports. Aidoku uses Swift, UIKit, SwiftUI, and Core Data.

- `Aidoku/App`: lifecycle, navigation, and localized resources.
- `Aidoku/Core`: sources, persistence, networking, OCR, and translation services.
- `Aidoku/Features` and `Aidoku/Extensions`: screens and framework extensions.
- `Aidoku/Resources/Translation`: OCR models and dictionaries.
- `AidokuShare`: share extension; `AidokuTests`: app-hosted tests.
- `Scripts`: native host tooling and regression tests; `Vendor`: patched dependencies. Read `Vendor/README.md` before modifying them.

## Build, Test, and Development Commands

Use Xcode with the shared `Aidoku` scheme. Select a simulator or configure signing for a physical device, then Run.

```sh
# Optimized unsigned archive
xcodebuild -scheme Aidoku -configuration Release archive \
  -archivePath build/Aidoku.xcarchive -skipPackagePluginValidation \
  CODE_SIGN_IDENTITY= CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO

# Default fast simulator tests
python3 Scripts/test_quick.py --fast-ios --device <UDID>

# Affected suite only, when the fast plan does not cover the change
python3 Scripts/test_quick.py --ios TrackerSyncTests --device <UDID> --configuration Release

# Explicitly requested complete plans
python3 Scripts/test_quick.py --full-ios --device <UDID>
python3 Scripts/test_quick.py --full-host

swiftlint lint
python3 -m unittest discover -s Scripts -v
python3 Scripts/validate_localizations.py
```

### Default verification scope (mandatory)

- Run only fast tests by default: `python3 Scripts/test_quick.py` for relevant host checks, or `python3 Scripts/test_quick.py --fast-ios --device <UDID>` for Swift/iOS checks. Do not automatically run both when only one is relevant.
- Once relevant fast checks pass, stop verification. Do not append full tests, benchmarks, or repeated runs merely for reassurance or task completion.
- If changed behavior is outside AidokuFast, first run only the affected suite with `--ios <suite> --device <UDID> --configuration Release`. Selecting a suite from AidokuFull does not require running the entire plan.
- Run the complete AidokuFull plan only when explicitly requested, required by a concrete release/CI check, or necessary to investigate a demonstrated cross-cutting regression that focused tests cannot resolve. State the concrete reason before running it; ordinary edits and routine installs are not sufficient reasons. This does not require an extra approval question for already authorized work.
- Compile only when needed to validate changed compiled sources/build settings or produce a requested app. Documentation-only changes do not require app compilation or iOS tests.
- When compilation is needed, use incremental builds and existing caches. Never run `clean`, delete DerivedData, or force a full rebuild by default. Use a clean/full rebuild only for demonstrated cache corruption, an explicitly requested clean-build check, or a concrete reproducibility requirement, and state the reason first. Dependency/settings changes may naturally rebuild affected targets; do not proactively wipe caches.

### Mandatory Build-Speed Policy

Use incremental compilation by default for all development builds, tests, and Release installations.

- Set `SWIFT_COMPILATION_MODE=singlefile`; retain Release `-O`. Use `ONLY_ACTIVE_ARCH=YES` for simulator and single-device validation, except when multiple architectures are explicitly required.
- Reuse fixed DerivedData directories per platform/configuration and keep compiler/signing options consistent. Do not routinely clean, delete caches, create dated DerivedData directories, or force full recompilation after ordinary edits or installations. Never run concurrent builds against the same cache.
- Build current sources incrementally, then test or install that output. Use `test-without-building` only after confirming a successful build of the same sources/settings and no subsequent relevant changes.
- Do not impose an arbitrary iOS compilation, launch, or test deadline. An explicit user-requested deadline may be used; timeout is incomplete, never a pass. The host smoke runner's separate 55-second default does not apply to iOS.
- Use a clean/full rebuild only for a demonstrated need such as confirmed cache corruption or a reproducibility requirement. Use `wholemodule` only for mode-specific diagnosis, representative performance validation, or an explicit distribution requirement. Explain the concrete reason before taking the exception; Release installation alone is not a reason.
- Report build and test times separately, distinguishing no-source-change builds from incremental builds after edits.

Use `Scripts/build_device_release.py` for device Release builds and install its resulting app. Its `--full-optimization` option is an exception with a separate cache. Use `Scripts/test_quick.py --ios <suite> --device <UDID>` for focused tests; add `--configuration Release` when Release behavior matters. Default caches are `build/device-fast` and `build/simulator-fast-{debug,release}`.

## Coding Style & Naming Conventions

Use four spaces, `// ` comments, implicit returns where appropriate, and floating-point literals without unnecessary `.0`. Follow `.swiftlint.yml`: line lengths warn at 150 characters and error at 200. Use `UpperCamelCase` types and `lowerCamelCase` members; name files after their primary type or extension responsibility.

## Testing Guidelines

Use the optimized test workflow documented in `Scripts/TESTING.md`. Start routine host checks with `python3 Scripts/test_quick.py`; for routine Swift checks use `--fast-ios --device <UDID>` (Release, AidokuFast). The shared Aidoku scheme defaults to AidokuFast. Use `--ios <suite> --device <UDID>` for explicit affected suites (AidokuFull), or `-testPlan AidokuFull` for exhaustive integration/performance validation. iOS compilation, launch, and tests have no default time limit. The 55-second default applies only to host smoke checks; `--seconds` is an explicit optional override. Timeout means incomplete; zero executed iOS tests must never pass. Broaden only under the mandatory verification-scope exceptions above; prefer a focused affected suite before AidokuFull.

Preserve the optimized fixture helpers: condition-based waits and controlled retry clocks. Keep assertions and fixture matrices intact. Heavy integration, benchmark, and external-fixture suites belong in opt-in AidokuFull rather than the routine AidokuFast plan; do not silently omit explicitly requested tests. Keep production retry delays unchanged. Record build, startup/test execution, and test-body timings separately. Verified timings and coverage limits are in `Scripts/TESTING.md`.

Follow existing Swift Testing suites (`import Testing`, `@Test`), using descriptive behavior names and `*Tests.swift` filenames. Run affected native suites for Swift/Rust changes. Add regression coverage for behavior fixes. Report simulator, physical-device, and host-only validation separately; no numeric coverage threshold is prescribed here.

## Commit & Pull Request Guidelines

History mixes terse fixes with descriptive imperative subjects; prefer specific subjects such as `Stop cached translation renders from delaying visible pages`. Keep commits focused. PRs should describe the problem, resulting behavior, validation commands and results, and remaining limitations. Link relevant issues and include screenshots for visible UI changes.

## Localization & Configuration

Use `NSLocalizedString` for UI text and update every supported locale, including share-extension strings when affected. Preserve format placeholders. Keep credentials out of source and logs; bundle identifiers and app groups are configured in `Aidoku/Aidoku.xcconfig`.

## Image translation pipeline CLI

For quick image translation/OCR analysis, use `Scripts/image-translation.swift` directly on Apple Silicon macOS 15+ with Xcode command-line tools and Rust (`rustc`). From this Git root, passing only an image, image list, or folder runs the production Core ML OCR, recovery/grouping, remote translation and native Core Graphics/Core Text renderer:

```sh
swift Scripts/image-translation.swift /path/to/page.png
swift Scripts/image-translation.swift /path/to/images
swift Scripts/image-translation.swift --list /path/to/images.json
swift Scripts/image-translation.swift --ocr-only /path/to/page.png
```

The runner automatically reads this repository's ignored `.env`, including the API key and the actual installed iPhone settings imported into it. Defaults are a saved phone snapshot, not the app's factory settings or a live phone query on every run. Precedence is CLI arguments > shell environment > `.env` > built-in fallbacks. Keep credentials in `.env`; never commit, print, or copy them into reports. `.env.example` contains no credential. Refresh the snapshot from a connected phone with:

```sh
python3 Scripts/image-translation/sync-iphone-settings.py --device <DEVICE_ID> --bundle-id <INSTALLED_AIDOKU_BUNDLE_ID>
```

This reads the installed app's preferences and preserves the existing local API key. It imports protocol/reasoning, languages, image/filter flags, OCR model/sizes/confidence/detector thresholds, and supported overlay appearance settings. Scheduling/cache preferences are retained as provenance; this CLI uses bounded image workers (default `AIDOKU_IMAGE_JOBS=8`, overridden by `--jobs N`), overlaps translation across images, and uses the production layout planner with AppKit/Core Text font metrics. OCR and rendering each retain one admission slot. Supply the actual reader container with `--viewport WIDTHxHEIGHT` or `AIDOKU_RENDER_VIEWPORT`; the 430x932 default is portrait screen geometry, not a live reader measurement. Image-attached provider calls are capped at three. Bundled serif fonts are registered with Core Text; source restoration and mask/PDF composition use the production native renderer and original Rust kernels compiled as a native static library; macOS font metrics and iPhone performance/pixel output can still differ.

Runs save numbered intermediate JSON, OCR/stage PNGs, detector probability maps, native restoration masks and repaired crops, final JSON/PDF/PNG and a static HTML preview, and an interactive `analysis-index.html` under `../output/image-translation/run-<UUID>/`. Open the analysis report to inspect OCR text/confidence, reading direction, geometric angles, recovery/merging, balloon interiors, segmentation and final rendering. OCR-only runs have no renderer masks. `final.html` displays the saved PNG; opening it does not execute an overlay renderer. Native repair-alpha diagnostics record actual repair patches, not the former JavaScript glyph-mask instrumentation. Rebuild reports from existing output without running OCR or a server:

```sh
swift Scripts/image-translation.swift --visualize-run /path/to/run-UUID
```

Final composites are also collected in `RUN_DIRECTORY/final/`. Use `swift Scripts/image-translation.swift --render-run RUN_DIRECTORY` to recompose completed results from saved render payloads without OCR/API calls. Use `--resume-run RUN_DIRECTORY` with the same image inputs/order/settings to retain completed native results and continue an interrupted run. Completed historical browser renders are recomposed from saved inputs with the native renderer, without OCR/API calls.

See `Scripts/image-translation/README.md` and `swift Scripts/image-translation.swift --help` for all options. Focused checks are `python3 Scripts/tests/run-image-environment-smoke.py`, `python3 Scripts/tests/run-image-analysis-smoke.py`, and `python3 Scripts/tests/run-image-translation-smoke.py` (real host OCR/rendering and a local mock server). Apply the existing verification-scope rules; documentation-only changes need no build or test run. The launcher reuses its incremental Swift/Core ML cache in `build/image-translation-host`.

The previous Web renderer, JavaScript/WASM comparison harnesses, and their tests have been removed at the user’s request. Validate the native runtime directly; do not restore legacy renderer oracles.
