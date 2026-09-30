# Native source and authentication migration

## Checkout and scope

Implementation is isolated in `worktrees/native-source-auth`, based on commit
`14627f57`. Existing uncommitted changes in the original checkout are excluded.
The current original checkout's `AGENTS.md` policy applies to this work; its file is not part of the migration diff.

The corrected scope removes source WASM execution and replaces all recovered
installed sources with compiled Swift adapters. Unknown source identities or
versions must fail explicitly instead of falling back to WASM. Browser-dependent
provider authentication remains a separate compatibility boundary: a native
coordinator around a web authentication session does not make the hosted page
native. Translation and dictionary rendering are outside this migration.

## Baseline dependency inventory

| Area | Dependency and responsibility |
| --- | --- |
| Modern external source runtime | `Vendor/AidokuRunner` uses local `Vendor/Wasm3`; `Interpreter.swift` executes modules. Imports bridge networking, HTML, JavaScript and canvas operations. |
| Legacy source runtime | `Aidoku/Core/Sources/Legacy/Source.swift`, `SourceActor.swift`, `Wasm/Imports` and `WasmGlobalStore.swift` retain the older Wasm3 ABI. |
| Source JavaScript | AidokuRunner `Imports/JavaScript.swift` and `Utilities/IsolatedJSContext.swift` use JavaScriptCore; `Utilities/WebViewHandler.swift` handles browser execution. |
| Source browser imports | Legacy `Wasm/Imports/WebView/WebViewViewController.swift` and AidokuRunner `WebViewHandler.swift` remain required for modules requesting browser features. |
| Login settings | `Aidoku/App/Common/Settings/WebView.swift` implements generic cookie-based web login; `SettingView.swift` owns token exchange and attempt state. |
| OIDC setup | `Features/Browse/SourceSetup/OIDCLoginView.swift` originally captured cookies from an embedded login page after an `aidoku:` navigation. |
| Cloudflare | `Core/Sources/Cloudflare/CloudflareHandler.swift` originally detects a limited HTML challenge, loads WebKit, obtains clearance cookies and retries through `SourceNetwork`. |
| Shared source transport | `Core/Network/SourceNetwork.swift` provides URLSession transport and the optional iOS 17+ HTTPS proxy; its WebKit configuration is needed by compatibility views. |
| Outside this migration | Translation overlay/export and dictionary popup still use WebKit; embedded overlay pixel kernels also contain WebAssembly. |

`AidokuRunner.Runner` already allows compiled Swift implementations. Existing
Local, Komga, Kavita and Suwayomi sources demonstrate this path. A downloaded
WASM module cannot be converted to an equivalent native source simply by changing
its file extension or runtime factory: each adapter must reproduce that source's
protocol, models, filters, listings, image request headers and update semantics.

## Native runtime boundary

Native registrations must match source identity, source version and configuration
explicitly. Unknown identities and versions must report an unsupported-source
error. Registered native factory errors propagate; there is no WASM fallback.
Import and database reload must make the same decision. Baseline Wasm3 inventory
above records what must be disconnected, not permitted runtime compatibility.

`NativeSourceRunnerRegistry` registers an explicit source key and version set
with a runner factory. Registration overlap is rejected atomically; lookup
releases the registry lock before invoking the factory. The native loader keeps
manifest metadata and can select a supported adapter without an executable.
Fixture versions in package tests are not live source support claims.

## Recovered installed source inventory

A metadata-only inventory scanned 862 `source.json` and `.aix` files under the
original checkout's `output` tree, yielding 12 identities and 14 unique
manifest/executable hash pairs with zero decode errors. No preferences, tokens,
cookies or credentials were read. Freshness below is filesystem modification
time, not proof of capture chronology. Repeated backups cannot establish native
adapter parity by themselves.

