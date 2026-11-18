# Isolated source affine poses and differential weight bands

Owned additions only:

- `Vendor/SourceInference/FontWeightBands.h/.mm`
- This focused standalone harness directory.

No existing math, fonts, Python kernels, NativeCV/FontTemplateFeatures headers,
physical48, Swift graphs, renderer, defaults or build configuration is modified.
No GT, model inference, training, whole-page inputs or real corpus are used.

Run from the Aidoku repository:

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Scripts/tests/source-weight-bands/parity.py
```

The harness privately compiles only `main.mm` and `FontWeightBands.mm` against
the provisioned macOS arm64 OpenCV archive in `TemporaryDirectory`. It does not
invoke native-source-cv/build.py, Xcode, shared builds/caches, FreeType or ICU.
Only public Foundation character APIs are used by the new core; there is no
`u_charType` reference or `-licucore` link dependency.

## Caller prerequisites and API

`aidoku::measureFontWeightBands(alpha, bbox, angle, sourceEm, text, pairs,
glyph, anchor, optionalPoses)` returns `WeightBandResult`:

- `poses`: 192 doubles, four pairs x kana/non-kana x 24, exact affine_pairs layout.
- `bands`: 112 doubles, four pairs x kana/non-kana x 14, exact weight_bands layout.

`confirmFontWeightBands(bands, policy)` is the pure source measurement runtime
confirmation. The policy is supplied explicitly; no policy/default/model is
installed. It chooses the first maximum slot12, then applies inclusive added
stem, common body, glyph fit and reconstruction error comparisons.

The caller must provide all of the following:

1. Source-predicted fill alpha over the **bounded source-local crop**, in [0,1],
   CV_32F or CV_64F, and source bbox/angle/final sourceEm/original UTF-8 OCR text.
   The core does **not** predict alpha, obtain ownership/style, certify crop
   origin, or slice alpha to bbox again. Python uses bbox only for the discarded
   rotated-bbox return; alpha is rotated in its complete local frame.
2. Exactly four explicit regular/heavy `WeightBandPair` records in production
   order, with path/SHA256/optional variable weight. These descriptors are
   passed unchanged to the caller's glyph provider. No resolver/fallback exists.
3. `WeightBandGlyph`: returns exactly `native_pairs.glyph(record,char)` pixels,
   actual EM128 uint8 glyph trimmed to the >40 support rectangle (retaining
   interior antialiasing), or empty for Python None. Provider owns digest and
   variable-axis handling. In particular, coverage must follow native_pairs'
   actual glyph semantics; don't replace its unsupported glyph with a new rule.
4. `WeightBandAnchor`: exact `glyph_measurement(default_font_paths()[0],char)[4]`
   or nullopt. This is **separate** W3/face0 EM256 cmap-supported >=64 coverage,
   sqrt(area)/256. EM128 fitting glyph area is not an equivalent anchor metric.

Callbacks may cache their resources; the core caches per-face/per-scalar fitting
rasters during a measurement. No token identity leaves the returned features.
The bounded API currently admits sourceEm/unit <=4096, angle within +/-360,
and glyph sides <=4096. Supplied poses must follow the genuine affine transform
contract (factor/aspect positive and <=2, normalized angle within +/-90).
Failures throw `std::exception`; no alternate measurements are substituted.

NFC plus public Foundation alphanumericCharacterSet minus nonBaseCharacterSet
implements L/N filtering. Small kana are excluded, metrics <=.05 are discarded,
anchors sort by descending metric then ascending scalar with a **global** 256
limit, then the first two witnesses per kana/non-kana group are used.
Foundation/Python Unicode versions may differ for newly assigned scalars.

## Exact numeric behavior

- Rotate full alpha only when abs(angle)>.1, resize longest side to <=480 with
  original fx/fy, then cast to float32. Alpha mass<1 zeros affine observations.
- Physical paired_patterns: uint8 INTER_AREA at actual EM128 ratios, Python
  ties-to-even dimensions/padding, float32 /255, independent centered faces.
- Fixed scales .85/.95/1/1.05/1.15. Objective is stronger regular **OR** heavy
  correlation at one shared location, not the mean. Strict greater replacement
  preserves scale/location/witness ties. Refinement uses only the winning
  coarse factor, aspect .9/1/1.1 and angles -4/0/4, and occurs only below .85.
- Source/template dice, float32 mass sums, log ratios, precise distance-transform
  ridge median strokes and affine witness median/mean aggregates are measured.
  Zero non-fitting fits still participate in witness aggregates as in Python.
- Band witness recovery minimizes (abs(score-poseScore), -score), preserving the
  first candidate on exact ties. It is not an independent strongest-fit choice.
- Band coefficients/energy/errors/common/plus/minus masks and linear quantiles
  use float64, including energy<1 and missing support zero slots.

Standalone `fitFontWeightAffine` and `fontWeightBandStats` also expose the actual
numeric kernels for callers/focused oracle coverage, without alternate math.
Float reduction follows NumPy's pairwise and noncontiguous-buffer semantics.
The implementation retains NumPy's BSD notice; distribution of derived binaries
must reproduce it in accompanying notices. Existing font/OpenCV notices remain.

## Executed oracle parity (2026-11-12)

Actual unmodified downstream Python: `affine_pairs.measure/fit`,
`weight_bands.measure/band_stats/confirmation`, `physical_templates.paired_patterns`,
`native_pairs.glyph`, `features.stroke_summary`, `anchor_chars/glyph_measurement`.
Only predicted_fill_alpha is injected at the **caller alpha boundary** in the
Python test process. No downstream fits, anchor calculations, rasters, poses,
stats or confirmations are mocked. C++ callbacks receive serialized results of
actual native_pairs.glyph and actual W3 anchor metrics, not substitute images.
Four pairs are the explicit `STRONG-NORMAL-BLACK-PAIRS.json` source reference
records: NotoSansJP, RoundedMplus, ZenMaru, NotoSerifJP (two variable families).

| Check | Cases | Maximum absolute error |
| --- | ---: | ---: |
| Complete affine poses (192) | 36 | 1.3877787807814457e-17 |
| Complete bands (112) | 36 | 5.551115123125783e-17 |
| Standalone affine fit (24) | 16 | 0 |
| Standalone band stats (14) | 19 | 6.544631658365738e-26 |
| Runtime confirmation | 14 + all 36 measurements | exact boolean agreement |
| Invalid input | 5 | all rejected |

Discrete scale, aspect, angle, presence/gate and witness visibility slots are
asserted **exactly**, separately from correlations/statistics (atol/rtol 2e-6).
Returned confirmation booleans are exact. Numeric agreement is not a universal
bitwise guarantee: native OpenCV is 4.11.0 and Python OpenCV is 4.13.0.

Coverage includes all four families/both weights, both witness groups, stronger
OR heavy matches, exact coarse fits and uncertain refinements, all five scales,
constant-mask first ties, unavailable/non-fitting groups, small kana/excluded
symbols, repeated/NFC/decomposed/supplementary text, >256 global anchors,
source rotation threshold, float32/64 alpha, >480 resize in two orientations,
fractional bbox, mass around one, external pose-equality witness selection,
energy around one, coefficient clipping, quantiles and policy boundary ties.

Private host compile **2.189 s**; complete native harness execution **3.461 s**
(including fixture JSON parsing and direct tests; not per-crop device timing).
No shared/app builds were performed.

## Remaining integration limits

Parent must supply production sourceFillAlpha, correct native source-font
EM128 rasterization (including variable weights), and the separate W3 anchor
metric provider. Their native extraction parity is **not** established by this
callback-fed harness. The new core deliberately does not depend on a concurrent
variable-font worker. Parent owns feature-producer wiring and policy plumbing.
No real crop corpus, iOS compile/device timing or end-to-end model/rendering
validation is claimed. Runtime validation here covers confirmation arithmetic,
not model inference or complete `runtime.predict_band_page` execution.
