# Native runtime map

The reader's translation display, final image export and dictionary popup use
native code. Installed source packages select registered Swift adapters; source
WASM execution is removed. Browser-dependent login and interactive challenges
still use WebKit. The app as a whole therefore still has a browser component.

| Area | Current execution | Main entry points |
| --- | --- | --- |
| OCR and recovery | Core ML and Swift image/geometry processing | `NativeCoreMLOCRPipeline`, `ReaderOCRService` |
| Translation requests | Swift URLSession transport, parsing and bounded batching | `RemoteTranslationClient`, `ReaderTranslationService` |
| Translated text layout | Swift, Core Text and Core Graphics | `NativeTranslationRenderer`, `NativeTranslationLayoutPlanner` |
| Source color, text removal and background repair | Swift plus original Rust kernels compiled as a native static library through a C ABI | `NativeTranslationPixelKernels`, `Scripts/overlay-kernels/native/build.py` |
| Live translation display | Worker-owned bitmap, direct Core Graphics source painting, Core Text and bounded native helpers | `ReaderTranslationOverlayView`, `NativeSourceCanvasHierarchyCompositor` |
| Final image export and cache | Native image/PDF composition with versioned cache identity | `ReaderTranslationImageExporter`, `ReaderTranslationRenderCache` |
| Dictionary popup | UIKit text, links and view layout | `NativeDictionaryPopupView` |
| Installed source metadata and adapters | Native registry dispatch by exact ID/version; unsupported packages fail | `NativeSourceRegistration`, `Vendor/AidokuRunner` |
| Web login, challenge solving and user agent | WebKit for browser-dependent flows | `WebView`, `CloudflareHandler`, `UserAgentProvider` |
| Image translation CLI | Native production algorithms with an AppKit/Core Graphics host adapter | `Scripts/image-translation.swift` |

Historical `Browser…` names can remain on pure Swift layout and OCR data types.
A type name alone does not imply browser execution. The production translation
and dictionary path does not load the old overlay JavaScript or instantiate the
old Web popup. Native Rust is compiled machine code, not an embedded WASM
interpreter.

## Host image translation

```sh
swift Scripts/image-translation.swift /path/to/page.png
swift Scripts/image-translation.swift --render-run /path/to/saved-run
```

The launcher builds current source with incremental object/model caches. It
requires Apple Silicon macOS 15+, Xcode command-line tools and Rust. Rendering
uses Core Text/Core Graphics, native restoration and PDF composition; `final.html`
is a static PNG preview. The host shares the app's worker-side Core Graphics
source compositor; temporary window capture is no longer required. Host font
and raster behavior is not proof of exact iPhone output.

See [CLI configuration and outputs](../Scripts/image-translation/README.md),
including `.env`, saved phone settings, replay and bounded concurrency.

## OCR resolution limits

Reader settings and the image-translation CLI use a detector longest-side ceiling
of **1184** and recognizer crops of at most **48 × 1184**. Existing larger saved
values are bounded on load/use/save; smaller valid choices are retained. The CLI
also bounds explicit flags, environment profiles and imported phone settings to
32...1184. Recognition height remains 48. OCR cache keys include the effective
configuration, so earlier 1280 results cannot satisfy the new settings.

The bundled models support dynamic input dimensions. Historical fixed-function
names such as `rec1280b1` describe compiled tensor contracts, not the app's current
crop limit. Low-level explicit model/replay configuration keeps its documented
wider range for frozen regression fixtures; it does not change reader or CLI
limits. Historical service replay fixtures explicitly retain their captured
1280 recognition width so a new app default cannot silently change their inputs.
Tests in `NativeOCRResolutionContractTests` exercise real inference for all three
bundled detector and recognizer tiers at the 1184 limit.

Unused fixed detector canvas tables, the unused detector predictor-injection
interface and the alternate full-image preprocessing switch were removed. The
independent full-image sampling reference now lives only in its regression test.
The one-off efficiency measurement suite became `NativeRenderPipelineTests`,
retaining live/export/source correctness assertions without sampling memory,
repeating benchmarks or writing reports from the app test target.

## Native allocation and painting policy

Admitted source repairs draw into the worker's existing bitmap, avoiding a full
page prefix copy, main-actor window capture and bitmap replay. Unsupported
geometry retains the native fallback. Horizontal outlined text reuses the
measured Core Text glyphs for fill/stroke passes; mixed stroke attributes,
color glyphs, vertical and condensed text retain the appropriate existing path.
Mixed stroke runs can change ligatures when reshaped, so they must not enter
the glyph-reuse path.

Cold image composition accepts the existing native bitmap and repair CGImages.
PNG/Base64 encoding remains for persisted assets and explicitly requested layer
diagnostics. Cached reads retain their encoded-asset compatibility path. The
host similarly composes repair images directly and encodes the final PNG once
for both the saved image and its HTML preview. The visual cache namespace is
`reader-render-v159-native-direct-paint`; OCR and translation keys are unchanged.

SQLite compressed reads borrow the BLOB only within the synchronous statement
and return owned decoded bytes. Writes retain their source buffer until SQLite
finalizes the statement. Cancelled preload JPEG slots cannot be refilled by a
late producer. Hidden overlay rasters are released, and the overlay stays weak
while waiting for a shared layout producer. Dictionary raster attachments decode
at their display size and retain one size/trait-specific rendered bitmap;
explicit pixelated images preserve their original pixels.

The archived `NativeEfficiencyMeasurementTests` benchmark used one warmup and
three samples per phase. Its historical report records wall time, sampled process
RSS, physical footprint, returned payload bytes and output PNGs. The replacement
`NativeRenderPipelineTests` retains the correctness checks without measurements
or report output. Historical generated fixtures and the six-source-draw
microbenchmark do not establish whole-app or physical-device improvements.

## Verification

The previous Web renderer, its JavaScript/WASM oracle, comparison captures and
legacy regression tests have been removed. Native rendering, restoration,
export, cache and resource-lifetime suites validate the current implementation
directly. Existing native input fixtures remain where they support these tests.
No legacy-renderer pixel-equivalence gate remains.

See [test commands](../Scripts/TESTING.md). Web login and Cloudflare still use
WebKit; the CLI's interactive analysis report uses JavaScript to display saved
native results. Neither runs the removed translation renderer.
