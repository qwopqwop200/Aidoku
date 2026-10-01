# Native CPU / browser WASM kernel differential tests

Run from the repository root on Apple Silicon macOS:

```sh
python3 Scripts/native-render-parity/kernel-parity/run.py
```

The runner compiles the production `Scripts/overlay-kernels/kernels.rs` into a host native CPU dynamic library with the installed Rust compiler. It extracts the **frozen pre-migration WASM bytes** from `../reference-source/BrowserSourceTextColor.swift` and executes that independent oracle in Node's WebAssembly runtime. It does not rebuild or embed the WASM oracle from the native port.

The fixture manifest is generated deterministically from three fixed seeds. Every one of the 25 exported kernels receives nonempty, valid buffers and at least one active semantic case. A coverage gate rejects a suite that merely resolves symbols, clears scratch buffers, or only exercises an early rejection: successful exemplar fill, enclosed-paper restoration, local-component restoration, glyph detection, rays, and periodic detection must actually occur. Some rejection cases intentionally have zero active output.

Both runtimes receive identical aligned buffers and scalar arguments. The test compares exact return values and **all input/output/scratch bytes**, including raw Float32 residual/relaxation arrays and Float64 statistics. Each allocation has a 32-byte guard region, checked after native execution. Mismatch reports identify the first differing byte offsets and each runtime's digest; the full binary arenas remain available for inspection.

The 83 fixtures exercise:

- All 25 exports, with nonempty glyph outlines, enclosed paper holes, coloured pixels, ray hits, channel bins, and statistical columns.
- Fractional colour modes, negative fractional bounds and band origins, both axes and accelerated/unaccelerated harmonic relaxation.
- Polygon-shaped exclusion/forbidden masks and fractional auxiliary/excluded rectangles. These kernels accept raster masks and rectangles; no export accepts a vector polygon directly.
- Alpha rejection and an insufficient glyph-support threshold.
- The documented production aliases: harmonic RGBA input in the final third of Float32 work, exemplar work sharing RGBA input, and component membership sharing the completed seen mask.
- ECMAScript `ToUint8Clamp` half-to-even behavior using real local-component ring samples averaging `240.5` and `241.5`, with independent expected restored byte assertions of `240` and `242`.
- Pixel-class matching, fallback, protected pixels, and disabled flags.

Generated artifacts are written under `build/native-render-parity/kernel-parity/`:

- `report.md`: every kernel's exact-case count, active-case count, and result.
- `report.json`: per-fixture comparisons, native statistics, timings, ABI signatures, and SHA-256 provenance for native source/library, frozen WASM, and fixture manifest.
- `fixtures.json`: the reproducible calls and buffers.
- `native/*.bin`, `wasm/*.bin`: complete resulting arenas.

To compare an already-built host library, pass `--native-library /absolute/path/libAidokuOverlayKernels.dylib`. Use `--rustc` or `--output` to override the compiler or artifact directory.

A successful result proves exact native CPU kernel equivalence for the covered inputs. It does not establish Core Text/WebKit glyph equality, Swift-to-C bridge call correctness on iOS, or whole-page pixel equality; those have separate app-hosted renderer/parity suites.


## Actual Swift bridge coverage

`AidokuTests/Translation/NativeEngine/NativeTranslationPixelKernelBridgeTests.swift` executes the production Swift wrappers for all 83 fixtures, comparing every return and the complete arena, including Float32/Float64 scratch, real shared allocations and guard bytes. It separately verifies rejected geometry/scalars/indices, short buffers, harmonic border access, and borrowed-view bounds/alignment/lifetime. This suite is included in `AidokuFast.xctestplan` and also runs in the complete test plan.

The checked-in fixture is 847 KiB of raw DEFLATE plus an eight-byte uncompressed-length header. Apple Compression decodes it inside the test bundle; expected results come exclusively from the independent frozen WASM outputs. Regenerate after running `run.py`:

```sh
python3 Scripts/native-render-parity/kernel-parity/generate-swift-fixtures.py
```

A standalone macOS Swift/Testing execution uses the same test source and compressed fixture. Its only adaptations remove `@testable import Aidoku` and use the fixture's filesystem path instead of the iOS test-bundle URL:

```sh
python3 Scripts/native-render-parity/kernel-parity/run-swift-bridge.py
```

Host results are written to `build/native-render-parity/swift-kernel-bridge/report.json` and `tests.log`. The iOS app-hosted suite remains the platform-specific ABI check; the host runner does not replace it.
