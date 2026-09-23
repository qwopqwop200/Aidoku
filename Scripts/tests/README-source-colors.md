# Source color regressions

Run from the repository root with Node.js 18 or newer (no npm dependencies):

```sh
node Scripts/tests/source-color-regression.cjs
node Scripts/tests/source-color-sampler-regression.cjs
node Scripts/tests/source-color-diversity-regression.cjs
node Scripts/tests/source-color-stroke-regression.cjs
node Scripts/tests/source-color-readability-regression.cjs
node Scripts/tests/source-color-background-regression.cjs
```

The runners extract the actual JavaScript from `BrowserSourceTextColor.swift`.
They do not maintain a separate implementation of the estimator. The pull
request workflow runs them when the source or runners change.

## Stroke presence and color

The stroke runner scores **stroke RGB and false detections separately from
displayed text color**. It reuses 116 original corpus captures and adds 19
work-disjoint captures. Of the original 116, 104 have a single reviewed stroke
or no stroke; 12 ambiguous tiny, hollow, or multiple-outline cases are retained
but unscored. The extra 19 were annotated before predictions, after initial development.
References are assistant-reviewed visible sRGB swatches, not human gold.
The original holdout and confirmation cases were inspected during regression
work. Later fixes used native WebKit regressions in those original cases and
UIKit controls; the extra 19 were replayed without changing their references.
Treat these as work-disjoint confirmation and regression checks, not a fully
sequestered blind benchmark.

Every scored crop uses the same maximum-channel RGB tolerance of 25. Missing
strokes fail outlined cases; any non-null stroke fails an outline-free case.
The runner prints both stroke matches and false positives, and every known miss.
Its aggregate floor is a regression gate, not a claim that every crop is correct.
It also checks hashes, work separation, cache reuse, opaque input validation,
flat/frame/art negatives, source immutability, and unchanged pixel allowances.
An additional UIKit/WebKit pixel capture checks white text with a brown outline
on a white surface at four OCR margins. This control is excluded from dataset
accuracy counts and prevents confusing white glyph interiors with the panel.

Stroke estimation checks bounded repeated glyphs and local fill-to-stroke-to-
exterior transitions, rejects antialias ramps, and retains independently
validated enclosure/native-detail evidence. It uses existing pixels only.
Rejecting a stroke color does not enlarge an already measured cleanup fringe.
Caption text/background decisions remain separate; captions still use the
existing outline-free display policy.

```sh
node Scripts/tests/source-color-stroke-regression.cjs --report /tmp/strokes.json
node Scripts/tests/source-color-stroke-regression.cjs --source /tmp/before.swift \
  --measure-only --report /tmp/strokes-before.json
node Scripts/tests/source-color-stroke-regression.cjs \
  --export-replay /path/to/simulator/Documents/MangaQuality \
  --baseline-source /tmp/before.swift
```

Resolve a dedicated simulator's data container with `simctl get_app_container`.
The exporter adds PNGs, `stroke-replay.json`, and `stroke-baseline.js` without
deleting documents. Run `ReaderSourceStrokeColorTests` in Release to compare
the baseline/current production sampler in WKWebView, check OCR/translated
cache parity and budgets, and export measured JSON plus source/swatch snapshots
to `MangaQuality/stroke-results`. These are supplied OCR boxes, not OCR or
translation-provider accuracy tests, and not device-memory measurements.

The stroke expansion adds **228 source crops from 228 previously untested
works**, excluding the 467 work groups present in the color fixtures at
selection time. It covers 40 CG/illustration, 40 SNS comic, 16 game CG,
48 public visual-novel screenshots, 40 doujin, 32 manga and 12 vertical-comic
crops. A seeded source-only contrast/color ranking and interleaved random
controls select crops without consulting predictions. The frozen exclusion
list and seed are stored with the annotations; hashes preserve original RGBA.

Of these, **47 have a reviewed primary outline and 174 have no outline**.
Seven ambiguous/illegible/glow cases remain unscored. Clearly identifiable
primary edges of hollow or double-outline text are included. Five swatch-index
transcription corrections are recorded in `annotationErrata`; outline presence,
scoring eligibility and the 25-unit RGB tolerance did not change. The initial
171/57 work-disjoint development/confirmation split was made before predictions.
The confirmation cases exposed further failures and were subsequently used for
fixes, so these are reviewed regression cohorts, not an untouched blind test.
The aggregate gate includes misses and also requires at least 60% color coverage
on actual outlined cases and at most 4% false strokes on negative cases.

