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
| Live translation display | Native bitmap painter and bounded UIKit/Core Animation/Metal helpers | `ReaderTranslationOverlayView`, `NativeSourceCanvasHierarchyCompositor` |
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
is a static PNG preview. The host adapter declines iOS window-specific live
capture, while offline final-image composition remains native. Host font and
raster behavior is not proof of exact iPhone output.

See [CLI configuration and outputs](../Scripts/image-translation/README.md),
including `.env`, saved phone settings, replay and bounded concurrency.

## Reference code and verification

The previous renderer remains only as an independent test oracle. Known defects
in that oracle require a separately labeled, narrowly corrected runtime copy;
the original source, image and raw comparison remain archived.

- `AidokuTests/Translation/LegacyBrowserOverlay` compiles the frozen reference
  into the test target, not the production app.
- `Scripts/native-render-parity/reference-source` preserves original source and
  hashes. Its WebKit, JavaScript and embedded WASM are reference inputs.
- Node source-color and restoration scripts test the historical algorithm.
  Passing those tests alone does not validate the native runtime.
- Native Swift/Rust tests and native/reference RGBA captures validate the
  replacement. Reference expectations remain immutable; never regenerate them
  from native output.
- Final-export comparisons use the same prepared source pixels, logical image
  size and PDF composition route. The cache bitmap retains its independent
  exact comparison across preload depths. Mixing a fractional cache raster
  with WebKit's whole-point PDF crop is recorded as a diagnostic comparison.
- To honor the user's request that a few pixel differences not block migration,
  the implementation uses a bounded final-export policy: identical positive
  dimensions and channel differences of at most four byte values anywhere.
  Larger channel differences may reach 16 only when pixels exceeding four
  account for at most 0.1% of the image; lower-delta pixels do not spend that
  separate sparse budget. These numeric bounds are implementation choices.
  Exact equality and raw changed-pixel/max-delta
  metrics remain recorded, and independent source, text, geometry and restoration
  checks remain mandatory. A separate certificate permits an isolated common
  shift of at most one physical pixel along one axis: it requires unchanged
  alpha, exact total and projected channel mass, an unchanged opaque border,
  at most 0.1% changed pixels and a bounded 65,536-pixel envelope. The whole
  envelope must fit one displacement and coverage weight; missing text, altered
  weight, independent moves and a two-pixel shift fail this check. Font-size or
  erasure differences do not qualify as small raster rounding.
- A test-only contour fallback (`NativeFinalExportContourAudit`,
  `NativeFinalExportGlyphContourAcceptance`, and
  `NativeFinalExportPanelContourAcceptance`) can certify larger edge deltas only
  from matching live text, font, colors, transforms and per-character geometry,
  followed by glyph coverage/component or panel-contour pixel evidence. Alpha
  stays exact, the whole-image quota above delta four remains 0.1%, and every
  pixel above delta 16 must be covered by a successful certificate. The fallback
  contains no page-specific waiver and preserves the complete raw comparison.
  Missing glyphs, heavier strokes and mismatched descriptors remain failures.

The previous worktree's 16-fixture final-image matrix passed with zero decoded
RGBA differences at its recorded BUILD66 snapshot, and bounded source-canvas
checks passed at BUILD69. These are historical results, not current full-main
verification. The expanded current-main replay covers all 12 recorded inputs
(one verified empty page) at two preload depths, yielding 22 nonempty final-image
comparisons against the checked-in frozen Web renderer. The stale September 29
optimization captures remain archived diagnostics, not replacement goldens.

The historical unfiltered `full-ios-7` run reported 2,340 passing tests,
two failing tests and zero skipped tests. Its final export replay had four exact
comparisons and 18 material mismatches; none qualified for the then-current
sparse one-byte allowance. Later production fixes and independently checked
reference corrections are recorded separately from that historical baseline.

Current verification evidence, completed on 2026-10-01:

| Scope | Observed result |
| --- | --- |
| Full host matrix, `full-host-3` | 107/107 commands passed in 368.647 seconds; all 2,715 recorded source inputs stayed unchanged. |
| Recorded-page native/Web replay in `full-ios-9` | All 22 nonempty comparisons across two depths passed in 75.539 seconds: eight exact, eight bounded color differences, four contour certificates and two common-displacement certificates. |
| Independent contour verifier | Original PNG/live-layout evidence for pages 5 and 9 passed; all 17 destructive or malformed negative controls were rejected. |
| Final 16-fixture native/Web export matrix in `full-ios-9` | All passed: 15 exact; one with 2,325 changed pixels and maximum channel delta three. Independently decoded PNGs confirm the report. |
| Unfiltered iOS, `full-ios-9` | 2,435/2,435 declarations passed; 3,984 expanded executions; zero failures, skips or expected failures. All 2,723 recorded source inputs stayed unchanged. Build activity 2.279 seconds, test body 582.234 seconds, wall time 593.854 seconds. |

The earlier `full-ios-8` run had 2,433 passes and two failures: a panel fixture's
numeric JSON type and a stale expected render-cache revision. After correcting
those test inputs, focused-ios-27 passed all 14 declarations; full-ios-9 then
reused those unchanged compiled sources. No clean rebuild was performed. Both
full runs and their source manifests remain separate historical evidence.

The final run used one iPhone 17 Pro simulator with iOS 26.5 and two build jobs.
Its 12-page depth trials observed a maximum 402.207 MiB during the complete test
sequence; this is simulator process memory, not a physical-device measurement
or a renderer-only benchmark. Browser-dependent authentication remains outside
the native translation and dictionary paths.

Three opt-in reference repairs are documented independently of native output:

1. Accepted-growth rollback restores the complete last accepted style, children,
   coordinates and dataset after an unsupported exterior trial. It cannot leave
   a rejected font displayed, and the native surface proof remains unchanged.
2. Scaled glyph release converts the measured physical box back to logical CSS
   coordinates before reparenting, preventing a second scale and lost suffixes.
   Its diagnostic probe observes the completed stroke reset and must reproduce
   the same pixels as the uninstrumented correction.
3. Foreign layout exclusions restrict the chromatic reference's placement mask
   using original neighboring OCR bounds. Its ordinary caller supplied only ruby
   hints, allowing some foreign ink to remain layout-safe. The correction changes
   no source or restored RGBA and no erasure certificate; painted foreign overlap
   fails explicitly. Raw historical and rollback-only page images remain saved.

These transforms operate on a runtime copy, preserve checked-in frozen source,
leave the default 16-fixture oracle unchanged, and retain identical source,
regions, settings and logical geometry. Corrected final images still pass through
the same independent comparison policy; no reference is built from native pixels.

See [pixel-comparison evidence and limitations](../Scripts/native-render-parity/README.md)
and [current test commands](../Scripts/TESTING.md). Report host, simulator,
physical-device and historical-reference validation separately. A full-suite
claim requires an actual current-source execution with nonzero tests; a
prerequisite failure or skipped case is not a passing test.

The source-runtime migration has a separate provenance trail in
[native-source-auth.md](native-source-auth.md) and
[native-source-reaudit.md](native-source-reaudit.md). Their dated descriptions of
then-existing translation WebKit/WASM refer to the earlier revision.