| Source | Version | Manifest SHA-256 | Executable SHA-256 | Copies |
| --- | --- | --- | --- | --- |
| `ja.mangarawbest` | 2 | `cf3e0287679e4907706f4dbcc6af54b7a0700caed0a5b78db6c0338cbb1e83b7` | `405eb3d5110d37359ef21e64306f06e97abbd330051d0f18c79c9604cb06930d` | 63 |
| `ja.mangarawjp` | 2 | `91a4d52cc2e1ac8c3848002905daaf139425a318dea7942c8c98264a06b81a14` | `4f76b92f9720bc0ebeaa63edc7659993d9275fcac40bd757ea48fbc63f85a03c` | 63 |
| `ja.rawdevart` | 3 | `f1d64b8efab5b5b522fad60271f85fce19bb76d07c52fdb1ce9b4244a483e5d3` | `a24ebc2e491d0dde22f2602a3c0db5c32e517df8254ad6f856ddfa71571b950d` | 63 |
| `ja.rawkuma` | 6 | `b905bc2ca3769e02940565eaf6faf2e9fab4b2791091de1f3c59aa4395fcce58` | `4fe3b13606267648218b6e264c0c7ca93d807166b29e9b0409e9814fc535ef1a` | 63 |
| `ja.rawotaku` | 2 | `911abd9a7c0734e0f2054d132c8925457a3790fd057b4b9bb50fc4393650185e` | `bdeb9d742df8123ba8e29ab669e00363dd063dd0ec103d31e97aed8dfe7a54ac` | 63 |
| `ja.senmanga` | 2 | `bf3e35800ad0926a60dbbe126023a592314d403319b694c15495e13bddeda5aa` | `30fba4d1da10874cce11dd2dd486900eecf75a5f47d99caa43b081a302d202b5` | 63 |
| `ja.soraraw` | 5 | `d6f731606e827d9f4075caf6260b3ae0c9e96d2c15fdf5c7dd5f46b7a471724c` | `9c0b43a9689993038584e4a802f7ee4f1297756edf5565d045d3b667a04e1f57` | 63 |
| `ja.spoilerplus` | 1 | `62917fa3cd5159084a441b1c04339cdcea7ef3d473e2f7597ed537a4f21316e4` | `d1851fc2ce0a24e645935d064095276bfce90cdd562d34119fcf842cbf02cfe3` | 63 |
| `ko.yomii` | 7 | `a0d5bb4ea74436203751b3be37a941850fbccb28fa578bca903180c03ee0ed19` | `d1fa9dbcb1167d2e54356888daafad693b292b165e9aa76d35968b158766a670` | 63 |
| `multi.ehentai` | 2 | `e53c2a7aa6957fc43c19fb9db965162b39b3f8ba073b2ef3f68a02ec6424cc95` | `cc87cafb94c179eeb067e92bf2190d6cb6ca91b58ef917408bc7f053754bc6d3` | 63 |
| `multi.hitomi` | 2 | `3d30ac30cbe182ef38ce56ecf91776689f17c6cb33c370c25e1e4c6483500446` | `c94e70114697ad318356d31e3003bdb90887ce307b1740e030633036dd7bfe48` | 52 |
| `multi.hitomi` | 2 | `3d30ac30cbe182ef38ce56ecf91776689f17c6cb33c370c25e1e4c6483500446` | `ac7bf949b9c3f3ace416ea20f5ad18c0694c15d83c6c1d62d20df2a1faac7d40` | 63 |
| `multi.hitomi` | 2 | `3d30ac30cbe182ef38ce56ecf91776689f17c6cb33c370c25e1e4c6483500446` | `c9b0f184d12bdfa2f706f85ae612e14f4238e0cbdccf43f1c046e6ec0bbb763d` | 2 |
| `multi.nhentai` | 17 | `2321d4c01d07a7852ac631aac39d02a702a6b814887ce2946a8450cb101a8992` | `eb39593169a6f9540a8678c7a2898ceeebb85aa30ddf604679a71d5c7cb341b1` | 115 |