```sh
node Scripts/tests/source-color-stroke-regression.cjs \
  --annotations Scripts/tests/fixtures/source-color-stroke-expansion.json \
  --captures Scripts/tests/fixtures/source-color-stroke-expansion-captures.json \
  --report /tmp/expanded-strokes.json
```

The expansion uses the same runner, negative controls and native replay format.
Its corrections distinguish physical fill from display ink, corroborate width
with local enclosure, and allow dark interiors to rejoin their exterior only
through a separately owned band. Subpixel strokes require additional observed
support. No additional image reads or larger pixel budgets are introduced;
independent `sourceInk` evidence remains available to erasure. Native replay
also records and rejects any previously correct scored case that regresses.

The background runner reuses the original RGBA captures from the diversity
fixtures with separate, frozen annotations in `source-color-background.json`.
It checks 82 exposed backgrounds across manga, colored comics, game dialogue,
visual novels, photographed print and illustrated surfaces. The 41 development
and 41 work-disjoint holdout annotations were frozen before background predictions;
the initial correction used development inputs only. Subsequent WebKit validation
found a dense h083 crop that fell below the exposed-pixel coverage threshold;
the spatially distributed sparse-background correction now makes this a reviewed
regression set, not an untouched statistical holdout. Expected
colors are assistant-reviewed visible swatches, not human gold or reconstructed
hidden artwork. Maximum per-channel sRGB error must be at most 25, with no
per-case exemptions. Known clean synthetic panels and a gradient additionally
guard against exterior borders, ink contamination and source-role mutation.

`--source FILE --measure-only --split development --report FILE` replays a prior
implementation without changing labels. The iOS
`ReaderSourceBackgroundColorTests` replay uses `MangaQuality/background-replay.json`
and `background-baseline.js`, exports actual WebKit snapshots and applied RGBs,
and checks OCR/Korean captions, unchanged ink/layout and page pixel limits.
Its inpainting is disabled so the measured RGB belongs to a visible caption.
Background display evidence is stored independently from erasure palettes.
Use `python3 Scripts/tests/export-source-background-fixtures.py DESTINATION
--baseline BASELINE_SWIFT` to populate that simulator fixture directory without
imaging dependencies. Resolve the current app data directory using `simctl`.

The second background review adds 129 candidate crops from 126 works absent from the original
116 source-color fixtures, using seed 23092601 and source-only diversity ranking
plus random controls. `source-color-background-expansion.json` freezes 109
reviewed background annotations, and `source-color-background-expansion-captures.json`
stores their exact sRGB pixels and provenance. These add dark panels, low-contrast
signs, colored balloons, halftones, illustrated surfaces and translucent game UI
across eight formats; the combined background suite has 191 crops across ten formats.
Twenty candidates with multiple incompatible surfaces are listed as excluded
before predictions. One further coarse OCR group was corrected to its existing
single-line annotation during review. Five annotation corrections (including
misread swatch indices and measured gradient references) are recorded explicitly.
The final set is a reviewed regression corpus, not untouched human-gold holdout
accuracy. Its original work-disjoint development/holdout partition is retained
for diagnostics. No per-fixture error exemptions are used.

```sh
node Scripts/tests/source-color-background-regression.cjs \
  --labels Scripts/tests/fixtures/source-color-background-expansion.json \
  --captures Scripts/tests/fixtures/source-color-background-expansion-captures.json
```

The fixture exporter accepts the same `--labels` and `--captures` options,
plus optional `--candidate SWIFT_SOURCE`. That writes the exact production
JavaScript to `background-candidate.js`; the native test substitutes it in the
app's overlay renderer while retaining the real WebKit Canvas and layout path.
Without this option the exporter removes any prior candidate override, and the
test uses the compiled source. Record the source snapshot alongside replay results.
The native replay now requires every after-image to meet the RGB tolerance,
while retaining before/after ink, geometry and pixel-budget checks. Additional
known clean controls cover dark backgrounds inside the ordinary ink tolerance,
broad additive light gradients, connected dark surfaces, and physical glyph fills
whose display is flattened to a colored outline. The last two also reproduce
additional failures exposed by WebKit's actual Canvas reduction.

The third background review considers 172 line-preferred regions from 172 new
works (seed 23092603), excluding every work in the original fixtures and all
second-round candidates. `source-color-background-round-three.json` and its
`-captures.json` freeze 153 reviewed regions, bringing the total to 344 across
ten formats. Seventeen ambiguous surfaces were excluded before predictions;
two more were excluded after full-resolution source audits. A gradient reference
and a halo/background swatch index were also corrected, with all four audits
recorded in the fixture metadata. The work-disjoint partition is diagnostic only:
the final corpus is reviewed regression data, not untouched holdout accuracy.

