# Source word observations: reference, soft and optional ordered evidence

Owned additions only:

- `Vendor/SourceInference/SourceWeightWordObservations.h/.mm`
- This focused parity harness directory.

Production source/header are stable and ready for parent integration. No existing
implementation, parent bridge, ordered glyph module, Swift/model orchestration,
policy/default, font or NativeCV API was modified. No shared/app build was run.

## Public entry

```cpp
auto result = aidoku::source::observeSourceWeightWords(
    input, originalWords, explicitPairs,
    aidoku::source::SourceWeightWordObservationPaths::Both,
    includeOrdered /* defaults false */);
```

`SourceWeightInkInput` must contain the **existing** RGB, ownership, valid,
primary, boundary, native and RF27 arrays, source paint, and finite positive
**final** `sourceEm`. Reconstruction cutoff is fixed .5 as in Python source
observe; another cutoff is rejected rather than silently changing measurements.
There are no model calls or glyph/segmentation/RF re-inference. Existing arrays
are borrowed/read only, including noncontiguous row-stride inputs.

Recognized words are original `bbox` xywh, original UTF32 text and optional
polygon in the same source-local crop coordinates. There are no token/ID rules,
new word splitting, region lookup or manufactured members. Explicit reference
intervals use the same `WordReferencePair` contract as the existing fair fitter.

The result has `referenceWords`, `softWords`, `expectedReferenceWordCount` and
`expectedSoftWordCount`. `orderedGlyphsImplemented` is true; optional per-soft-
word `orderedGlyphs` is absent unless includeOrdered is requested. Parent owns
ObjC dictionary conversion, mixed detection, confidence/scale/image policies,
soft-glyph conflict veto and all Swift/model decisions. This helper never applies
eligibility/rescue/acceptance rules from Python infer_page wrappers.

## Exact field serialization contract

Reference words mirror `reference_ink_weight.measure()['words']`:

`templateFit, estimatedVisualWeight, matchedReferenceWeight,
bestRegularTemplateFit, normalTemplateMargin, weightFraction, fractionSpread,
registeredStrokeProfile, sourceWidthsPx, regularWidthsPx, heavyWidthsPx,
visibleSourceFraction, referenceFamily`.

`visibleSourceFraction` is the **entire prepared word known-map mean**, not the
final matching/profile ROI mean. Stroke/profile measurements use their actual
matched ROI. These scopes are intentionally different in the Python oracle.

Soft words mirror `soft_ink_source.observe()['words']`: flatten the typed
`profile` fields into the word and add `matchedWeight, templateFit,
normalTemplateMargin, referenceFamily`; add `orderedGlyphs` only if present.
For the enclosing Python soft observation use `expectedWordCount` equal to
`expectedSoftWordCount`. Reference top-level method/boolean metadata may be
added by the parent bridge; the typed helper returns the physical observations.

Registered/soft profile keys follow the existing profile module exactly:
`correspondingCentres, informativeCentres, newModelCreated,
modelTrainingPerformed, usable`; soft also has `alphaLevels`. Serialize the six
measurement fields **only when measurements is present**. An unusable result
must not fabricate zero/null numeric evidence.

Optional ordered observations are produced by the parent's existing
`measureSourceWeightOrderedGlyphs(..., softProfile=true)`. Pass the reconstructed
word source/valid **before the final matching ROI**, normalized complete text,
orientation, unit and winning family **common normal/heaviest frame**. No
independent profile mask/crop is substituted. The harness compares actual
ordered output keys, glyph intervals and profiles against unmodified Python;
parent owns the ordered implementation and its separate 34-case verification.

## Production flow

1. Existing `reconstructSourceWeightInk(ColorConsistent)` runs once per source,
   using original glyph/native/seg/RF/paint evidence. Existing style cleaning and
   palette observations are reused; no replacement source mask is inferred.
2. Reference members use original-order spread6 (`np.linspace(...).astype(int)`)
   if there are more than six; soft members use the original first6. Expected
   counts include original selected members even if a member produces no word.
3. Use the exact bbox +/-10% bounded context and polygon pose_angle. Normalize
   original text to NFC, remove Python whitespace, retain whole-word geometry.
4. `prepareSourceWeightPaletteWord` ports palette_word_pairs.prepare_palette:
   primary/alternate predicted fill only initializes geometry; rotate and <=640
   resize use Python's exact order, spans, bbox axes and unit. Palette values and
   known support use the **existing** SourceWeightInk palette implementation.
5. Crop/rotate reconstructed source and valid maps, area-resize to prepared
   geometry only if needed, with known footprints required >.99. Derive spans
   from reconstructed >.5 AND known pixels and replace prepared fit evidence.
6. Existing `fairSourceWeightFaceFits` independently fits normal/heavy faces
   with the same budgets. Stable first maximum chooses the winner; use its
   common family frame, original or punctuation-trimmed variant, shared transform
   and masked locate. No source/target labels enter this selection.