Latest installed payloads by filesystem mtime are under
`output/pipeline-speed-0929/depth-after/ApplicationSupport/Sources/<id>/`.
The Hitomi `.aix` variants include
`output/cache-install-0930/after/Documents/Inbox/source-autocomplete.aix` and
`output/reader-loading-0929/multi.hitomi-v2-reader-loading.aix`.
The newest nhentai archive by mtime is
`output/iphone-v76-install/before/Documents/multi.nhentai-v17-autocomplete.aix`.
Complete safe installed source metadata and hashes are retained in
`AidokuTests/Fixtures/NativeSourceBackupMetadata.json`. It contains manifests,
filter/settings definitions and provenance only, with no executable bytes,
preferences, saved login credentials or cookies. The full repeated-backup
inventory remains `/tmp/native-source-backup-inventory.json` for coordination.

## Authentication compatibility

`CloudflareResponsePolicy` classifies challenge responses natively and permits
one cached-clearance refresh for safe bodyless GET/HEAD requests. Interactive
challenges retain browser fallback. Browser verification never replays a mutation
body; the original mutation is retried only after verification, and body streams
are rejected where replay cannot be guaranteed. Cookie refresh respects host,
path, scheme and expiry; concurrent challenge ownership and cancellation remain
scoped to matching request context.

Login settings retain their declared method: `basic` invokes the source's native
credential handler, `oauth` coordinates `ASWebAuthenticationSession` and native
token exchange, and `web` retains isolated WebKit for the source's cookie and
localStorage contract. `NativeWebLoginPolicy` validates HTTP login URLs and OAuth
callback scheme, declared redirect origin/path, state, provider errors and
duplicate security parameters. The existing S256 PKCE verifier/challenge flow
remains; state is generated when absent in that flow. Legacy non-PKCE settings
without declared redirect URI or state retain scheme-only compatibility checking.

Kavita OIDC still uses a nonpersistent WebKit login session: its account API
requires `.AspNetCore.Cookies`, and `ASWebAuthenticationSession` does not provide
an API to export the provider's browser cookies. Native completion logic accepts
only the exact main-frame `aidoku://oidc-auth` callback, filters cookies for API
endpoint domain/path/security/expiry and commits once. Generic cookie login reads
localStorage only for the source's origin including scheme, host and port, and
rejects extraction from an obsolete navigation snapshot.
Generic web-login exports keep host/security/expiry filtering but deliberately
do not filter by the login page's path: the legacy flat name/value contract does
not describe an API endpoint path. OIDC and Kavita use strict API endpoint paths.

A general hosted login or interactive Cloudflare challenge cannot be recreated
as a universal Swift form without provider-specific protocols. Browser fallback
is therefore retained where the server requires browser execution or interaction.
Moving such interaction to a system browser is native API coordination, not
native HTML rendering; browser cookies are not automatically URLSession cookies.
The implementation must eliminate source WASM execution, but no claim of
universal Cloudflare bypass or complete application native rendering is made.

The application deployment target remains iOS 15. AidokuRunner declares iOS 15
and macOS 12 support, Swift tools 6.0 and Swift 6 language mode. Availability guards
remain necessary for newer system authentication and networking APIs.

## Verification workflow

Eight implementation agents completed separate changes and behavior tests. Eight different reviewers then audited the runtime, Hitomi, galleries, Japanese groups A/B, image codecs, authentication/Cloudflare, and app integration. Original implementers or the coordinator corrected their findings; reviewers independently rechecked those corrections. Static review is supplemented by the executable evidence below.

No structural source-string harness is added. Existing Swift Testing suites and
production helper tests exercise actual decoding, routing and cancellation.

New implementation suites include `NativeWebLoginPolicyTests` and
`NativeLoginAttemptTests`. `SourceLoginBrowserPolicyTests` exercises cookie scope,
host-only and secure cookies, same-origin localStorage, and exact OIDC callback
matching. `NativeSourceRoutingTests` covers external-versus-built-in classification
and manifest identity rejection before executable loading. Registry package tests cover supported selection
without an executable and preserved metadata, explicit unsupported key/version
rejection including packages that still contain executable bytes, factory failure
propagation, atomic overlapping registration, registration from a factory without
holding the lock, and concurrent lookup.
The native registry package tests have executed successfully (15 tests in 4 suites). Simulator evidence is recorded below.