```sh
node Scripts/tests/source-color-background-regression.cjs \
  --labels Scripts/tests/fixtures/source-color-background-round-three.json \
  --captures Scripts/tests/fixtures/source-color-background-round-three-captures.json
```

The added halftone case reproduces gray dots being masked as dark glyphs,
leaving an almost-white caption background. The display-only background helper
retains tiny components only when their density is corroborated outside the OCR
box and their pattern repeats along both axes. It averages the retained texture
without trimming away its dark dots. Known-clean horizontal/vertical halftones
and a text-confined punctuation control guard against treating small glyphs as
background texture. Pixel reads remain within the existing sampler budgets.

The estimator suite checks explicit RGBA fixtures: glyph colors, antialiasing,
border/art contamination, faint lettering, noise rejection, panel-side
agreement, gradients, enclosed ink diluted by white antialias fringes, and
bright-mode bias inside translucent panels. Some controls reuse the deterministic pixels or
palette expectations in `ReaderSourceTextColorTests` and
`ReaderOCRPreviewColorTests`.
Captured antialiased outline fixtures also guard against returning the stroke
as the fill. Their compressed RGBA bytes decode with Node's built-in zlib;
no font or canvas dependency is needed to replay them.
Fourteen captured Japanese dialogue crops also check the single-color caption
ink over textured artwork, in both orientations and under shared page budgets.
The sampler distinguishes spatially repeated outline ink from a pale interior
and rejects plain white lettering, broad backgrounds, solid art, and a single
frame. Native detail strips share the existing reads and pixel allowance.
The resulting `lettering.color` is display-only evidence; source fill/stroke
roles used by restoration remain independent. Embedded Display P3 captures are
converted to sRGB before fixture encoding.


The sampler suite uses deterministic area averaging to exercise actual source
cropping, long horizontal and vertical lines, outlined interiors, independent
detail samples, page budgets, cache isolation, and read failures. Focused budget
and geometry tests stub the color helpers; color assertions run the production
helpers. A captured translucent balloon checks panel-informed black/white role
assignment at three scales in both orientations, with genuine white-fill
controls. The same fixture exercises production inpainting: dense Kanji
ownership, removal of every dark source stroke, source immutability, and smaller
masks based on observed halo thickness. The area filter is not a replica of
WebKit's image resampler.

The readability suite also executes the production initial style block and
final caption pass in `BrowserOverlayView.swift`, using a minimal DOM with
fixed geometry. It checks exact observed chromatic and neutral RGB when source preservation is enabled,
contrast adjustment for manual/default fallback ink, flattened colored outlines, zero display strokes and shadows, opaque source
color boxes, and settings changes. Its DOM does not implement WebKit layout or
rasterization. Caption width and word-flow regressions run in iOS WKWebView in
`ReaderAdaptiveRenderingTests`, including neighboring text, image edges, manual
font sizing, and explicit line breaks. Text reflow is limited to the existing
box interior. Before/after assertions require every panel position and size to
remain identical; it must never enlarge or regenerate a panel after text reflow.

To compare estimator behavior against an earlier revision:

```sh
git show REV:Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourceTextColor.swift \
  | node Scripts/tests/source-color-regression.cjs --source /dev/stdin
```

`--baseline` selects existing-behavior controls. `--filter TEXT` selects case
names. All color expectations remain the same when replaying an older source.

These checks do not replace the iOS tests. On a Mac, also run the
`ReaderSourceTextColorTests`, `ReaderOCRPreviewColorTests`,
`ReaderSourcePanelRestorationTests`, `ReaderSourceInkRestorationTests`,
`ReaderAdaptiveRenderingTests`, and `ReaderTranslationDiskCacheTests` suites
in the Aidoku scheme. They cover UIKit/WKWebView rendering, actual font
rasterization, overlay settings, and restoration. Real-page replay tests that
require `Documents/MangaQuality` fixtures need those inputs on the simulator.

For a local WebKit replay, place original page PNGs and `lettering-replay.json`
in the simulator's `Documents/MangaQuality`. The manifest is an array of
`{name,image,regions:[{bounds:[x,y,width,height],source,expected:[r,g,b]}]}` with
normalized OCR bounds. `capturedLetteringUsesObservedInkInPreviewAndTranslation`
checks actual OCR-preview and Korean-caption colors, page sampling budgets, and
exports JSON plus WKWebView PNGs to `lettering-results`. An optional
`lettering-baseline.js` replaces only the source-color script for before images.
These are annotated color fixtures and fixed translated strings, not an OCR
recognition or translation-provider accuracy benchmark.

