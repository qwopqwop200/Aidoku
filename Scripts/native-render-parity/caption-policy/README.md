# Caption/panel observation policy parity

```sh
python3 Scripts/native-render-parity/caption-policy/run.py
```

The runner captures all seven caption/panel helper calls while running the 47 existing source-color regressions against the frozen pre-migration JavaScript. It supplements them with deterministic real pixel buffers representing light, colored, and dark surfaces, chromatic and white glyphs, and fractional ink estimates. It builds a host native Swift executable linked to the production native Rust kernel library, without an Xcode app build.

All 111 calls must have exactly equal descriptors, including nested confidence/evidence, every RGB value, gradient stops, nullable fields and optional fields. Each of the seven functions must also make at least one active update; null-only or unchanged-result implementations fail coverage.

The policies cover opposite-side panel agreement and gradient averaging, repeated outlined-color recovery, observed gradient surfaces, display-only fallback palettes, local halo ink recovery, trimmed exposed caption interiors, broad/narrow ink masks, and native column statistics. Integer ink uses the same-source native kernels. Fractional ink retains Double threshold comparisons rather than truncating palette values for the integer ABI.

Artifacts under `build/native-render-parity/caption-policy` include the captured fixtures, native results, original regression log, per-function report and source/fixture provenance. This policy test does not establish full-page rendering or glyph rasterization equality.
