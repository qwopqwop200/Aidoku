# Source authentication

Sources run as described in [the runtime map](native-runtime.md). Requests use the shared source session
(`NativeSourceNetwork`, `SourceNetwork`) with bounded bodies and Cloudflare handling. Browser-dependent provider
authentication stays a separate WebKit boundary.

- `CloudflareResponsePolicy` classifies challenges natively and allows one cached-clearance refresh for bodyless
  GET/HEAD requests; interactive challenges fall back to the browser. Verification never replays a mutation body:
  the mutation is retried only afterwards, and non-replayable body streams are rejected. Cookie refresh respects
  host, path, scheme and expiry; challenge ownership and cancellation are scoped to the matching request context.
- Login methods: `basic` calls the source's credential handler, `oauth` uses `ASWebAuthenticationSession` with
  native token exchange (S256 PKCE; state generated when absent), `web` keeps isolated WebKit for the source's
  cookie/localStorage contract. `NativeWebLoginPolicy` validates HTTP login URLs, callback scheme, declared redirect
  origin/path, state, provider errors and duplicate security parameters; legacy non-PKCE settings without redirect
  URI or state get scheme-only checks.
- Kavita OIDC uses a nonpersistent WebKit session because its API needs `.AspNetCore.Cookies`, which
  `ASWebAuthenticationSession` cannot export. Only the exact main-frame `aidoku://oidc-auth` callback is accepted;
  cookies are filtered by API endpoint domain/path/security/expiry and committed once.
- Generic cookie login reads localStorage only for the source origin (scheme, host, port), rejects obsolete
  navigation snapshots, and filters exported cookies by host/security/expiry but not path (the flat legacy contract
  has no endpoint path). OIDC and Kavita use strict endpoint paths.

Hosted logins and interactive challenges cannot become universal Swift forms, so browser fallback stays where the
server needs it; there is no universal Cloudflare bypass. The app targets iOS 15; AidokuRunner declares iOS 15 /
macOS 12, Swift tools 6.0, Swift 6 mode.

Tests: `NativeWebLoginPolicyTests`, `SettingsLoginAttemptTests`, `SourceLoginBrowserPolicyTests` (cookie scope,
localStorage origin, OIDC callback), `CloudflareResponsePolicyTests`, plus `SourcePaginationTests`,
`SourceBrowseSafetyTests` and `HTTPSBypassTests`. Run affected suites with
`python3 Scripts/test_quick.py --ios SuiteName --device <UDID> --configuration Release`. Fixtures validate protocols
and parsing; no live account login or Cloudflare solve has been run.