`node Scripts/tests/source-inpainting-regression.cjs` exercises source restoration
with known-background error bounds and eight captured crops from the local
real-comics-20000 corpus. It covers dark game dialogue, colored UI, faint gray
lettering, short captions, nonlinear gradients, frame preservation, alpha and
pixel limits. Palette recovery is erasure-only: display colors still come from
the source-color estimator. Captured acceptance checks complement the synthetic
pixel-error oracles; they do not establish recovery of hidden illustration detail.

The ruby fixtures include twelve rasterized Japanese body/reading pairs with
known clean backgrounds, body/ruby pixel labels, and protected frame labels.
Six additional real manga crops preserve fixed OCR ruby annotations and
explicit observed-ink pixel counts, separately from the known-background tests.
Both orientations, dark panels, colored ink, and faint antialiased readings are
checked pixel-by-pixel. Faint ruby is recruited only inside OCR-owned auxiliary
rectangles whose outer ring corroborates the background. Unknown or missed OCR
readings do not gain ownership just from looking like small text.

Restoration now permits 1,572,864 source pixels per page and 262,144 per crop;
the cleanup cache retains at most 16 MiB of actual RGBA, layout-mask and luminance
buffers. Source-color sampling has its independent unchanged allowance. The
budget tests execute the production crop/cache code with controlled image/DOM
and reconstruction stubs to check native detail for later regions, page limits,
byte accounting, eviction, and release on page changes. They are not WebKit
timing or sustained device-memory evidence.

The reconstruction regression also includes 24 mixed solid/faded Japanese text
oracles (two orientations, three palettes, flat and gradient backings), eight
underestimated-outline oracles, and three captured residual-ink regressions.
An additional captured gray balloon contour protects pale drawing lines that
cross an OCR box. These tests check observable source pixels against known
backgrounds or reviewed pixel probes, not just whether a crop was accepted.
Faint body components require a clear surrounding ring and cannot cross the
OCR boundary or form solid inset blocks. Eight captured low-contrast speckle
regressions also keep isolated body noise from becoming a false layout obstacle;
explicitly owned one-pixel ruby remains supported. Outline continuation follows observed
stroke colors with bounded distance and preserves neighboring donor exclusions.

`fixtures/source-inpainting-corpus-selection.json` records 249 additional pages
from 222 works in ten categories. With the previous 121 regression pages, the
local full-page replay covers 370 pages. The new selection reserves 61 pages
for evaluation after tuning; this is a **page split, not a work-disjoint split**.
Seven additional variants retain native alpha from the source images instead of
the RGB-normalized corpus replay. Pages with unchanged original text (such as
page numbers) must preserve the source and clear the overlay, not synthesize
a restoration to satisfy a nonempty test assertion.
Corpus annotations are model-generated silver OCR boxes, not pixel gold.
They cannot establish background reconstruction accuracy by themselves.

`ReaderInpaintingTests` accepts a frozen `baseline-restoration.js` under
`Documents/InpaintingQuality`. Both arms use current limits by default and have
separate cache keys. An optional `candidate-restoration.js` injects a captured
current production helper into the candidate arm when layout builds change
concurrently; record that script hash alongside the app and test binaries.
To reproduce an older budget experiment, explicitly supply
`baseline-limits.json`, for example:

```json
{"pagePixels":393216,"cropPixels":131072,"cacheBytes":4194304,"lookupPixels":1048576}
```

Omit that file when measuring algorithm changes at identical budgets. Each
fixture produces original region JSON, render diagnostics, translated snapshots
and restoration-only snapshots for both algorithms.

## Diverse real-image color benchmark

`source-color-diversity-regression.cjs` replays 116 text crops from the local
`real-comics-20000` collection: manga, color illustrations, SNS comics, vertical
webtoons, game dialogue/UI, visual novels, and a creator webcomic. They include
Japanese, Chinese and English source text, both writing directions, bright and
dark backings, saturated/gray/pale ink, outlines, gradients, and halftones.
The compressed RGBA fixtures include source hashes, crop coordinates and
work/creator identity; the full corpus is not needed in CI.

