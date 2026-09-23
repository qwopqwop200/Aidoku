# Slanted source text

`BrowserOverlayRotation` derives local text/panel rectangles and rotation from
an OCR quad in image pixels. Reader WebKit, exported images, and native overlays
share its geometry. It supports 3–80 degrees in either direction, corrects the
long-edge ordering of confirmed single vertical columns, and rejects malformed
or excessive-perspective quads. Its inscribed text bounds and original source
center are preserved. Rendering does not make additional OCR or translation
requests; bounded native OCR recovery is described below.

## Glyph erasure and artwork protection

With source colors and inpainting enabled (source appearance at full opacity), rotated
replacement now uses `BrowserSlantedSourceRestoration`:

1. Read a bounded source neighborhood and rectify it into the lettering's axes.
2. Reconstruct only observed glyph/outline pixels. Connected cursive and large
   display glyphs may exceed the old 100-pixel component cap only when their
   complete shape stays inside the OCR axes. Surviving drawing remains protected.
   Palette-matched interiors enclosed by an owned outline are erased together
   with that outline, so white letter fills cannot become reconstruction donors.
3. If the enclosing page-axis palette was contaminated by neighboring artwork,
   retry a bounded color estimate of the actual rectified lettering. Tiny flat
   labels can use a separately validated glyph-boundary fill.
4. Reject partial reconstruction when independent source-colored components
   remain. Antialias connectivity distinguishes a continuous rule from letters.
   Permit supported smooth surfaces with RGB residual up to 8 and at most
   2.5% donor outliers. Use the fitted surface on owned pixels to avoid diffusing
   antialias ink back into the cleared lettering. Surviving contours inside a
   loose OCR envelope do not invalidate a separately protected glyph mask.
5. Project the alpha mask back into original image pixels. Untouched page pixels
   are never re-rendered or resampled. Include the bilinear mask footprint within
   its protected-pixel boundary, and check exposed native ink beside the projected
   mask. The text card is transparent.
6. Measure actual glyph bounds in WebKit (including a one-CSS-pixel guard),
   excluding empty font ascent/descent space from artwork tests. A raster
   snapshot regression independently verifies that these bounds contain the ink.
   Check protected pixels and restored-background contrast >= 4.5:1.
   Fit within the same source box and keep its angle/center; commit erasure and
   lettering together only after both checks pass. For large display lettering,
   artwork fitting stops at a readable 18 CSS px. Smaller text retains at least
   80% of its initial size and 8.5 CSS px; an already smaller initial layout is
   not reduced further. A higher user minimum still wins.

When ownership, available work, or fitting is insufficient, this path
retains the original image instead of hiding artwork with an opaque rectangle.
The audit explicitly distinguishes `slantedSourceErased=true` from
`slantedSourceErased=false`; the latter is a deferred replacement, **not** a
successful translation-rendering example. Retention can occur at moderate angles
as well as extreme ones. Curved/connected lettering and complex textured surfaces
are not guaranteed recoverable. Existing manual-color/inpainting-off panels and
native overlays without source pixels retain their ordinary rotated-card path.
Quads rejected by the shared geometry stage retain the existing ordinary-layout
fallback; they do not enter this slanted reconstruction path.

Both page-axis and rectified buffers spend the existing per-page work allowance.
Cache accounting includes mask and luminance bytes and keeps the existing 16 MiB
limit. The render cache identity includes `source-rotation-v7-native-balloon-fit`.

Suppressed ruby retains its actual polygon through OCR merging, region storage,
balloon merging, reuse and overlay payloads. Both body and reading are rectified
in the same coordinate frame, including at 45 degrees where an axis-aligned
envelope cannot uniquely recover a narrow reading. The OCR cache identity is
`reader-ocr-v56-merged-rotation`. Missing small reading columns can be inferred
on clear paper in rectified axes, including above horizontal text; neighboring
OCR regions remain excluded. Inference padding is allocated only for compatible
source color and aspect ratio. Horizontal and vertical OCR ruby suppression
are tested through ±78 degrees with full-size kana and semantic-reading controls.