7. Reference computes actual opposed-edge stroke quantiles, informative-gap
   fractions/visual weight and existing registered profile. Soft calls the
   existing soft profile, including unusable results. Ordered is optional and
   delegated. No production profiles or policy rules are duplicated/replaced.

Preparation's frozen predicted_fill_alpha geometry gate is a local exact port;
it is not the final source ink and does not rerun any trained producer. The
Python prepare's discarded intermediate observe_fill values are not recomputed:
palette_word_pairs replaces them before they can affect fitting.

Reference SWT uses the original .65 Gaussian/float32 Sobel/hypot, trusted eroded
known map, component extent/area filters, row-major <=6000 edge sampling,
nearest-even ray steps, alignment gate, >=16 widths and .25/.5/.75/.9 quantiles.
ROI filtering is isolated to the actual word/profile frame, as NumPy slices are.
Source/regular/heavy quantiles require two informative >=.75px gaps. These are
measurement gates from the original algorithm, not new boldness policies.

Finite/geometry behavior: invalid finite bbox/out-of-crop/empty observations are
skipped; nonfinite reference-selected bbox raises as Python floor would, while
soft-selected nonfinite bbox is skipped. If a nonfinite word occurs only in the
soft first6 and not reference spread6, it cannot fail the unselected reference
path. Nonfinite polygon/em/paint/evidence is rejected. Inputs are bounded to
4096 original words and 32 reference intervals; existing fit/grid bounds apply.

## Focused oracle command and results (2026-11-12)

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Scripts/tests/source-weight-word-observations/parity.py
```

For one diagnostic case only, the harness accepts the optional environment
`AIDOKU_WORD_OBSERVATIONS_CASE=<exact-case-name>`; default runs all cases.

The oracle uses **unmodified** `soft_ink_source.observe`,
`reference_ink_weight.measure`, `palette_word_pairs.prepare_palette`,
`color_consistent_ink.reconstruct`, existing fitting/reference raster functions,
registered/soft profiles and `ordered_glyph_ink.measure`. No downstream functions
or glyphs are mocked. Four actual accepted families/normal-strong-heavy intervals
from WORD-PAIRS are loaded, verified and rasterized by actual FreeType/Pillow.
Synthetic RGB/ownership/primary/boundary/native/RF27/valid/paint arrays are the
same input observations on both sides. No font copies or whole-page data exist.

The harness additionally checks full reconstructed alpha and known maps for each
observation, and exact prepared known/text/geometry fields. A second test-only
reconstruction is used for these diagnostics; the production helper calls it
once. Selected existing modules are linked read-only in a private
TemporaryDirectory; no shared/native/app build script or cache is invoked.
Python source SHA256 values are captured before/after the run to reject an oracle
changing during concurrent parent work.

| Coverage | Executed |
| --- | ---: |
| Complete source word observations | 21 cases |
| Palette word preparation | 8 cases |
| Invalid em/cutoff/RF geometry/nonfinite reference bbox | 5 rejections |
| Reference words compared | 26 |
| Soft words compared | 25 |
| Optional ordered word results / glyph profiles | 3 / 6 |

All keys, list order, family/nominal choices, usability flags, centre counts,
ordered intervals and prepared geometry/known maps agree. Maximum absolute
output difference **5.960464477539062e-7**, confined to template correlation
scores/margins (atol/rtol 2e-6). Observed stroke quantiles, estimated/fractional
weight, registered/soft numeric profiles, ordered numeric evidence and source
support fractions have **zero** difference on these fixtures. Reconstructed
alpha and prepared alpha use atol/rtol 1e-7; known maps are exact.

Coverage includes normal/heavy actual-font alpha, multiple reference families,
vertical punctuation with ordered evidence, unknown-color existing seg/RF maps,
ownership gaps, polygon pose, fractional bbox, alternate-fill geometry fallback,
NFC/whitespace/excluded/short text, no contrasting fill, no words, >640 rotated
geometry, separate reference-only/soft-only calls, eight-word first6/spread6
selection and the path-specific nonfinite member case. The same field presence
rules are asserted for usable and unusable profiles.

Final private host compile **7.516 s**, complete native harness **7.873 s**.
Native OpenCV4.11.0 / FreeType2.14.3; Python OpenCV4.13.0 / Pillow13 BASIC layout.
These include JSON/font hash/raster/reconstruction diagnostics and all cases,
not device or per-word production timing.

## Remaining integration and validation limits

Parent owns `FontWeightSourceEvidence` dictionary bridge, original word/input
bindings, mixed/ordered/conflict policies, source eligibility, Swift orchestration
and actual full830 results. This helper does not add/update any of those files.
No production full830 run, real-page visual review, device/iOS compile, model
quality improvement or fix for the parent's two false-bold cases is claimed.
Optional ordered is integrated and exercised here, while its full standalone
coverage belongs to the parent's separate ordered parity suite.