References were visually reviewed separately from predictions, then snapped to
populated source RGB swatches. They are **assistant-reviewed references, not
human gold**. Source boxes originated in silver OCR and were visually checked.
The 51 development and 45 work-disjoint evaluation crops were followed by 20
new work-disjoint confirmation crops after the algorithm was fixed. The cyan
title regression found among the 45 was corrected, so that set is now a reviewed
regression set, not an untouched statistical holdout. No quality tuning used the
20 confirmation crops. One multicolor logo was excluded before measurement;
mixed speaker/name groups were narrowed to individual same-color text lines.

A match requires maximum per-channel sRGB error <= 25 against an accepted
observed reference; missing estimates count as misses. Known misses are printed
and **do not count as accurate**. Per-case error ceilings prevent worsening them,
while every previously accurate case must stay within 25. These are controlled
color tests, not a claim about all 20,000 pages or OCR/provider accuracy.
The Node area resampler differs from WebKit. `displayEvidence.color` chooses
bounded glyph cores/defining outline ink; the original fill/stroke/background
and cleanup permissions stay independent. At most twelve modes and six competing
candidate colors are examined with 128 probes per pair, using existing reads.

```sh
node Scripts/tests/source-color-diversity-regression.cjs --report /tmp/current-colors.json
node Scripts/tests/source-color-diversity-regression.cjs \
  --source /tmp/before/BrowserSourceTextColor.swift --measure-only --report /tmp/before-colors.json
```

To reproduce the native replay, resolve the simulator container dynamically,
then export the fixtures (this also runs the Node checks):

```sh
container=$(xcrun simctl get_app_container booted app.aidoku.Aidoku data)
node Scripts/tests/source-color-diversity-regression.cjs \
  --export-replay "$container/Documents/MangaQuality" \
  --baseline-source /tmp/before/BrowserSourceTextColor.swift
```

Run `ReaderSourceTextColorTests/datasetColorDiversityUsesSourceColorsInWebKit`
in Release. It renders both source-preview and fixed Korean captions against
the frozen baseline and current script, checks the shared source-pixel cap,
requires an accuracy improvement and >=80% observed reference matches, and saves
all JSON/PNG pairs plus exact match counts in `color-diversity-results`.
It does not assert that every remaining difficult case is solved. The exporter
writes additional fixture files without removing any existing app documents.

`node Scripts/tests/source-inpainting-segmentation.cjs` checks 120 frozen raster
oracles across Japanese, Korean and Latin glyphs, light/dark and colored surfaces,
low contrast, gradients and antialiased colored outlines. It executes the actual
sampler and restoration scripts together. Observed ink must have at least 99%
mask coverage with reconstruction MAE <=5, while source-color error is limited
to 25 sRGB units per channel. Known clean backgrounds also bound unintended
background changes. These are controlled pixel tests, not corpus accuracy.
`--measure-only`, `--color-source FILE`, `--restoration-source FILE` and
`--report FILE` support a frozen before/after comparison. Pixel inputs are
checksummed and do not require the original system fonts at test time.

`ReaderSourceSegmentationTests` additionally executes colored outer-ramp and
frame-protection checks in WKWebView. Its optional `Documents/SegmentationQuality`
replay loads a `fixtures.json` list of JSON filenames. Each case supplies an image
PNG data URL, pixel dimensions and OCR rectangle, with optional clean/label PNGs
for ground truth and `capture:true` for a comparison PNG. Baseline color and
restoration JavaScript files isolate the algorithm change; the exported audit
reports native Canvas results separately from the deterministic Node resampler.

### Expanded work-disjoint color cases

`source-color-expansion.json` adds **272 real source crops** to the original 116,
for **388 distinct work groups** in total. The new set adds 46 CG/illustration,
44 SNS comic, 36 game CG, 48 public visual-novel, 44 doujin, 32 manga, 18 vertical
comic and 4 visual-novel dialogue crops. Work identity prevents page reuse across
cohorts; it does not guarantee unseen artists, fonts, or product branding.

The added cohorts are 181 development, 59 work-disjoint reviewed evaluation, and
32 later independent confirmation cases. A gray-ink regression found in the 59
was fixed, so only the final 32 stayed untouched by algorithm tuning. References
are original-image visual selections from observed source swatches, not model
predictions or human gold. Six swatch indexing corrections are recorded in the
fixture metadata and applied to both revisions. Mixed punctuation is judged by
the primary lexical ink. A single representative RGB cannot describe all the
visual detail of gradients, transparency, or multicolor lettering.

