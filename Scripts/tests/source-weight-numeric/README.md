# Isolated weight numeric prerequisites

Owned production files: `Vendor/SourceInference/Sources/SourceWeightFeatures.hpp`
and `.cpp`. This harness directory is the only additional write set. No app
activation, Xcode edit, full build, model training, model artifact changes,
Python kernel changes, GT tables, IDs, or whole-page images are involved.

Run from the Aidoku repository:

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Scripts/tests/source-weight-numeric/parity.py
```

The runner compiles only a standalone C++ harness against the existing macOS
arm64 OpenCV archive, in `TemporaryDirectory` outside shared build caches. It
includes the implementation in the harness translation unit to test private
palette argsort ordering directly. All imports disable bytecode writes. No
fonts are copied, and no models are loaded or trained.

## Implemented contracts

- `weightEstimatorExtra40`: actual estimator v5 contour rectangles, feature-major
  quantiles, nearest eligible body-center distances, counts and boundary ratios.
- `weightStroke55`: actual five masks, interior-component filtering, PRECISE L2
  ridge thickness, contour perimeter and extents; 11 scalars per mask. Uses
  max(1, scaled prior), as Python weight features does.
- `weightGrouped144`: two core masks, three closing fractions, three kernel
  orientations, explicit zero padding, Python ties-to-even radius rounding,
  component quantiles, count normalization by original bbox and boundary rates.
- `composeWeightRaw597`: 156 + 40 + 55 + 144 + 56 + 146, first six forced zero.
  Shared 156/56/146 inputs have strict lengths and finite-value validation.
- `weightDirect7`: actual `pixel_rules.observe`, including quantized top-six
  palette hypotheses, padded component distance transforms, hollow-contour
  penalty, boundary penalty, source-em normalization, quality and first-winner
  behavior. Order is `quality, glyphCount, bodyThickness, thinStroke,
  broadStroke, hollowFraction, occupancy`; chosen mask name is also returned.
- `weightFill71V1`: caller-supplied predicted alpha in crop coordinates;
  bbox recropping, 800-pixel resize, three stroke summaries, actual 32 moments,
  source palette contrast, outline/em, mass gate and full-crop ownership mean.
  Float32 pairwise summation preserves the discrete alpha-mass gate in tested
  boundary cases. Ownership must be boolean CV_8U 0/1, not 0/255.

## Oracle and observed parity (2026-11-12)

Actual unmodified Python sources used: font_weight_estimation `features.py`,
`pixel_rules.py`, `fill_body.py`; font_size_estimation `estimator.py`,
`morphology_features.py`, `glyph_body_features.py`, `font_metric_features.py`,
`optimized_features/glyph_residuals.py`. For fill only, the alpha predictor is
replaced inside the test process by the exact caller-supplied alpha; all
subsequent measurement logic is the actual Python `measure(version=1)`.
Reference font metrics use the existing `default_font_paths()` and `日あA`.
No alternate numeric fields stand in for Python fields.

35 synthetic crop cases and 210 exact palette-argsort cases passed.

| Component | Maximum absolute error |
| --- | ---: |
| extra40 | 4.440892098500626e-16 |
| stroke55 | 7.450580707946131e-10 |
| grouped144 | 1.7763568394002505e-15 |
| direct7 | 1.4901161193847656e-08 |
| fill71 v1 | 5.960464477539063e-08 |
| composed raw597 | 7.450580707946131e-10 |

Assertions use `atol=1e-7, rtol=1e-7`; palette argsort, selected mask names and
first6zero are checked exactly. This is numeric agreement within tolerance,
not bitwise floating-point equality. Python oracle: NumPy 2.2.6 ARM,
OpenCV 4.13.0; native vendor: OpenCV 4.11.0. Final isolated compile: 1.053 s;
oracle execution: 1.714 s. These are host-only results.

Coverage includes dark/light/saturated/antialiased fragmented bodies, hollow
rings, slanted polygons, clipped/fractional bboxes, 640/800 resizes, morphology
rounding, >6 equal-frequency palette modes, float32/float64 alpha, empty/full
alpha, boolean ownership, singleton dimensions, and alpha mass near one.
Every crop also checks rejection of wrong shared-vector lengths/nonfinite
values, invalid prior, outside bbox and ownership geometry mismatch.

## Remaining integration and coverage gaps

This is **not a complete native weight pipeline**. No Swift/C/ObjC bridge or
production caller is added. The caller must supply Python-equivalent native156,
glyphBody56 and fontMetrics146 for the same crop, bbox, OCR prior and text.
The raw597 test deliberately supplies those three shared vectors from Python:
it tests their layout and composition, not native extraction of those vectors.
In particular glyphBody56 MUST be measured over the entire RGB crop with
**all-ones ownership**, not the existing native OWN body signal. FontMetrics146
must use the first6zero native156. These provenance requirements cannot be
verified from a vector's length alone.

Fill alpha prediction remains the caller's responsibility using existing
segmentation/font/style information; no private font APIs are changed.
Fill version 2 is not implemented. Page context, residual/paired features,
model export/inference and render policy are outside this module. No real crop
corpus, device, iOS compiler or end-to-end production pipeline is validated.
Palette ties intentionally match the accepted NumPy 2.2.6 ARM argsort; other
NumPy releases or SIMD implementations require separate validation. Floating
point/OpenCV version differences remain subject to the stated tolerance.

NumPy sort/summation adaptations retain the NumPy BSD notice in the new `.cpp`.
Any eventual distributed binary must also reproduce that notice in its
accompanying notices. Existing OpenCV/FreeType and font notices are untouched.
