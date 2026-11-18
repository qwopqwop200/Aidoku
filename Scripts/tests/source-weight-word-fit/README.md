# Whole-string reference grids and equal-budget word fits

New owned production files:

- `Vendor/SourceInference/SourceWeightReferenceGrid.h/.mm`
- `Vendor/SourceInference/SourceWeightWordFit.h/.mm`

This directory is the only additional write set. No existing files were edited;
no new NativeCV API was necessary. Existing default/strict/reference glyph APIs,
fonts, core math, source-band helper, Swift/model pipeline, defaults, decoder and
renderer remain outside this task's write set. No model, training, GT, token/
region-ID rule, artificial word splitting, font copies or whole-page view exists.

Run from the Aidoku repository:

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Scripts/tests/source-weight-word-fit/parity.py
```

The harness compiles only its main, the two new implementation files and the
existing NativeSourceCV.cpp against the provisioned static OpenCV/FreeType
archives in a private TemporaryDirectory. It never invokes shared build caches,
Xcode/app builds, downloads or a producer/profile pipeline. Tests use actual
Pillow fonts, not serialized/mock downstream glyphs or fitting calculations.

## API and source contract

`SourceWeightReferenceGrid` owns one operation's SHA256/cmap/glyph/render cache.
Explicit `WordReferencePair` holds a family grouping name, two `WeightBandFont`
records and an optional shared frame pair. Names only group supplied reference
families; they are not features or text/source classification rules. Every font
is face0 of the supplied public font file, SHA256 checked against actual bytes,
with optional explicit wght. No font/path resolver or fallback is present.

- `wordMasks(pair, text, vertical, tracking)` ports `word_pairs.word_masks`:
  advances are the per-character maximum of the two faces; union trim is >32.
  Vertical text uses the native_pairs >40-trimmed glyph and independent cell
  centering, including the exact vertical punctuation rotation set.
- `masks(...)` ports `reference_grid.masks`: advances and >0 union bounds come
  from the explicit common frame pair (the pair itself if absent). Both selected
  weights retain these exact bounds. Vertical text uses full 3em cells and ms
  baseline origins; clockwise punctuation rotation preserves cell bearings,
  and ImageChops.lighter overlap is reproduced.
- All glyphs are actual EM128 FreeType rasters with hinted advances, bearings
  and baseline. Optional weights follow the Pillow13 integer-axis conversion,
  validated for the original finite coordinate/axis/range. Cmap-missing text
  returns None (the whole-string Python renderers require support in all faces).
- Horizontal ImageDraw uses float32 fractional starts, 26.6 rounding then PIXEL
  quantization. The implementation retains the unrounded accumulated advances
  and reproduces that phase and L-mode compositing, rather than rounding the
  reference mask placement or translating a trimmed glyph arbitrarily.
- `transformSourceWeightWord` ports ties-to-even target sizes, cross-axis scale,
  INTER_AREA, pad and rigid linear/border-zero rotation from word_pairs.transform.
- `nominalWeight` returns the explicit axis coordinate, otherwise reads actual
  OS/2 usWeightClass metadata. Metadata access never changes the rasterizer.

Renderer outputs share the session's immutable cache; callers must clone before
mutation. Caches are neither static nor shared across sessions. Renderer input
is the exact whole string; it does not normalize, filter or split it. This is
important for faithfully retaining punctuation/combining glyph geometry.

`PreparedSourceWeightWord` represents an **already prepared** observation:
NFC/whitespace-removed original OCR, float32 observation values (not the frozen
pose alpha), boolean CV_8U 0/1 known map, orientation, source/box extents and unit.
Caller owns preparation/provenance. Reuse the existing same-source font,
segmentation and RF observations when preparing values, known support and
reference context; this helper does not replace or recompute that evidence.
The helper does not manufacture inputs from a source crop, estimate a profile
or invoke a model.

`correlateSourceWeightWord` and `locateSourceWeightWord` port masked_word_pairs:
CCORR cross/observed source/reference energy, foreground support >=.3,
float32 divide/sqrt/clip/finite gates, stronger regular OR heavy objective,
and first row-major maximum. Unknown pixels contribute neither known background
nor source energy. Oversized/non-fitting/negative-score patterns return no match.

`fitSourceWeightWord(prepared, pair, session, refine, renderer)` returns the exact
32-field masked_word_pairs.fit row. It uses full-string geometry to derive the
four sorted/unique scale hypotheses, optional punctuation/symbol end-trim variant,
exact cross/scale gates and first-winner updates. Refinement uses the frozen
coarse scale across tracking .9/1/1.1 x factors .975/1/1.025 x cross .9/1/1.1,
then the selected tracking/scale/cross at rotations -4/+4. No outcome-dependent
extra search is granted to either face. Observed differential band fields and
unknown-support coverage are included; this is not a stroke/profile producer.

`fairSourceWeightFaceFits(prepared, intervals)` ports
`reference_ink_weight.fair_face_fits`:

1. Build per-family common normal (<=400) / heaviest frames from actual interval
   endpoints, preserving Python's insertion/last-normal/first-maximum rules.
2. Deduplicate faces stably by (path, digest, nominal weight), then fit each face
   independently against itself in that family's shared frame.
3. Stably rank valid normal and heavy candidates independently. Refine up to
   **two per class**, with exactly the same refinement schedule/cap; return only
   these refined candidates, normal class then heavy class. No refined-heavy vs
   unrefined-normal comparison is returned. As in Python, a class with fewer
   valid competitors is not padded with synthetic candidates.

API validation bounds: renderer text <=128 scalars/tracking (0,4], <=32Mi-pixel
canvas; prepared fit text 2..32 scalars and positive finite source extents/unit
<=1e6; transform scale (0,16], cross (0,4], abs(angle)<=360; <=32 reference
intervals per fair comparison. Genuine source-local inputs normally lie far
inside these bounds. Invalid SHA, unavailable font/axis or invalid geometry
throws std::exception; no alternate measurement is substituted.

## Actual unmodified Python oracle, 2026-11-12

Functions used directly without monkeypatches:
`word_pairs.word_masks/transform`, `reference_grid.masks`,
`masked_word_pairs.correlation/locate/fit`, `reference_ink_weight.fair_face_fits`,
`observed_weight_bands.band_stats`, `native_pairs.reference_font/glyph`,
`word_weight_summary.weight_intervals` and actual Pillow ImageDraw.

References are the installed explicit accepted `WORD-PAIRS.json` and `PAIRS.json`
records, with normal/strong/heavy intervals and common frames for NotoSansJP,
RoundedMplus, ZenMaru and NotoSerifJP. Static nominal weights come from real OS/2;
variable weights use actual FreeType variation coordinates, no synthetic bold.

| Check | Cases | Maximum absolute error |
| --- | ---: | ---: |
| Word/shared-grid masks and transforms | 722 | **0**, exact shapes/pixels |
| Complete masked correlation map | 9 | **0** |
| Shared-location scores and x/y | 9 | exact |
| Prepared full 32-field fits | 33 | combined fit maximum below |
| Equal-budget independently refined face comparisons | 9 | **3.9968028886505635e-15**, combined fit maximum |
| Invalid reference SHA/path/weight | 3 | all rejected |

Scale/cross/tracking/rotation/coverage/orientation/presence slots are additionally
asserted **exactly**, as are ordered fair face family/nominal-weight choices and
location x/y. Other fit arithmetic uses atol/rtol 2e-6; the observed tiny residual
comes from float64 reduction order in observed band statistics. No raster or
selected-pose mismatch was observed. Raster checks themselves allow zero error.

Coverage includes horizontal/vertical kana/Han/Latin/accents/combining glyphs,
negative bearings, spaces, small kana and rotated punctuation; unsupported
supplementary/cmap text returns None; tracking .9/1/1.1; independent selected
faces rendered in common 400/900 frames; exact fractional phase probes .49,
.49218749, .4921875 and .5; cross-axis transforms and +/-4 rotations; visible and
unknown ink, no support, same-size/oversized patterns, normal/heavy synthetic
font-alpha sources, trim variants, coarse/refined fits and stable duplicate
interval deduplication. No source strings determine a policy or candidate budget.

Latest focused rerun: private host compile **3.155 s**; complete native harness **4.220 s**, including
JSON/render diagnostics/all checks, not per-crop/device timing. Native OpenCV
4.11.0/FreeType2.14.3; Python OpenCV4.13.0/Pillow13.0.0/FreeType2.14.3.

## Gaps and integration handoff

The actual accepted Pillow runtime has **BASIC layout, RAQM unavailable**. Exact
raster agreement is established for that environment and tested references.
A Pillow build with RAQM/HarfBuzz shaping or different font raster versions is
not claimed equivalent. Fractional start behavior follows Pillow13 getmask2/
ImageDraw; it must be revalidated after runtime changes. Public Foundation
punctuation/symbol Unicode data can differ for newly assigned characters.

No new NativeCV origin API or change to any existing glyph behavior was needed.
No complete source crop producer, palette/known-map reconstruction, profile/SWT/
registered/soft evidence, member sorting/pooling, profile policy, decoder, Swift
connection, model/GT pipeline, real-crop corpus or iOS/device validation is part
of this task. Parent supplies the correctly prepared observation and explicit
reference intervals/frame context and owns production integration. Numeric
agreement here does not certify those future producers or any rendering policy.
