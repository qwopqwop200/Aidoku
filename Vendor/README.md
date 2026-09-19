# Local source dependencies

The app uses the local `AidokuRunner` package, which uses the local `Wasm3`
package, and the local `HoshiDicts` package. These source copies came from the dependencies resolved for the
2026-09-19 audit. They are required by the app's Xcode package graph, rather than
unused reference copies.

- AidokuRunner upstream: https://github.com/Aidoku/AidokuRunner
- Wasm3 Swift wrapper upstream: https://github.com/Skittyblock/Wasm3
- Wasm3 interpreter upstream: https://github.com/wasm3/wasm3
- HoshiDicts upstream: https://github.com/Manhhao/hoshidicts

Preserve the upstream notices. AidokuRunner's README contains its own copyright
and distribution terms; it is not relicensed by this directory. Wasm3's included
license remains with that package.
HoshiDicts and its included libraries retain their respective license notices.

Local corrections cover callback/runtime ownership, cancellation and WebView
completion, serialized model decoding, raw memory bounds, C/Swift structure
layout, malformed modules and allocation failure recovery, and WASI memory/file
boundaries. Keep C headers and implementation layout synchronized, including
build configurations used by the Swift wrapper.

HoshiDicts includes the library's source and literal-include header closure,
including architecture-specific libdeflate code. Its deployment target matches
the app's iOS 15 minimum; Swift dictionary UI retains its existing availability
guards. Corrections include malformed ZIP/hash/record bounds, import rollback,
Unicode/JSON handling, query error propagation, and thread-safe codec dispatch.
Its generated Unicode table is retained as data. The CLI and unrelated examples
are not part of this package. Zstandard remains a resolved package dependency.

Run both packages' test suites after changing either dependency:

```sh
swift test --package-path Vendor/Wasm3
swift test --package-path Vendor/AidokuRunner
```

Run the app's integrated iOS tests as well: package tests do not exercise reader
rendering, app settings, or the app's complete build flags. Compare and carry
forward these changes deliberately when updating the upstream sources.

Hoshi native regression sources and runners live in `Scripts/tests/hoshi-*`,
`Scripts/tests/run-hoshi-*`, and `Vendor/HoshiDicts/Tests/ImportRegression`.
Run those with their documented sanitizer commands after changing the native
dictionary library, in addition to the app's integrated tests.
