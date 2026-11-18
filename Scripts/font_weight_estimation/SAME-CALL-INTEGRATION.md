# Same-call model observations

`inpainting_compare.font_weight_runtime.estimate_page` accepts
`source_context=SourceFontContext` together with an already loaded trusted
`weight_bundle`. The full peer batch is passed to `source_runtime.infer_page`;
original priors and final estimated ems retain their separate units/contracts.
No classifier is fitted and no GT weight fields are read.

Each `SourceFontObservations` carries original word observations (an explicitly
empty sequence is valid), glyph observations and RF observations. Both array
records contain `sourceSHA256`, `GTMaskUsed: false`, page-space integer LTRB
`cropBounds`, RGB uint8 `rgb`, `sourceRGBSHA256` of raw RGB bytes, and boolean
`valid`. Glyphs contain `primary`, `boundary`, `native`; RF contains `rf` with
27 channels and `rfModelWeightsSHA256`. Arrays are aligned by page coordinates;
unobserved margins remain invalid, never background evidence.

Actual original word records carry `sourceSHA256`, `sourceIndex`, `text`, bbox
XYWH and polygon. `coordinateSpace` is `page`, or `crop` with that word's own
page-space `cropBounds`. No paragraph-to-word splitting is performed.

The adapter verifies source hashes, original image crops, array geometry,
packet order/owner IDs, original priors/final ems and word bbox/polygon agreement
before publishing any typography changes. Mixed source weight remains regular
for the whole translation without actual translated span alignment.

This is an explicit Python inference entry, not default production activation.
The prepare command now supplies actual original word observations and authenticated
existing glyph/RF outputs with an explicitly selected frozen weight package. Default
activation remains pending whole-corpus verification. Native font estimation now exposes the same call's packets,
style187, angles131, priors and final ems; native operational predict retains
this context. Native weight feature/raster/policy execution and final typography
consumption remain separate unfinished work. An OWN erasure mask is never a
substitute for primary/boundary/native/RF evidence.

Focused checks:

```sh
.venv-source-inference/bin/python -m unittest discover \
  -s Scripts/font_weight_estimation -p test_font_context_adapter.py
python3 Scripts/tests/run-native-source-font-context-smoke.py
```

The Swift harness isolates the font-estimation boundary with graph/measurement
stubs. Its success does not certify native end-to-end model accuracy or iOS.

Font estimator geometry is preserved exactly as supplied by the caller. Weight
residual geometry uses recognized-word polygons; a262-wide source-font residual
is reused only when these geometries match. Otherwise the exact weight residual
is freshly remeasured with the original prior and original pixel/paint/mask data.
The source-font final em still comes from the same estimator call. Its original
reference prior in the review producer is the appearance localization inventory's
fontPixels hint, not freshly recomputed OCR and not a new font-size GT lookup.

The optional measurement observer retains same-call raw/fill/band arrays in memory.
A sampled confidence envelope tests one source-font bin (two pixels), opening
only independently corroborated central-image gates. It cannot promote a
confidence-only polarity decision. The earlier unanimous-em control was rejected
and removed from runtime after it lost real bold examples. No trained weights
were changed by these integration corrections.
