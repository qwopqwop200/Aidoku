# Bounded source-weight bridge prerequisites

Production files: `../FontWeightFeatures.h`, `../FontWeightFeatures.mm`, and the
minimal helper declarations/implementation in `../FontTemplateFeatures.h/.mm`.
The existing `Sources/SourceWeightFeatures.hpp/.cpp` and all Python numeric
kernels are unchanged. No Swift graph, app build configuration or production
activation is changed here.

## Contract

`AIDExtractSourceWeightSignals(packet, NSError **)` returns NSNumber arrays
`raw597` (597), `direct7` (7), and `fill71` (71, Python fill version **1**).
Failures return nil and an optional NSError in `Aidoku.SourceWeightMeasurements`.

The packet uses the existing FontTemplateFeatures dictionary decoder:
`rgb`/`ownership` NSData, positive `width`/`height`, optional byte strides,
`bbox` xywh in the bounded RGB crop, original OCR `prior`/`text`, source-predicted
`style`, and `measurementSpec` with the existing pinned4/8/4 font lists. Crop
context is at most 15% per side (existing decoder's one-pixel tolerance).
`sourceEm` is additionally required, finite and positive.

- Raw uses fresh same-crop native156 with first6zero, existing extra40/stroke55/
  grouped144, glyphBody56 with an independently allocated all-ones mask over
  the **entire RGB crop**, and fontMetrics146 from original normalized OCR text
  and first6zero native156. Supplied `native156`/`native` fields are ignored.
- Direct uses original OCR prior, in existing DIRECT_KEYS order: quality,
  glyphCount, bodyThickness, thinStroke, broadStroke, hollowFraction, occupancy.
- Fill uses actual source ownership/style via `sourceFillAlpha`, then
  `weightFill71V1` with **final sourceEm**, bbox recropping and boolean ownership.
- The minimal helper computes only the three shared basics. It shares native
  FreeType rasterization with the font path; no templates, high-order fitting,
  models, labels, source IDs or page summaries are evaluated.

## Executed host validation (2026-11-12)

From the Aidoku repository:

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python \
  Vendor/SourceInference/Tests/verify_weight_bridge.py
```

The new standalone Objective-C++ harness is `FontWeightFeaturesMain.mm`.
Compilation/linking uses only its explicitly listed native source closure and
existing macOS OpenCV/FreeType static archives in a TemporaryDirectory; no full
or shared-cache build. Actual unmodified Python `features.measure`,
`pixel_rules.observe`, and `fill_body.measure(version=1)` are the oracles.
In particular fill's real `predicted_fill_alpha` is **not patched**.

70 synthetic bounded packets passed `atol=1e-7, rtol=1e-7`:

| Array | Maximum absolute error |
| --- | ---: |
| raw597 | 7.450580707946131e-10 |
| direct7 | 8.344650265224018e-08 |
| fill71 | 2.7755575615628914e-17 |

First six zeros and ownership-invariance of raw/direct are checked exactly.
Paired sparse/all-ones ownership also exercises preservation of the actual
ownership used by fill. Tests include 0/1 and 0/255 packets, final em distinct
from prior, deliberately stale supplied native156, fractional crop bounds,
640/800 resize cases, palette ties, dark/light/colored/blank/singleton RGB,
and NFC/whitespace/empty OCR text. Each packet rejects missing/nonpositive/
nonfinite/non-numeric final em, GT-mask flags, ownership geometry mismatch and
invalid bbox; nil error sinks and NSError lifetime are exercised.

Final isolated source compile/link: 7.153 s. Native execution including admission
controls: 0.888 s. Python oracle uses NumPy 2.2.6 ARM/OpenCV 4.13.0; native OpenCV
is vendor 4.11.0. This establishes numeric tolerance parity, not bitwise equality.

## Remaining gaps

No measured parity failures remain in this bounded synthetic set. Real-crop
corpus, whole pages, iOS/device compilation/performance, font resource mismatch
across OS versions, and alternate NumPy palette-tie behavior are unvalidated.
The inherited decoder still requires full4/8/4 measurementSpec lists even though
this path rasterizes only the four baseline metric fonts. Test extended/native
lists intentionally reuse baseline faces; these lists have no numeric role here.
Fill v2, paired/page features, trained weight inference, Swift graph integration,
parent Python integration and final rendering policy remain outside this bridge.

## Integrated paired48 bridge (2026-11-12)

The same dictionary bridge now optionally consumes `physicalFontPairs` and
returns actual same-RGB/final-em paired48. The integration oracle supplies all
three actual Hiragino pairs and compares raw597/direct7/fill71/paired48 over
70 bounded synthetic packets. All passed; paired48 maximum error0, raw
7.45e-10, direct8.34e-8, fill2.78e-17. Isolated compile10.236s, native3.042s.
The physical module uses public Foundation character sets for L/N filtering;
no direct ICU symbol or additional ICU link dependency is required. Its separate
73-case oracle and5 rejection controls also passed after that integration.
This remains host-only numeric evidence, not end-to-end weight activation.

## Dedicated raw597-only sibling (2026-11-17)

`AIDExtractSourceWeightRaw597(packet, NSError **)` returns only `raw597`.
The original `AIDExtractSourceWeightSignals` implementation is unchanged.
The sibling uses the same dictionary decoder and basic-feature validator,
including real ownership/style, positive finite `sourceEm`, and pinned4/8/4
font banks. `sourceEm` is an admission requirement only in this sibling; its
numeric raw597 authority remains the original constructor `prior` and text.
The single-BODY Swift caller supplies that actual original prior as `sourceEm`.
No fake accepted font, source paint, mask or extra font list is manufactured.

It skips `direct7`, `sourceFillAlpha`, `fill71`, and mixed-palette arithmetic.
Requests containing `weightMemberPolygons`, `sourceAngle`, `physicalFontPairs`
or `referencePairs` are rejected, rather than silently claiming those optional
measurements. The legacy API retains all its existing optional behavior.

Focused command, private temporary native build only:

```sh
.venv-source-inference/bin/python Vendor/SourceInference/Tests/verify_weight_raw597.py
```

Executed70 bounded synthetic cases: dedicated and generic raw597 arrays match
exactly; maximum absolute difference against the original Python raw597 oracle
is7.450580707946131e-10 (atol/rtol1e-7). Each case checks22 required rejection
controls with equal generic/dedicated error messages, plus4 explicit unsupported
optional-key rejections. First6zero and ownership invariance are checked.
Private compile8.505s; native run1.401s. No models, core NN or shared build ran.

The updated actual Swift helper was separately replayed on619 nonempty cached
pages/4047 actual cached raw597 rows with the real BODY forest and page math:
probability difference0, label mismatches0. This is numeric-model replay, not
fresh real-crop extraction evidence. Fresh runtime extraction, integrated
macOS/iOS builds and end-to-end source/display behavior remain root-owned
validation boundaries. Only baseline4 fonts are numerically rasterized, but
the unchanged decoder still admits/verifies full4/8/4 font resources.

Follow-up admission-vs-calculation controls independently doubled valid
`sourceEm` and changed valid source style RGB/presence/width in every case:
all raw597 arrays stayed exactly equal. Sparse/full ownership invariance is
also exact across35 paired cases. Private compile9.778s/run2.416s for this
expanded control set. The real public Swift module declaration also passed:

```sh
xcrun swiftc -swift-version 6 -warnings-as-errors -typecheck \
  -I Vendor/NativeSourceCV/include \
  Vendor/SourceInference/Tests/CheckRaw597Import.swift
```

Two further controls replace one baseline path with a SHA descriptor carrying
the wrong hash or a missing font file. Both dedicated/generic APIs reject them
with equal error messages. Ordinary path-only synthetic cases do not include
production per-crop hashing cost; none of these isolated times is an E2E or
on-device speedup measurement. Required full4/8/4 descriptor admission remains
unchanged, including repeated pin verification when hashes are supplied.
