# Native source and authentication migration

Source WASM execution is removed: installed sources are served by compiled Swift
adapters, and unknown source identities or versions fail explicitly instead of
falling back to WASM. Browser-dependent provider authentication remains a separate
compatibility boundary: a native coordinator around a web authentication session
does not make the hosted page native. See [the current runtime map](native-runtime.md).

`AidokuRunner.Runner` already allows compiled Swift implementations. Existing
Local, Komga, Kavita and Suwayomi sources demonstrate this path. A downloaded
WASM module cannot be converted to an equivalent native source simply by changing
its file extension or runtime factory: each adapter must reproduce that source's
protocol, models, filters, listings, image request headers and update semantics.

## Native runtime boundary

Native registrations must match source identity, source version and configuration
explicitly. Unknown identities and versions must report an unsupported-source
error. Registered native factory errors propagate; there is no WASM fallback.
Import and database reload must make the same decision.

`NativeSourceRunnerRegistry` registers an explicit source key and version set
with a runner factory. Registration overlap is rejected atomically; lookup
releases the registry lock before invoking the factory. The native loader keeps
manifest metadata and can select a supported adapter without an executable.
Fixture versions in package tests are not live source support claims.

## Recovered installed source inventory

A metadata-only inventory of installed `source.json` and `.aix` files yielded
12 identities and 14 unique manifest/executable hash pairs with zero decode errors.
No preferences, tokens, cookies or credentials were read. Repeated backups cannot
establish native adapter parity by themselves.

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

## Tests

New implementation suites include `NativeWebLoginPolicyTests` and
`SettingsLoginAttemptTests`. `SourceLoginBrowserPolicyTests` exercises cookie scope,
host-only and secure cookies, same-origin localStorage, and exact OIDC callback
matching. `NativeSourceRoutingTests` covers exact id/version routing and manifest
identity rejection before executable loading. Registry package tests cover supported selection
without an executable and preserved metadata, explicit unsupported key/version
rejection including packages that still contain executable bytes, factory failure
propagation, atomic overlapping registration, registration from a factory without
holding the lock, and concurrent lookup.

`CloudflareResponsePolicyTests` covers challenge detection, bodyless browser
verification and cookie boundaries. `NativeHitomiSourceTests` covers metadata
mapping, ranged pagination, index size limits, untrusted index/routing parsing and
deep-link host validation.

Relevant existing suites include `SourcePaginationTests`, `SourceBrowseSafetyTests`
and `HTTPSBypassTests`.
Select affected suites based on changed behavior, not the entire app test plan.

```sh
python3 Scripts/test_quick.py --ios SuiteName --device <UDID> --configuration Release
```

Coverage limits: no physical iPhone installation or live account login/Cloudflare
solve has been performed. Fixture tests validate protocols and parser behavior,
not current availability of every provider. Yomii was reconstructed from static
backed-up module data/control flow (`Docs/NativeYomiiRecovery.md`); complete
equivalence of every historical WASM branch is not proven.

## Source provenance and license

Eleven recovered identities have exactly matching manifest versions in the
[Aidoku community source repository](https://github.com/Aidoku-Community/sources/tree/897b8f2102b48c722f438c10373d1cb5e10876cb/sources),
revision `897b8f2102b48c722f438c10373d1cb5e10876cb`. This matches source versions,
not rebuilt WASM binary hashes. `ko.yomii` version 7 is
absent from that revision. Its native implementation derives from the recovered
local custom module's static data and control flow, not an assumed public adapter.

Native ports deriving from the community code use its MIT license option.
Copyright 2025 Aidoku community source contributors. The complete notice is
preserved in `Docs/NativeSource-MIT.txt`, with per-port provenance comments.
The upstream repository also offers Apache 2.0 as an alternative.

`SenMangaSourceRunner` ports the matching `ja.senmanga` v2 JSON API, search sort
and select parameters, details, ratings/viewer, chapters, page lists, deep links
and old-key migration. `NativeSenMangaSourceTests` covers detail and chapter mapping.

`NativeSourceRoutingTests` loads each of the 12 exact built-in source ids and versions
into a temporary package with no executable, checks that it routes to its native runner,
and verifies explicit rejection of every other version.
