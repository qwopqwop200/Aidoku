# Isolated paired48 physical weight oracle

Production additions are only `Vendor/SourceInference/FontWeightPhysical.h/.mm`.
No existing features, native header, fonts, resolver, core math, Swift graph,
renderer, defaults, build settings or Python kernels are modified.

From the Aidoku repository:

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Scripts/tests/source-weight-physical/parity.py
```

The runner compiles only its `main.mm`, the new implementation and existing
`NativeSourceCV.cpp` against the provisioned macOS arm64 OpenCV/FreeType static
archives in a private `TemporaryDirectory`. No shared build/cache, app build,
model, source IDs, GT, training, whole-page input or real corpus is involved.

## Call contract

`aidoku::measureFontWeightPhysical(rgb, bbox, sourceEm, utf8Text, pairs)` returns
`std::array<double,48>` and throws `std::exception` on invalid inputs/native
errors. The RGB input is CV_8UC3 (RGB order, arbitrary valid OpenCV stride),
with bounded source-local context up to 15% per side (one pixel tolerance).
The xywh bbox uses original crop pixels, as does finite positive sourceEm.
Caller owns source-local provenance; dimensions cannot prove the crop's origin.

Supply exactly three ordered explicit filesystem path/faceIndex pairs:

1. Hiragino Kaku Gothic W3/0 and W6/0.
2. The same W6/0 and W9/0.
3. Hiragino Mincho ProN/0 and the same collection/2.

The function checks indices and shared pair paths; caller is responsible for
those paths naming the specified installed fonts. There is no font discovery,
filename-based resolution, substitution, CoreText fallback or copied font.
`acv_glyph` receives **128 * 64** directly; EM256 is never requested.

Production scales are fixed `.85,.95,1,1.05,1.15` with no API override. Crop
slicing, <=360 target resize (using original fx/fy), RGB gray/Otsu, strict pale
and chroma masks, >40 glyph trimming, Python ties-to-even pattern dimensions,
center padding and float32 correlations follow `physical_templates.measure`.
Joint scores select a single shared location for regular/heavy. Strict greater
replacement preserves first scale, mask and row-major location ties.

Text is NFC normalized and deduplicated by Unicode scalar. Only letter/number
categories survive. Kana is U+3040..U+30FF; the other group is non-kana. Each
group selects the maximum (W3 thresholded glyph area, scalar) tuple, matching
Python's reverse tuple sort. Thus each group has at most one observation and
its median is exactly that observation. Pair-major/group-major slots are:
`joint, regular, heavy, heavy-regular, scale, count, joint>.5, joint>.7`.
Empty, blank or non-fitting groups produce eight exact zeros.

## Executed parity, 2026-11-12

Unmodified oracle: `physical_templates.measure(scales=source_runtime.PAIRED_SCALES)`.
Python OpenCV 4.13.0 versus native vendored 4.11.0; FreeType 2.14.3.

- 73 synthetic crops, all 48 values: maximum absolute error **0.0**.
- Scale/count/gate slots additionally asserted exactly, including zero slots.
- 5 invalid-input rejections: nonpositive EM, excessive context, wrong Mincho
  index and missing font path.
- Private standalone compile: **1.974 s**; native execution: **5.331 s**.

Coverage includes all five font faces, three mask colors, small/medium/large
EM, constant masks and first ties, tiny/non-fitting targets, fractional and
negative clipped bboxes, <=360 resize in both orientations, seeded noise,
empty/punctuation/mark/symbol text, single groups, repeated text, decomposed
NFC text, supplementary-plane numbers and an unsupported-codepoint case.
Assertions permit atol/rtol 2e-6 for correlations across OpenCV versions, while
the observed run was exactly equal. This is focused host parity, not a universal
bitwise guarantee. Foundation NFC and system ICU category data can differ from
Python Unicode versions for newly assigned characters; tested strings agree.

No real crop corpus, iOS compile/device, production integration, model inference
or end-to-end rendering was run. Parent owns wiring and those validations.

Integration note: Unicode L/N selection now uses public Foundation
alphanumericCharacterSet minus nonBaseCharacterSet. The 73 cases and5 rejection
controls were rerun with exact48-slot parity and without a libicucore link.
Platform/Python Unicode-version differences remain outside that fixed fixture.