## Dataset

The frozen manifest now has **304 cases**: 268 Korean targets and 36 English
targets. It retains all 224 earlier cases (132 original source regions) and adds
80 explicit rotations of eight real ruby captures from seven page identifiers.

- The previous 112 cases remain, including unsafe-angle and corrupt-quad negatives.
- 64 new real regions challenge sign borders, clothes, balloon contours, pale
  lettering, outlines, handwriting, and nearby illustration.
- 32 explicitly recorded ±55/±78-degree rotations of eight of those real crops.
- 16 additional English-target replays.
- 80 real ruby replays at ±8/25/45/55/78 degrees, with actual auxiliary polygons
  and missing-ruby cases. These captured rasters have source/input SHA provenance.
- A separate 200-case pixel suite combines these 80 captures with 120 known-
  background light/dark, colored and faint-ruby controls; these are augmentations,
  not 200 independent pages. Reviewed masks preserve neighboring ink/illustration.
  Complex multi-balloon regions remain explicitly tracked when restoration fails.

Natural steep examples reach about 61 degrees. ±80-degree evidence uses explicit
real-pixel augmentation; it is not a claim of naturally occurring 80-degree
annotations. Each source is identified by path and SHA-256. Model/silver labels,
fixed translations, and assistant source review are not human ground truth or
provider translation-quality measurements.

## Reproduce

Resolve the dedicated simulator's current container:

```sh
xcrun simctl get_app_container SIMULATOR_UDID app.aidoku.Aidoku data
python3 Scripts/tests/export-slanted-text-fixtures.py CONTAINER/Documents/SlantedText
```

The exporter requires Pillow and defaults to the sibling
`datasets/real-comics-20000` corpus (`--corpus PATH` overrides it). It verifies
original hashes, crops real pixels, applies recorded rotations, and preserves
unrelated app data. Do not reuse an old simulator container UUID.

Run `ReaderSlantedTextTests` in the Release simulator target. Its opt-in dataset
replay and fresh-OCR tests must actually execute for a dataset-validation claim.
Swift Testing method filters include parentheses, for example
`'-only-testing:AidokuTests/ReaderSlantedTextTests/datasetReplay()'`; a successful
xcodebuild exit with zero executed tests is not verification.

- Four setting combinations × upright control/current quad = **1,216 pairs and
  2,432 WebKit snapshots**. Upright controls isolate the current rotation path;
  they are not screenshots of an earlier app revision.
- Audit text content, angle, center, overflow, contrast, erasure atomicity, and
  whether a replacement was applied or the source was retained. Pixel comparisons
  of safety-rejected geometry must remain identical to upright controls.
- Twelve full original pages also pass through current OCR/merging and production
  export. Their angle references have five-degree tolerance except one explicitly
  reviewed curved-clothing silver annotation with eight degrees. Export follows
  current detection within 0.001 radians. This is not corpus-wide OCR accuracy.
- Adjacent suites: `ReaderTranslationRenderingTests`,
  `ReaderTranslationImageExportTests`, `ReaderOverlayEngineTests`, and
  `NativeOCRTextLineMergerTests`.

Run independent pixel regressions:

```sh
node Scripts/tests/slanted-artwork-regression.cjs
node Scripts/tests/source-inpainting-regression.cjs
python3 Scripts/tests/audit-slanted-artwork.py CONTAINER/Documents/SlantedText/results --output metrics.json --test-summary test-summary.json
```