```sh
node Scripts/tests/source-color-diversity-regression.cjs \
  --fixtures Scripts/tests/fixtures/source-color-expansion.json \
  --report /tmp/expanded-colors.json
node Scripts/tests/source-color-diversity-regression.cjs \
  --fixtures Scripts/tests/fixtures/source-color-expansion.json \
  --export-replay "$container/Documents/MangaQuality" --replay-name color-expansion \
  --baseline-source /tmp/before/BrowserSourceTextColor.swift --export-only
```

`--export-only` validates fixture hashes and writes the native replay inputs;
it does **not** run the estimator checks. Run the first command separately.
`expandedDatasetColorsPreservePreviousMatchesInWebKit` renders the frozen source
script and current implementation in source-preview and Korean-caption modes,
checks the page pixel cap, requires an improvement, and records previously
correct cases that regress. The exported JSON includes applied RGB and geometry;
the PNGs show real WKWebView rendering. Fixed captions and fixed OCR rectangles
do not measure OCR recognition or translation-provider quality.

The expansion correction changes display-color selection: agreement between
independent observations protects gray or joined colored ink; directional
containment distinguishes internal fill from its external band; a large bounded
gray word outranks small dark artwork; and a faint antialias fringe cannot replace
a supported colored endpoint. It adds no image reads or larger pixel allowance.
Known misses remain in the denominator and are printed on every CI run.

Native before/after review rejected two pale-fill promotions: the physical fill
matched the reference more closely but disappeared on a pale backing without its
dark outline. They retain their original pale reference and count as misses;
`outlineFreeDisplayColors` separately requires the observed defining dark ink in
both Node and WKWebView replay. A new pale-core promotion requires contrast on
the observed backing; this is not a general recoloring of legitimate gray text.

The native outlined `HELLO` control also checks a white interior on a white
page with a brown outline. The display may use the brown outline as its fill,
while the original physical fill/stroke roles remain white/brown. Corroborated
lettering with a bounded measured band preserves that physical edge even when
white's global component ownership is low. This compatibility check does not
relax the display-color matching threshold.

Seven captured dense or colored lettering crops additionally guard against
losing erasure when display-outline validation rejects a visible halo. The
sampler keeps independent `sourceInk` evidence; restoration retries that evidence
only after the displayed palette fails, through the same ownership, frame and
surface checks. This does not assign an outline to translated text. The tests
exercise the actual sampler as well as pixel-identical reconstruction from the
independent evidence, and preserve the palette and original pixels.

Six reviewed art crops now cover the first-attempt drawing guard, rejection of
textured crossing artwork, and rejection of outline-colored donor rings that
contradict the observed backing. The balloon check records 203 manually selected
contour pixels; none may be overwritten. Rejected crops are counted separately
from successful restoration, rather than inflating reconstruction coverage.
Measured contrasting outlines may use a smooth RGB plane with small residuals,
sparse outliers and no crossing art to avoid propagating the halo into the fill.

A captured native-Canvas palette also covers the one-pixel outline-width
variation on a blue gradient. Three restored fringe probes are checked against
nearby unobscured pixels in the same column (12 RGB units tolerance). These are
reviewed approximate surface references, separate from the 120 clean-background
pixel oracles. The local fitted backing only guides a bounded outline-fringe
recheck; protected artwork and donor exclusion remain in force.

The September 23 segmentation expansion samples 522 additional work groups from
seven available corpus formats, excluding the existing reviewed fixture works.
317 works are development candidates; 205 are reserved for confirmation after
freezing the patch. The production segmentation suite includes 13 reviewed
development regressions in `source-inpainting-expanded-environments.json`: nine
source fill colors (thin antialias cores, wide white outlines, pale subtitles,
gold lettering and blue UI) and four reconstruction decisions (photographed
paper, a billboard, crossing grid artwork and periodic screentone).

These silver OCR rectangles are not gold masks. Reconstruction acceptance is
coverage, not accuracy; the separate 120 raster fixtures have known clean
backgrounds and masks. The periodic texture guard requires repeated marks both
inside and outside OCR in two directions, so noise and isolated punctuation do
not alone establish patterned backing. In unsafe cases reconstruction abstains.
Source RGBA and the existing per-page read limits remain unchanged.

### Third color review: dark UI, signs and colored cores

`source-color-round-three.json` adds **170 real source crops**, bringing the
color review to **558 distinct work groups**. The additions are 31 CG/illustration,
19 game CG, 40 public visual-novel screens, 24 SNS comics, 24 doujin, 16 manga,
and 16 vertical comics. Selection uses source pixels and work identity, not
estimator output. The 115 development and 55 holdout cases were assigned before
source review; holdout predictions were opened only after freezing the changes.
One additional candidate with multiple fill/outline colors in the same line was
excluded before predictions because it has no single representative RGB.