`CloudflareResponsePolicyTests` covers authoritative challenge headers, ordinary
403 rejection, legacy markup, safe cached retries, mutation/cookie preservation,
bodyless browser verification and cookie boundaries. `NativeHitomiSourceTests`
covers model/settings mapping, gallery-cache sharing and invalidation, cancelled
gallery fan-out, reader Referer preservation and deep-link host validation.

Relevant existing suites include `SettingsLoginWebSchedulingTests`,
`SourcePaginationTests`, `SourceBrowseSafetyTests`,
`SourceListingPaginationTests`, `BuiltInSourceModelTests`, and `HTTPSBypassTests`.
Select affected suites based on changed behavior, not the entire app test plan.

```sh
# Replace SuiteName with an affected suite; current source build is required.
python3 Scripts/test_quick.py --ios SuiteName \
  --device AA441ADA-456B-41F8-B643-ECBF93AC0718 --configuration Release

# Native registry and model/codec tests; source WASM runtime was removed.
swift test --package-path Vendor/AidokuRunner
```

Keep Release optimization, `SWIFT_COMPILATION_MODE=singlefile`,
`ONLY_ACTIVE_ARCH=YES`, and fixed `build/simulator-fast-release` cache settings.
Never run concurrent builds in the same cache. No clean or cache deletion is
required. `test-without-building` is valid only after a successful build of the
same sources and settings. Zero executed tests and timeouts are not passes.

## First-round evidence (historical)

- `swift test --package-path Vendor/AidokuRunner --jobs 2` passed **15 tests in 4 suites** after the final public static-metadata API change. Incremental package build: 3.56 seconds; test body: 0.004 seconds. Log: `/tmp/aidoku-native-source-package-final.log`.
- `python3 Scripts/validate_localizations.py` passed: 41 locales, app/share extension, 40,959 entries and 918 literal Swift keys; no placeholder or missing-key errors.
- `git diff --check` passed.
- Independent codec harnesses extracted the actual production files and matched all three full RGBA reference hashes, identity/reversed MangaRawJP pixel arrays, OpenSSL AES counter-wrap/Japanese-path vectors and malformed Unicode rejection. These host-only checks do not replace iOS execution.
- Release `xcodebuild build-for-testing` passed with `-O`, `SWIFT_COMPILATION_MODE=singlefile`, `ONLY_ACTIVE_ARCH=YES`, testability enabled and the fixed `build/simulator-fast-release` cache. Incremental build after the Rawkuma path fix: **58.730 seconds**; final incremental build after the SenManga literal fix: **28.100 seconds**. No clean/cache deletion or whole-module build was used.
- AidokuFast executed **971 Swift Testing tests in 179 suites** on the iOS 26.5 iPhone 17 Pro simulator. Startup plus test execution: **37.248 seconds**; test body: **17.181 seconds**. Initial result failed two test methods: the new Rawkuma link test (2 assertions) and the existing render digest oracle (3 assertions). All other native migration suites, including all-12 backup loading/version rejection and seven independent audit suites, passed.
- After fixing Rawkuma trailing slash preservation (`URL.path` dropped it; `URLComponents.percentEncodedPath` retains the source key), focused `test-without-building -only-testing:AidokuTests/NativeRawkumaSourceTests` passed **4 tests in 1 suite**. Startup plus execution: **5.009 seconds**; test body: **0.022 seconds**. The final native migration evidence is **119 tests across 26 added Swift Testing suites**, passed across the initial run and necessary focused reruns. SenManga and independent group B audit rerun passed **7 tests in 2 suites**, startup plus execution **4.811 seconds**, test body **0.028 seconds**. Logs: `/tmp/aidoku-native-ios-fast-tests.log`, `/tmp/aidoku-native-ios-rawkuma-tests.log`, `/tmp/aidoku-native-ios-senmanga-tests.log`.
- The first-round complete Fast plan **was not green** because `ReaderTranslationDigestEquivalenceTests.persistedOCRTranslationAndRenderKeyContractsRemainExact` has a pre-existing stale oracle: test revision `v116-source-restoration-geometry`, production revision `v119-small-caption-inpainting`. Both files' Git blobs exactly match baseline `14627f57`; history shows production changed at `b194d7aa` and `14627f57` without updating this oracle. At the first-round checkpoint the unrelated translation implementation/expectation was preserved. The second audit corrected the stale test oracle; see the current report. This failure is not counted as a native migration pass.
- Final app `nm` inspection found no `Wasm3`, `wasm3` or `_m3_` interpreter symbols. Early compile attempts uncovered a login variable redeclaration, app/runner model ambiguity, shared HTTP method enum deletion and Cloudflare actor/controller references; all were corrected. Removed legacy-UI tests were retired, while modern stepper lifetime/100-use reset assertions were adapted to the existing native lease. Final independent evidence review also caught SenManga type qualification accidentally changing the `^Chapter` pattern and matching test input; both literals were restored to the authentic API values and focused validation was repeated.

