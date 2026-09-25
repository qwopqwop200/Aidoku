# Aidoku pinned Nuke provenance

Upstream https://github.com/kean/Nuke, version **13.2.0**, revision
`30f7a7e72e0607d304fbf69c799474bd5fb6d1ce` (existing Xcode Package.resolved).
Copied Sources, Package.swift, LICENSE and README.md from that resolved checkout.
Upstream notices remain intact.

Local patch: ImageRequest(urlRequest:) derives its underlying identity from URL,
method, case-insensitive sorted explicit headers, and body. Values are SHA256
hashed with length-delimited fields; authentication is not exposed in keys.
Headerless/bodyless GET keeps the historical URL key. Non-replayable body streams
receive a per-construction nonce; ImageRequest copies keep their identity.
Default disk keys use an aidoku-image-data-v2 namespace so old unscoped records
are not reused; old records age out under the same existing disk-cache limit.
Delegate-provided explicit cache keys remain unchanged.
Both default memory/disk identity and original-data coalescing share this value.
An explicit custom imageID still intentionally overrides cache identity, while
original data coalescing remains tied to the full request. Loader, response,
streaming and cancellation behavior are unchanged.

Session-injected cookies/credentials are not available in the URLRequest at this
boundary. Account switching which relies only on implicit URLSession state still
needs explicit request identity or cache/session invalidation at the owner.
Custom imageID overrides remain the caller's responsibility for cache isolation.

Run `swift test --package-path Vendor/Nuke -j 2`, then the integrated iOS tests.
Carry this correction and its tests forward deliberately when updating upstream.
