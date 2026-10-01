# Native source migration: second independent audit

> Later integration: translation overlays, image export, dictionary popups and
> translation pixel kernels now use the native renderer. The historical scope
> and measurements below describe the source-runtime migration at its recorded
> revision. Browser-dependent authentication/challenges still use WebKit. See
> [the current runtime map](native-runtime.md).

Date: 2026-09-30. Worktree: `worktrees/native-source-auth`.
Branch: `codex/native-source-auth`, base `14627f57`.

The requested second audit used 16 new agents: one for each of the 12 recovered
source identities, and four for runtime/serialization, import/integration,
authentication and Cloudflare. These reviewers were separate from the initial
implementation and first eight-agent review. Production fixes followed concrete
source comparisons, paused-request reproductions or public response evidence.
Builds and simulator tests were coordinated serially by the root agent.

## Findings and fixes

| Independent reviewer | Confirmed finding and final change |
| --- | --- |
| MangarawBest v2 | Prefer chapter numbers after `第` over earlier years in the title; restrict deep links to HTTP(S). |
| MangarawJP v2 | Correct asymmetric tile placement and top-origin/Core Graphics conversion; reproduce omitted `c`/`e` defaults while rejecting explicit null. Full pixel references include odd dimensions and 3×3 tiles. |
| Rawdevart v3 | Preserve existing cover when the API omits it; reject non-HTTP(S) and credential-bearing deep links. |
| Rawkuma v6 | Read sibling hero genre links; discard incomplete search/listing cards as upstream does. |
| RawOtaku v2 | Clear absent author/artist data; resolve reader links and identifier-free home chapters against the Japanese chapter list. A real English wrapper ID returned unrelated images. |
| SenManga v2 | No confirmed normal-input defect. Independently checked metadata, search, pagination, nullable details, chapter migration and public API responses. |
| SoraRaw v5 | Read dimensions from bounded partial JPEG/VP8 headers so 206 responses retain stacked-page slicing; bind partial publication to the originating subscription. |
| SpoilerPlus v1 | Preserve HTML line breaks, omitted chapter keys and cancellation; normalize chapter deep links; bind partial publication and prevent pending responses repopulating cleared caches. |
| Yomii v7 | Restore protocol-relative/root-relative images using the backed-up module's fixed base; reset stale genre/sort filters when textual search is active. Actual reader HTML previously lost all relative image URLs. |
| E-Hentai v2 | Skip an independently malformed home section while retaining other results; propagate cancellation. |
| Hitomi v2 | Prevent pre-clear pending responses repopulating gallery, GG, version and B-tree caches; preserve local GG routing during concurrent cache clearing. |
| nhentai v17 | Reject cancellation before initial partial home emission; use the canonical gallery key for chapter keys, URLs and caching. |
| Runtime / serialization | Preserve dynamic base-URL cancellation. Repair retained Postcard dictionary decoding, strict discriminants, cumulative allocation/work budget and negative numeric-key encoding. Preserve existing nonnegative wire bytes. |
| Import / integration | Prevent obsolete loads from undoing disable/remove/update/reload decisions using per-source and snapshot ownership. At the UI boundary, revoke queued partial results and stale final responses across replacement loads, refreshes and source changes; guard downloaded/history state before commit. A replacement refresh completes initial readiness even on error. |
| Authentication | Compare raw OAuth callback paths; preserve raw percent-encoded cookie path scope and trailing slash semantics. |
| Cloudflare | Atomically guard browser effects on MainActor, reserve one popup, invalidate before dismissal, remove hidden-size constraints and commit only scoped Cloudflare verification cookies so stale browser exports cannot overwrite account cookies. |

The root also repaired the existing translation digest test's stale revision
oracle from `reader-render-v116-source-restoration-geometry` to the production
`reader-render-v119-small-caption-inpainting`. Production cache revisions and
the test's key comparisons were retained. This resolves the separately recorded
first-round Fast failure rather than counting it as a source migration defect.

## Execution evidence

- Package: `swift test --package-path Vendor/AidokuRunner --jobs 2` passed **22 tests in 4 suites** after the final runtime/serialization fixes. Build 7.25 seconds, test body 0.004 seconds, root-measured total 8.295 seconds. Log: `/tmp/aidoku-reaudit-package.log`.
- The first second-audit Fast run executed **1,034 tests in 194 suites** and failed with four assertion issues in three test methods. RawOtaku's request fixture/oracle used `URL.path`, which drops a terminal slash on iOS; `URLComponents.path` now preserves and explicitly verifies it. The remaining issue reproduced a real SpoilerPlus newline defect: SwiftSoup serializes `<br />`, while the helper only replaced `<br>`. Both serializations now preserve breaks; the strict expected description remains unchanged. Log: `/tmp/aidoku-reaudit-fast-tests.log`. Test body 17.082 seconds; total 47.318 seconds.
- Final Release `build-for-testing` passed after the last fixes, using `-O`, `SWIFT_COMPILATION_MODE=singlefile`, `ENABLE_TESTABILITY=YES`, `ONLY_ACTIVE_ARCH=YES` and the existing `build/simulator-fast-release` cache. Incremental build: **26.248 seconds**, log `/tmp/aidoku-reaudit-build-final.log`. No clean/cache deletion or parallel cache builds were used.
- Final `test-without-building -testPlan AidokuFast` passed **1,034 Swift Testing tests in 194 suites** on the iOS 26.5 iPhone 17 Pro simulator `AA441ADA-456B-41F8-B643-ECBF93AC0718`. Test body: **15.980 seconds**; startup plus execution: **21.386 seconds**, exit code 0 and `TEST EXECUTE SUCCEEDED`. Log: `/tmp/aidoku-reaudit-fast-final.log`. All 15 new second-audit suites, all-12 backup metadata loading, source routing, earlier migration regressions and the repaired digest oracle passed. This is the Fast plan, not the Full plan.
- Localization validation passed: 41 locales, 40,959 entries and 918 literal Swift keys. `git diff --check` passed. App binary symbol inspection found no `Wasm3`, `wasm3` or `_m3_` interpreter symbols.

The 15 new app regression suites are explicitly selected in AidokuFast. Package
regressions are in the existing model-coding and native-registry suites. The
original source tests remain; only the independently identified stale digest
oracle was corrected. No account credentials, stored preferences or login
cookies were read for this audit.

## Provenance and limits

All 12 exact source IDs/versions, manifests, filters and settings were checked
against the actual recovered backup metadata. Eleven ports use matching upstream
revision `897b8f2102b48c722f438c10373d1cb5e10876cb`; Yomii uses static recovered
module control flow, including image URL function 58 and textual-search function
124. Static decompilation is not execution of the removed source runtime.
Public GET/HEAD evidence was obtained for several providers; site availability
and all live branches are not established by fixture tests.

No physical iPhone installation, live account login or interactive Cloudflare
solve was performed. Hitomi aggregate peak memory and complete historical Yomii
branch equivalence remain unmeasured. MangarawJP still omits query/fragment from
returned keys, rejects non-square/duplicate/oversized tile grids and non-upright
images; no normal-input impact was demonstrated for those retained limits.
SenManga retains minor upstream differences in terminal URL slashes, repeated
chapter-prefix handling and omitted partial publication; its checked normal API
responses matched the final adapter. The app still uses WebKit for hosted login
and interactive challenges, and translation/dictionary WebKit and translation
pixel-kernel WebAssembly remain outside the source-runtime removal. Source WASM
execution and its fallback remain removed; unsupported source versions are
explicitly rejected.