All 12 backed-up ID/version pairs have compiled native registrations. Metadata, source IDs and library keys are preserved. The old source interpreter, imports, Wasm3 dependency and executable fallback are removed. Downloaded `.aix` packages are metadata carriers for an exact supported registration; a new or unsupported version is explicitly rejected with a localized ID/version reason.

Coverage limits: no physical iPhone installation or live account login/Cloudflare solve has been performed. Fixture tests validate protocols and parser behavior, not current availability of every provider. Yomii was reconstructed from static backed-up module data/control flow; complete equivalence of every historical WASM branch is not proven. Hitomi response limits apply after URLSession buffering, and aggregate peak-memory behavior was not measured. The native implementation refuses stale gg routing when refresh fails rather than using an expired cache. Browser-dependent authentication and translation/dictionary WebKit remain; translation pixel kernels outside this migration still include WebAssembly.

## Source provenance and license

Eleven recovered identities have exactly matching manifest versions in the
[Aidoku community source repository](https://github.com/Aidoku-Community/sources/tree/897b8f2102b48c722f438c10373d1cb5e10876cb/sources),
revision `897b8f2102b48c722f438c10373d1cb5e10876cb`. This matches source versions,
not rebuilt WASM binary hashes. Authentic Rust/resources are retrieved into
`/tmp/aidoku-native-upstream/sources/<id>/` for porting. `ko.yomii` version 7 is
absent from that revision. Its native implementation derives from the recovered
local custom module's static data and control flow, not an assumed public adapter.

Native ports deriving from the community code use its MIT license option.
Copyright 2025 Aidoku community source contributors. The complete notice is
preserved in `Docs/NativeSource-MIT.txt`, with per-port provenance comments.
The upstream repository also offers Apache 2.0 as an alternative.

`SenMangaSourceRunner` ports the matching `ja.senmanga` v2 JSON API, search sort
and select parameters, details, ratings/viewer, chapters, page lists, deep links
and old-key migration. `NativeSenMangaSourceTests` exercises query encoding,
nullable pagination, null-status preservation, genre/chapter/date mapping,
page validation, migration identity, strict deep-link host and cancellation.
These tests are included in AidokuFast; their execution evidence is recorded below.

`NativeSourceBackupCoverageTests` loads all 12 exact installed source versions
from the combined bundled metadata fixture into temporary source packages with
no executable. It verifies identity, version, languages, listings, filter and
settings preservation, and explicit unknown-version rejection. The fixture is
bundled in the test target, so the suite does not depend on host checkout paths
or access actual backup directories at runtime. The test contains no live source
requests. Package verification after the final immutable static-metadata API change passed all 15 tests in 4 suites. Simulator and metadata-suite evidence is recorded below.

## Second independent audit

The requested 16-agent re-audit and its coordinated final execution evidence are
recorded in [native-source-reaudit.md](native-source-reaudit.md). This supersedes
the first-round failure status above; historical execution logs remain unchanged.
