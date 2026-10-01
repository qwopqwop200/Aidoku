# Forced source inpainting differential verification

Run on Apple Silicon macOS:

```sh
python3 Scripts/native-render-parity/forced-source-policy/run.py
```

This compiles the actual production `NativeForcedSourceInpainting`, `NativeResidualProof` and `NativeSourceGlyphSegmentation` with Swift 6 and strict concurrency. The small host compatibility definitions copy production palette parsing and max-channel color distance. No segmentation, source census, donor fill, surface fit, relaxation or quality algorithm is mocked.

The oracle composes the immutable pre-port browser scripts with the original conservative glyph adapter. Every frozen source is checked against the archived SHA-256 manifest before execution. The oracle and native runner receive identical pixels, palette descriptors and options. The oracle additionally verifies that source input pixels remain unchanged.

All 45 fixtures compare complete RGBA and ownership-mask arrays, every returned metadata field, method-specific quality/surface fields, nullability and failure reasons. The typed native quality structure is serialized into the original JavaScript shape; no numerical tolerance is used.

The corpus includes 33 synthetic controls and 12 preserved real crop regressions:

- Active glyph reconstruction, safe display reconstruction and certified rectangle reconstruction.
- Background-only/source-ink-only descriptors preserve metadata and avoid placeholder foreground admission.
- Null-background palette acceptance/rejection without fabricating white surface evidence.
- Actual outlined source lettering, observed/source-ink hypothesis separation and outline census.
- Independent incomplete source-core evidence: safe display rejection and ordinary rectangle fallback.
- Blocked donors, unsegmented display rejection, translucent donor rejection, empty masks and invalid crops.
- Neighbor rectangle exclusions, donor-only exclusions, protected/excluded raster masks and OCR polygon ownership.
- Auxiliary/trailing rectangles, measured gradients, artwork edges and a positive source crop-edge census.

The coverage gates require both successful methods, both mask modes, an actual positive outline census, positive crop-edge detection, active ownership cases, and the expected independent incomplete/donor rejection branches. This prevents a suite consisting only of null/empty/no-op matches.

Results, full fixture/actual JSON and immutable-source provenance are written under `build/native-render-parity/forced-source-policy/`. This is helper-level native/JavaScript verification; whole-page typography and final image equality require the independent app rendering suites.
