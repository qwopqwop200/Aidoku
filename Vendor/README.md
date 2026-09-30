# Local source dependencies

The app uses the local native-only `AidokuRunner` model/protocol package,
`HoshiDicts`, and `Nuke`. Installed source metadata selects an explicitly
registered Swift implementation by exact source ID and version. The package no
longer depends on Wasm3 and does not execute `main.wasm`; unsupported sources
are rejected. See `Docs/native-source-auth.md` for the recovered source inventory
and native ports.

- AidokuRunner upstream: https://github.com/Aidoku/AidokuRunner
- HoshiDicts upstream: https://github.com/Manhhao/hoshidicts
- Native source ports: https://github.com/Aidoku-Community/sources

Preserve the upstream notices. AidokuRunner's README contains its copyright and
distribution terms; it is not relicensed by this directory. The removed Wasm3
runtime's license is preserved in `Docs/licenses/Wasm3-LICENSE`. Native source
port notices are in `Docs/NativeSource-MIT.txt`. HoshiDicts and its included
libraries retain their respective license notices.

The native package retains metadata decoding, bounded Postcard serialization,
and task-owned partial-result publication. Run `swift test --package-path
Vendor/AidokuRunner --jobs 2` after changing it, plus the affected integrated iOS
source/authentication suites. The removed runtime's test suites no longer apply.

HoshiDicts includes the library's source and literal-include header closure,
including architecture-specific libdeflate code. Its deployment target matches
the app's iOS 15 minimum; Swift dictionary UI retains its existing availability
guards. Corrections include malformed ZIP/hash/record bounds, import rollback,
Unicode/JSON handling, query error propagation, and thread-safe codec dispatch.
Its generated Unicode table is retained as data. The CLI and unrelated examples
are not part of this package. Zstandard remains a resolved package dependency.


Hoshi native regression sources and runners live in `Scripts/tests/hoshi-*`,
`Scripts/tests/run-hoshi-*`, and `Vendor/HoshiDicts/Tests/ImportRegression`.
Run those with their documented sanitizer commands after changing the native
dictionary library, in addition to the app's integrated tests.

## Nuke

`Vendor/Nuke` preserves the pinned upstream source and license; see its
`AIDOKU_PATCHES.md` for exact revision and the request-identity correction.
The local package is required by the app project. URLRequest headers, method,
and body must identify both cached bytes and coalesced original-data tasks;
changing only a public cache key leaves simultaneous requests vulnerable to
wrong-image reuse. Source interceptor request/response semantics stay intact.

Run `swift test --package-path Vendor/Nuke` and the app's image-cache/reader
regressions when changing this patch. Carry the fix forward deliberately during
upstream updates.
