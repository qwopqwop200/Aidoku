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

Active data loading priority: an optional `DataLoadingPriorityUpdating` handle
forwards the maximum coalesced subscriber priority to URLSessionTask.priority,
including promotion and demotion after resume. This is a network scheduling
hint, not guaranteed bandwidth or preemption. Existing DataLoading conformers
remain supported; request identity, concurrency limits and last-subscriber
cancellation are unchanged. Aidoku's asynchronous source-loader wrapper retains
and forwards the latest priority while its URLSession is being prepared.

Safety audit corrections:
- `DataCache.flush(for:)` drains a pending global removal before later staged
  writes, so flushing one key cannot lose a write made after `removeAll()`.
- Memory-cache instances unregister their block notification observer on release.
- Resumed responses validate total-length overflow and the configured download
  limit before reserving memory; chunks validate the limit before appending.
- Disposed image tasks cannot restart transport after a failed cache decode or
  install a late preview in memory cache. Encoded disk writes honor the request's
  `disableDiskCacheWrites` option.
- Combine subscriptions start once on positive demand and remain terminal after
  cancellation/completion, releasing downstream state and cancelling a task
  created concurrently with cancellation.
- LazyImage request comparison includes decode scale and thumbnail options.
- Video resource reads validate offsets and clamp lengths to available bytes,
  including Data slices with nonzero start indices.

These changes retain successful response bytes, request method/body/headers,
decoding and rendering algorithms, and existing image/cache size policies.
Focused regressions live in `Tests/NukeRequestIdentityTests`; that target also
depends on NukeUI and NukeVideo to exercise their actual implementation.