The slanted test includes 14 geometry/known-background cases and 24 captured
real-pixel cases with separately reviewed lettering/protected-region masks.
The original 12 cases come from four source regions plus eight recorded rotations.
Twelve additional cases cover book print, colored vertical lettering, a gray
handheld label and print on a red shirt, including explicit ±55/78-degree rotations.
They are crops/augmentations, not 24 independent pages. They require at least 99.5% of
annotated lettering cores erased and zero protected pixels changed by more than
three RGB levels. The small number-label control also includes its connected gray
antialias fringe. The pink outlined-letter control includes white glyph interiors
and protects exposed artwork between letters beyond an eight-pixel sampling margin.
Five further captured failure controls reject partial source
silhouettes and unsupported background reconstruction, for 43 checks in total.
The masks are assistant-reviewed, not human gold. Review full
rendered output as well: pixel gates alone do not establish visual quality.
The replay audit requires the 19 controls with independently observed readable
placement to produce visible translations; silently retaining every source cannot pass this check.
The five red-shirt erasure positives are measured separately: their variable
background and local protected pixels can still prevent 4.5:1 readable placement.
They were already retained by the pre-fix renderer; passing pixel erasure alone
does not prove that a readable translation can be placed. All five separate
partial-reconstruction controls must retain the source without a mask.
Pass the final `xcresulttool get test-results summary --format json` output to
reject stale screenshots left by a previous run.

No physical-device latency, memory endurance, remote-provider quality, or complete
recognition/reconstruction of arbitrary artwork is established by these tests.

Run the new pixel suite with `node Scripts/tests/slanted-ruby-regression.cjs`.
Rebuild it with `python3 Scripts/tests/build-slanted-ruby-fixtures.py` (Pillow).
The suite checks source/ruby erasure, input immutability, illustration changes,
neighbor ownership and exact reading dimensions at 45 degrees. Near-white samples
created by bicubic rotation do not count as visible original ink. The separate
`freshRotatedRubyImagesKeepOCRAndRenderingEvidence` test records actual recognition
and rendered output for eight rotated full pages at ±25 degrees; its generic Korean text is a
rendering probe, not a claim about translation-provider quality.

The 200-case ruby suite now requires **zero** visible annotated body/reading
residue and zero protected-art changes for every accepted case, with at least
197 accepted. Three complex multi-balloon rotations remain explicit retentions.
The separate strict residual test preserves the three former tiny-reading
failures, so they cannot disappear inside an aggregate error allowance.

Native rectification orders actual quad edges instead of splitting the vertices
into left/right halves (which inverted clockwise-leaning vertical text). Ruby
ownership accepts cyclic vertex orders while preserving the original reading
polygon for painting. Fresh full-page recognition at ±25 is separate evidence
from the ±78 geometry/pixel augmentations; arbitrary steep-angle OCR is not
established. Native fringe completion updates layout safety only when all four
native sampling donors are owned erasure pixels, keeping the drawing boundary.
Contrast uses the final native composite for every sample, including cells that
mix erased pixels with untouched background. This prevents obsolete source-ink
luminance from rejecting an otherwise clean, readable translation. Source-pixel
coordinates use the original payload frame rather than CSS-rounded image bounds.
When full-width lines cross a multi-lobed balloon contour, a bounded secondary
search narrows the centered paragraph within the same rotated quad. It preserves
the font floor, source center, erasure mask and 4.5:1 contrast requirement.
This secondary search is limited to vertical source dialogue with a local width
of at least 60% of the height:
a narrow, misgrouped OCR strip cannot establish a whole balloon's interior or
authorize leaving an adjacent source column visible. The existing full-width
fit remains available to narrow regions.

Text/translation-region merging retains the common rotated source quad; upright
balloon bridge heuristics do not run over an already rotated region. The fresh
page checks require body anchors, reading ownership and the resulting merged
angle, so an upright replacement box cannot masquerade as a successful OCR test.
Rejected geometrically ambiguous crops and ambiguous Latin words may get one
alternative horizontal-axis recognition pass, capped at 32 crops and confidence
>=0.85. Accepted words are replaced only when the alternate confidence/complete
word evidence wins. A recognized Latin word also retains its horizontal baseline
when the model could read it from a quarter-turned primary crop. This restores the
natural -57-degree Latin control without reprocessing accepted upright text.
The existing bounded tensor windows, cancellation and cache remain in effect;
recovery prediction/time is included in recognition diagnostics.
