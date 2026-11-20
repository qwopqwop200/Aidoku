# Source authentication

Installed sources run their `main.wasm` as upstream Aidoku does: current packages
on the AidokuRunner interpreter (fork) and 0.6-API packages on the legacy runtime
(`Core/Sources/Legacy`). Source network requests go through the shared source
session (`NativeSourceNetwork`, `SourceNetwork`) with bounded response bodies and
Cloudflare handling; packages are unpacked by `SourcePackageExtractor` with entry
and size limits. Browser-dependent provider authentication remains a separate
compatibility boundary: a native coordinator around a web authentication session
does not make the hosted page native. See [the current runtime map](native-runtime.md).

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
No claim of universal Cloudflare bypass or complete application native
rendering is made.

The application deployment target remains iOS 15. AidokuRunner declares iOS 15
and macOS 12 support, Swift tools 6.0 and Swift 6 language mode. Availability guards
remain necessary for newer system authentication and networking APIs.

## Tests

`NativeWebLoginPolicyTests` and `SettingsLoginAttemptTests` cover login policy.
`SourceLoginBrowserPolicyTests` exercises cookie scope, host-only and secure
cookies, same-origin localStorage, and exact OIDC callback matching.
`CloudflareResponsePolicyTests` covers challenge detection, bodyless browser
verification and cookie boundaries. Relevant existing suites include
`SourcePaginationTests`, `SourceBrowseSafetyTests` and `HTTPSBypassTests`.
Select affected suites based on changed behavior, not the entire app test plan.

```sh
python3 Scripts/test_quick.py --ios SuiteName --device <UDID> --configuration Release
```

Coverage limits: no physical iPhone installation or live account login/Cloudflare
solve has been performed. Fixture tests validate protocols and parser behavior,
not current availability of every provider.
