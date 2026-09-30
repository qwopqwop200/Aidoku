# NHentai native adapter provenance

Ported from Aidoku-Community/sources `sources/multi.nhentai/src/{lib,models,home,settings}.rs`, source-affecting commit `428fcba98eea132e58c6882cf0ea5745d22644fd` (repository inspected at `897b8f2102b48c722f438c10373d1cb5e10876cb`). MIT license copied alongside this port.

The recovered `multi.nhentai` v17 original and autocomplete archives have identical `main.wasm` SHA-256 `eb39593169a6f9540a8678c7a2898ceeebb85aa30ddf604679a71d5c7cb341b1`. Static strings independently confirm `/api/v2`, image `path` models, image hosts and settings keys. The WASM bytes were inspected as data, never executed.

The autocomplete variant changes only `source.json` configuration. The package metadata remains authoritative, including `/api/v2/tags/search` POST JSON suggestions, namespaces, token replacement, quoting, and rate interval. Those suggestions are handled by Aidoku's existing native suggestion client, not this runner.

Search, listings, all four Home components, numeric-ID lookup, detail metadata/ordering, single chapter, image paths, language, blocklist, title preference and list-view preference follow v17. Native requests retain the recovered User-Agent and enter `Source.modify`, `SourceNetwork`, and Cloudflare interception. Explicit native error propagation replaces silent fallback; deep links validate the actual host instead of vulnerable string-prefix matching. The native Home publisher emits the initial four-slot layout and updates populated slots through task-local subscriber ownership, preventing obsolete source invocations from publishing into a replacement subscriber. The returned Home retains the complete layout. The package declares no source-account login contract and therefore adds no invented credential form.

Network fixture tests check real request paths/query encoding, filter ordering, model mapping, cache reuse/clear, image host routing, home layout/listing sort and failure behavior. These fixtures do not prove compatibility with a live remote service or solve browser-required interactive challenges.
