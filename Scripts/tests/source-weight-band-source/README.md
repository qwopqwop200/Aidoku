# Native source weight-band adapter oracle

New owned files only: `Vendor/SourceInference/FontWeightBandSource.h/.mm` and
this focused test directory. All existing core/features/font/native API/Swift/
renderer/build/default files remain outside this helper's write set.

Run from the Aidoku repository:

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Scripts/tests/source-weight-band-source/parity.py
```

Only a private TemporaryDirectory executable is compiled. No shared cache/app
build, downloads, model inference, GT, source IDs, real corpus, whole-page view
or font copies are involved. Existing vendored OpenCV/FreeType archives are
linked directly. No direct ICU symbols/link flags are required.

## Integration contract

```cpp
aidoku::source::measureSourceWeightBands(input, sourceFillAlpha,
    finalSourceEm, sameCallAngle131, pairs)
```

Arguments are already parsed `FontTemplateInputs`, the already computed alpha
with exactly the RGB crop's geometry, final positive source em, the angle131
from that same source measurement call, and exactly four explicit ordered
`WeightBandPair` records. The returned `WeightBandResult` contains poses192 and
bands112. No vectors, angle or alpha are inferred from another packet/call.

The parent only needs to decode the outer NSArray of reference records to the
existing C++ pair structs and call this function, then serialize its results.
No parser/bridge change is included here. RGB is used for crop/type/geometry
validation; this adapter deliberately does not predict sourceFillAlpha again.

References are accepted face0 public-TTF records: filesystem path, required
lowercase SHA256, optional weight. The helper hashes actual font bytes and
validates every face/axis/range eagerly, including references unused by empty
text/alpha. Duplicate path hashes and glyphs are cached only within this call.
There is no manifest lookup, default reference selection or substitution.

- Reference glyphs: actual `acv_glyph` at 128*64 for default coordinates, or
  `acv_reference_glyph_with_weight` for explicit weight; trim only to >40
  support, retain all grayscale pixels inside the bounding rectangle.
- Missing reference cmap entries retain **that same face's .notdef**, exactly
  as native_pairs/Pillow. They do not silently become empty or another font.
- Original anchor: resolve `input.fonts[0]` using its exact opaque key in
  `fontFiles`, `fontFaceIndices` and `fontWeights`. An absent map entry uses
  that original path/face0/default weight, never a replacement baseline font.
  Prefix/suffix aliases are map keys, not paths to heuristically parse.
- Anchors first require `acv_font_has_glyph`; unsupported is nullopt. Actual
  EM256 glyphs use >=64 coverage and sqrt(count/256**2), including optional
  baseline wght. Empty visible anchor masks are also nullopt.
- Pillow13 `setvaraxes` truncates explicit coordinates to integer design units.
  This adapter reproduces that conversion for reference and anchor rasters
  **after validating the original requested finite coordinate/axis/range**.
  The accepted production pair weights are integers. The extra 700.5 oracle
  cases cover this behavior explicitly. Existing native default/strict/16.16
  design-coordinate API behavior is untouched.

All fitting and band arithmetic delegates to the existing `FontWeightBands`
core. No alternate paired_patterns, matching, pose, witness or band math is
introduced here. UTF32 original OCR is converted losslessly to UTF8 (including
embedded NUL); the existing core owns NFC/filtering. Invalid scalar values and
resources throw std::exception. acv glyph storage uses RAII cleanup.

## Actual oracle and observed parity (2026-11-12)

Full-output fixtures use four actual accepted records from
`STRONG-NORMAL-BLACK-PAIRS.json`: NotoSansJP 700/900, RoundedMplus Bold/Black,
ZenMaru Bold/Black, NotoSerifJP 700/900. The reference digest/path/weight records
are passed unchanged. Original baseline anchor is installed Hiragino W3/face0.

Python `weight_bands.measure` and `affine_pairs.measure` are **unmodified**:
synthetic RGB + predicted ownership/style -> actual predicted_fill_alpha ->
actual anchors/native_pairs glyphs/pose fits/band stats. The same actual alpha
is supplied to the new native adapter at its required already-computed-alpha
boundary. No downstream arithmetic or callbacks are mocked or serialized into
production inputs. Native glyphs are actually rasterized through FreeType.

The standalone harness includes the new implementation in its test translation
unit to inspect its exact internal production resource provider without adding
a diagnostic public API. It separately compares those glyph bytes to actual
`native_pairs.glyph` and anchor values to Pillow >=64 EM256 metrics/cmap data.

| Check | Cases | Observed maximum absolute error |
| --- | ---: | ---: |
| Full poses192 | 31 | 0 |
| Full bands112 | 31 | 1.3877787807814457e-17 |
| Glyph pixel arrays / None | 480 | exact byte/shape equality |
| Anchor metrics / None | 60 | 0 |
| Legacy default/strict/reference unsupported behavior | 1 | exact expected behavior |
| Invalid resources/geometry | 12 | all rejected |

Discrete pose scale, aspect, angle, gate/presence and visibility slots are also
asserted exactly. Other outputs use atol/rtol 2e-6; observed errors are above.
Python Pillow13.0.0/FreeType2.14.3/OpenCV4.13.0; native FreeType2.14.3/OpenCV4.11.0.
Private compile **3.507 s**, complete native harness **5.021 s**, including JSON,
SHA validation and diagnostic/resource/invalid-input tests; not device timing.

Coverage: all four pairs/both weights, dark/pale/color predicted alpha, source
angles, .1 threshold crossing, >480 resize, fractional bbox, empty/excluded/
small-kana/NFC/decomposed/supplementary/unsupported text, explicit prefix anchor
aliases and plain path fallback, nonzero TTC face, default and fractional
variable weights, same-face .notdef vs strict rejection, wrong/malformed digest,
missing files, wrong identity bytes, invalid weight range, weight on static
font, invalid anchor face and alpha geometry. A valid call after invalid ones
also verifies failures do not poison subsequent resources.

## Remaining prerequisites / gaps

Parent still owns the outer reference decoder, producer call, same-call angle
and final-em provenance, and production serialization/feature graph wiring.
The helper cannot prove provenance from scalar arguments or certify a crop's
origin; it relies on the already parsed bounded source contract.

The test passes real Python-predicted alpha into the adapter; it does not
independently revalidate the native sourceFillAlpha producer in this task.
No existing source/template implementations are linked just to recreate alpha.
Weighted/nonzero-face anchor diagnostics verify resource handling, while the
full unmodified Python measurement oracle uses the original W3 baseline.
This is host-only numeric/resource parity, not an iOS/device/runtime-model or
end-to-end renderer pass. The core's documented Unicode-version and bounded
em/angle/glyph-size limits still apply. Pillow coordinate conversion is pinned
to the observed Pillow13 oracle and must be revisited if that runtime changes.