References remain assistant-reviewed observed source swatches, not human gold.
The fixture records one corrected swatch index (white `VIVLOS` lettering had
been assigned its blue backing), applied equally to both revisions. Known misses
and abstentions stay in the denominator; `knownLimitation` only bounds the allowed
error in CI. Newly repaired cases also require a color match during native replay.

```sh
node Scripts/tests/source-color-diversity-regression.cjs \
  --fixtures Scripts/tests/fixtures/source-color-round-three.json \
  --report /tmp/round-three-colors.json
node Scripts/tests/source-color-diversity-regression.cjs \
  --fixtures Scripts/tests/fixtures/source-color-round-three.json \
  --export-replay "$container/Documents/MangaQuality" --replay-name color-round-three \
  --baseline-source /tmp/before/BrowserSourceTextColor.swift --export-only
```

For `darkUICoreColorsPreserveIndependentCandidatesInWebKit`, append at least 20
previously reviewed control fixtures to that replay manifest (190 total).
The September 23 run uses the 170 additions plus `d000,d017,d027,h058,c006,e014,
e015,e029,e043,e080,e088,e094,e095,e101,e114,e119,e146,e169,n006,n011`. It renders
both revisions in source-preview and Korean-caption modes and requires no
previous-match regressions. PNGs are reviewed separately for legibility.

The correction preserves independently supported bright ink when a dark backing
or antialias band dominates the histogram. Nearby pale cores are sampled only
within the OCR rectangle, along the same observed RGB ramp, with at most 128
existing glyph locations per candidate and a median peak to reject highlights.
Directional enclosure protects dark inscriptions from their light counters;
well-supported saturated cores correct weak blended estimates. Native strips may
still brighten a pale core but cannot substantially darken a strongly corroborated
main estimate. No image read or page pixel allowance was added.

### Mixed ink and display-scale fringe regressions

`source-inpainting-fringe-selection.json` adds 153 pages from 153 works absent from
all earlier inpainting fixtures: 115 development pages and 38 work-disjoint
holdout pages. Categories include monochrome/color comics, vertical comics,
creator comics, illustration, visual novels and game CG. These remain fixed
silver OCR/translation replays, not pixel-ground-truth labels.

The reconstruction regression command also checks:

- `source-inpainting-mixed-ink.json`: 2,347 reviewed purple glyph pixels beside
  black text, plus 65 protected balloon-contour pixels. Both crop-sampler and
  actual WebKit palettes are replayed. The latter additionally checks 16,044
  source-white probes: erasing colored cores must not leave white silhouettes.
  Independently verified inks share one mask and one background fit. A separate
  pale-text capture rejects a joint mask that would uncover previously removed
  primary glyphs when their dark outline joins them into a protected component.
- `source-inpainting-chroma-fragments.json`: actual WebKit input with saturated
  JPEG islands inside lettering; outline-residue reduction and 1,664 untouched
  decorative-ribbon pixels are checked separately.
- `source-inpainting-resampling.json`: two actual gradient crops. Resizing a
  transparent patch separately from the source can expose erased white outlines;
  four 2x filter offsets are compared against compositing before resizing.
- `source-inpainting-surface-retry.json`: expanding an outline must not consume
  an irregular white caption surface when donors remain uncertain.
- Four synthetic positive/negative cases require repeated secondary-ink evidence
  and preserve a same-color exterior frame. Four additional cases validate a
  native candidate from `sourceInk.stroke`, rejecting a single connected object,
  exterior artwork and an unconfirmed palette color. An inverted-polarity case
  additionally keeps both inks aligned with dark-background ruby processing.

The WebKit fixture harness accepts optional `source-colors.js` in addition to
`baseline-restoration.js` and `candidate-restoration.js`. The sampler override is
shared by **all** comparison modes, so palette changes cannot be mistaken for
an inpainting improvement. Record the exact script hashes with replay results.

The two-pixel compositing guard copies matching original background pixels;
it does not infer new background or enlarge text ownership. Page/crop/cache/
lookup budgets remain 1,572,864 / 262,144 pixels, 16 MiB, and 4,194,304 pixels.


`source-inpainting-hard-cases.cjs` adds eleven reviewed real crops and six known-clean
periodic-background controls. It covers tiny dark ink, dark/red SFX interiors,
gold cursive lettering, pale menu/sign text, isolated balloons surrounded by
halftones, and outlined dialogue over repeated arc patterns. The new controls
require all known ink to be erased, mean reconstruction error <=1 per RGB channel,
no changes at crop boundaries, immutable inputs and existing sampler budgets.
The real-color references are reviewed visible swatches, not statistical gold.

Periodic reconstruction verifies two nonparallel translations on unmasked original
pixels, then requires two agreeing original donors at every masked pixel. A
missing donor rejects that reconstruction; translated pixels never become donors.
The repeated-dot guard applies to the final erasure mask, so tone outside a white
balloon no longer blocks its isolated lettering. Crossing artwork and unresolved
high-contrast screentone remain protected by the existing rejection paths.
The source-color, cleanup and durable render cache identities are advanced.

```sh
node Scripts/tests/source-inpainting-hard-cases.cjs
```

The runner accepts `--color-source`, `--restoration-source`, `--measure-only`
and `--report`. The task's fresh 210-work confirmation set is separate from these
regressions initially; final visual review promoted two existing texture/drawing failures
to regressions, leaving 208 untuned controls. It uses silver OCR rectangles and is
not a gold accuracy benchmark.

### Codec islands and smooth-background convergence

`source-inpainting-regression.cjs` additionally checks tiny codec fragments against
an observed contrasting outline and neighboring owned ink. The captured
`source-inpainting-codec-islands.json` fixture requires at most 202 white outline
residual pixels (previous implementation: 657), while preserving all 1,664
reviewed decorative-ribbon pixels. Different-hue detail and ink connected to the
crop exterior remain protected. This is a targeted residue metric, not whole-page
pixel accuracy or a claim that every original letter is removed.

The smooth-surface solve reuses fixed neighbor topology. Only a measured smooth
background with no donor outliers or crossing frame uses up to 32 relaxed
sweeps with convergence checks; uncertain regions retain 48 original sweeps.
Seven known-background curvature/lighting cases bound reconstruction error.
`source-inpainting-diffusion-donors.json` separately prevents faster convergence
from spreading barcode or exterior drawing donors into originally white paper.
No page, crop, cache, or lookup budget is increased by this change.

### One-pixel body-mask fringe

`source-inpainting-regression.cjs` includes a bounded extra ring for nearly planar
backgrounds (plane RMSE <=3, zero sampled outliers, >=64 donor samples, no crossing
frame). Only the original mask queue can seed this ring; newly admitted pixels
cannot propagate farther. The pixel must differ from the fitted background by
at least four RGB units and match the observed ink/outline-to-background ramp.
Protected ink and its donor margin remain excluded. The full existing ruby halo
(up to 20 pixels) plus the proposed ring is excluded within 21 pixels of each
auxiliary OCR box. The background is fitted again only when pixels were added;
an uncertain fit rolls back the ring without rejecting the previous restoration.
The unit is one pixel at the bounded reconstruction crop resolution.

Three known-paper controls erase exactly the nearest column of a faint
three-column tail, preserve its farther two columns, and keep annotated ruby and
an exterior-connected rule untouched. `source-inpainting-one-pixel.json` adds
four actual gradient, monochrome, colored-caption and ruby crops with frozen
pre-expansion masks. These bound every newly altered pixel to a single-pixel
neighborhood and preserve the full ruby exclusion. The frozen masks define an
allowed footprint, not gold text/background segmentation labels.

No page/crop/cache budget or additional diffusion iteration is introduced.
The renderer and durable render cache identities advance so cached masks refresh.

## Stationary grain and high-contrast halftone restoration

`node Scripts/tests/source-inpainting-textures.cjs` runs 14 additional checks: two visually reviewed real crops, six known-clean random-grain backgrounds, and six known-clean halftone backgrounds of both polarities. Grain is scored by preserved high-frequency energy and bounded color error; its exact random samples under the text are not recoverable. Halftones are scored pixel for pixel, including mask growth. These tests also check source immutability and preservation of the real balloon contours.

The restoration uses original donor patches after subtracting the fitted backing gradient, with at most 192 donor candidates, 32,000 masked pixels, and 24 million search operations per attempt. Faint-letter recruitment cannot promote a textured ring into glyph ownership. High-contrast dot reconstruction requires two independent repeat directions and agreeing original samples near observed dots. Illustration-connected text and ambiguous irregular structure retain the existing rejection checks; these examples do not establish arbitrary artwork reconstruction.

The exemplar approach is informed by [Criminisi et al., Region Filling and Object Removal by Exemplar-Based Image Inpainting](https://www.microsoft.com/en-us/research/publication/region-filling-and-object-removal-by-exemplar-based-inpainting/); the bounded texture-only implementation is not a full implementation of that paper.
