# Native translation final-image parity

## Historical checkpoints: final exports BUILD66, native scene capture BUILD69

This section records BUILD66/69 under their original exact-pixel policy. Its
results, limitations and timings are historical; current report acceptance is
documented in the Run section below.

The native exporter passed all **16 final-image fixtures** (12 synthetic and
4 frozen real pages): **0 different decoded RGBA pixels out of 36,126,272**.
All 19 raw restoration masks also match. The native live foreign-background
compositor passed four cases. The simulator was iPhone 17 Pro / iOS 26.5,
Release `-O`, with one test worker. These are simulator results, not a
physical-device or all-page guarantee.

BUILD69 passed **12/12 selected test declarations**. The four alpha/source-canvas
cases and three window-associated compositor cases all have zero differing RGBA
pixels. Full-size alpha cases use the production worker backing. Half-size cases
call the production source compositor with an explicit output size, preserving
the original source layer until the target rectangle is captured. Source/prefix
contents stay at the screen scale; the target rectangle controls capture size.
Default full-size output, output rejection, cancellation, cleanup and paint
ordering across the actual UI hop are covered by the affected tests.

The default live worker remains a full-size bitmap renderer. The new optional
snapshot output size is exercised directly by this bounded capture test; this
is **not proof of arbitrary reader zoom, multiple-source scene downsampling, or
all-page pixel identity**. At BUILD69, the production Main/PaintOrder implementation
and PDF-export branch were unchanged from BUILD66. That checkpoint did not rerun
the final-export gate solely for the live helper's optional output parameter.

The production renderer serializes preparation, UIKit capture and cleanup with
a FIFO admission lease. Only immutable images and numeric geometry cross to the
main actor. The helper uses an existing foreground window with an entirely
clipped temporary hierarchy and removes it synchronously before returning.
BUILD69 also adds a guard rejecting output dimensions that round down to zero.
No universal memory-leak, OOM, throughput or physical-device claim is made.

### Why the old half-size comparison differed

The original opaque half-size comparison has **322 differing pixels, maximum
RGB delta 1**, after reducing an already flattened full-size bitmap. The pinned
WebKit implementation instead captures the layer tree at the requested size.
BUILD68 showed the distinction with fixed public API controls: flattened UIKit
and CA captures reproduce the same 322-pixel difference, while the preserved
source with an explicit target rectangle matches both backgrounds exactly.

BUILD69 uses that source-backed scene contract under the original zero-tolerance
comparator. Web inputs, capture calls, immutable masks and expected pixels are
unchanged. The old compute output and its comparison remain in each background
folder under `historical-metal-*`; the old failures are not erased or converted
into passes. BUILD67/68 diagnostic snapshots also remain immutable.

**Historical strict limitation at BUILD69:** the separate affine-rotation captures
retained 1–2 differing pixels with maximum channel delta 1, alongside recorded
variation between fresh WebView references. Those original exact-policy results
remain failures; they do not describe the current final-export acceptance rule.
Unsupported compositor geometries retain the existing native painter.

The 1,216 compiled inputs did not change during BUILD69. Its incremental build
activity took 38.538 seconds; build/launch/tests together took 46.299 seconds.
The successful runner did not expose separate test-body timing, so it is not
inferred. BUILD66 took 41.026 seconds of build activity, 47.106 seconds in test
bodies and 107.223 seconds overall. These are validation timings, not renderer
performance measurements.

Independent artifacts under `build/native-render-parity/`:

- `verify-image-parity-build66.json` and `verify-image-build66/index.html`
- `verify-renderer-output-size69-source-review.json` and `verify-renderer-output-size69-runtime-review.json`
- `latest-summary.json` and `build69-comment-only-followup.json`
- `verify-renderer-snapshot-resize68-review.json`
- `verify-source-canvas-output-lifecycle.json`
- `build69-result.json` and `build69-source-sha256.json`
- `source-canvas-snapshot-resize66/source-report.json`

The frozen oracle remains commit `9003c6e248516b9485ae4ee2ba2436ba83b34406`.
All 21 frozen source files, 18 compiled legacy harness files, and final-image
inputs were independently rechecked. Those historical checkpoints used no tolerance
or replacement golden.
The historical checkpoints below describe their own build's evidence.

`ReaderTranslationNativePixelParityTests` compares the new **production native
exporter** with a **frozen test-only WebKit reference**. The reference has the
pre-migration overlay lifecycle, complete JavaScript renderer (including source
cleanup/color/typography helpers), PDF export script, and PDF compositor. It
never calls the new exporter to obtain its reference final image. The baseline
source files and SHA-256 hashes are preserved in `reference-source/`.

The suite uses the same immutable source UIImage, normalized regions, saved
translations, overlay settings, target language, viewport and aspect-fit mode.
Both engines run on the same simulator/device and bundled fonts. OCR, network
translation, saved app preferences and remote fonts are excluded. A fresh source
fixture is rendered once and reused by both engines. The baseline payload planner is frozen separately from the new native payload
planner; native planning and paint are exercised through the production image
exporter. Both share unchanged font metrics and layout primitives.

## Run

Use the repository's focused iOS test runner (incremental cache, no clean):

```sh
python3 Scripts/test_quick.py --ios ReaderTranslationNativePixelParityTests \
  --device <SIMULATOR_UDID> --configuration Release
```

Retrieve `Documents/NativeRenderParity` from the app container. For a simulator:

```sh
xcrun simctl get_app_container <SIMULATOR_UDID> <BUNDLE_ID> data
```

The retrieved directory contains `report.json` and one subdirectory per fixture:
`source.png`, `settings.json`, `regions.json`, `input.json`, `web-layers.json`,
`web-layout.json`, `web-final-layout.json`, `native-final-layout.json`, `web-typography.pdf`, `native-typography.pdf` (when capture is enabled), `web.png`, `native.png`, and `diff.png`. Then build a gallery:

```sh
python3 Scripts/native-render-parity/report.py <NativeRenderParity directory>
# Uses Pillow and NumPy; the bundled Codex Python runtime includes both.
```

The report exits nonzero for incomplete runs, missing artifacts, render errors,
changed dimensions or differences outside the declared policy. Current
`final-export-raster-acceptance` reports permit a maximum absolute RGBA channel
difference of **4 on the 0–255 scale** across any number of pixels, or a maximum
of **16 when at most 0.1% of all pixels exceed delta4**, with equal positive dimensions.
Pixels already accepted by the unrestricted delta1–4 category do not spend the
sparse moderate-color budget (floored to whole pixels). Raw changed counts still
include every differing pixel. Focused24 page11 illustrates the composition:
5,572 raw changed pixels/max16 comprise3,671 low-color pixels and1,901 pixels over4
(0.0614% of the page). Thresholds16 and0.1% are unchanged. A three-level
panel color difference is not a layout defect merely because the panel is large. These
bounds are our implementation choice responding to the user's request to allow
insignificant pixel differences; the user did not prescribe the numeric bound.

Calibration uses saved focused17 evidence: the page 0 ID10 outline has 152 changed
pixels and maximum delta 4 with the same painted font and baseline; page 8 has
12,620 changed pixels with maximum delta 3 and unchanged text/geometry. The
recorded page 0 font/line-size defect changed 5,804 pixels with maximum delta 255
and failed at that checkpoint. These examples calibrate the policy; they do not whitelist IDs.

A focused19 source-crop audit independently found 746 foreign texels retained by
native alpha clipping, of which 73 source texels visibly differ from Web's white
paint by at most 10 levels. This motivates a small moderate-delta category; it is
not a 73-pixel final-output measurement after scaling. That focused19 page 5 final
export changed 32,728 pixels with maximum delta 234 and failed. No fixture ID,
source mask or region is exempted from the final comparator.

Final exports also permit one narrowly certified common edge displacement: the
entire changed envelope must fit one axis direction and one coverage weight in
(0, 1], at most one physical pixel. All changed pixels must remain within its
original 0.1% budget; the new color composition does not relax this certificate. Both images must preserve alpha exactly and have the same dimensions, with an
opaque displacement envelope and
an unchanged constant two-pixel border around the complete difference envelope.
Every RGBA channel's total and every projection along the moved axis must be
exactly conserved. The shared coverage model permits at most one quantization
level of residual; no independent pixel matching or per-glyph alignment is used.
Only four axis directions are checked, and the envelope is capped at 65,536
pixels. This constant search uses existing buffers without shifted page copies.

Saved focused21 page10 provides the concrete calibration: 1,153 raw changed
pixels with maximum delta186 are exactly the same caption shifted down one
physical raster row. Every column's RGBA sum is equal, entering/leaving rows are
white, and all pixels outside its envelope are exact. This does not assert that
all subpixel rendering differences will qualify. Paired thickening/thinning can
pass a generic one-pixel neighborhood plus global mass test; the common move
requirement rejects it, as well as missing glyphs, extra lines, two-pixel moves,
independently opposing moves, and changed border/alpha conditions. Text, font,
line, source protection, kernel and cache assertions remain independent gates.

Exact, `accepted-low-delta`, `accepted-sparse-delta` and
`accepted-common-displacement` results have separate counters. Raw hashes,
changed-pixel counts/fractions, channel differences, bounds and diff images
remain visible. The report independently decodes the PNGs and requires reported
changed-pixel/maximum-delta and pixels-over4 measurements to match that recomputation. Altered
metrics, missing images, inconsistent statuses or incomplete runs fail.
Historical `exact-decoded-RGBA` reports retain zero tolerance; earlier bounded max4/max16 reports retain their color-only gate and all-changed sparse budget. The preceding common-displacement policy also retains its all-changed color budget. Earlier max4-only reports and reports
that declare the 0.01%/delta 1 policy retain their declared policy and `accepted-rounding`
status. Historical artifacts are never rewritten into passing results.

Low-amplitude raster acceptance alone does not prove geometry. Kernel/helper
comparisons, source erasure and protected-art assertions, text/layout invariants,
and cross-depth cache equality remain mandatory. Material glyph displacement beyond the bounded common move,
font/line-size, missing dark glyphs and shape changes are covered by high-contrast negative controls
and the existing structural tests; their failures cannot be waived by this
final-export color policy.

The Depth replay suite has an additional **test-only glyph/panel contour
certificate** after this base gate fails. It requires equal positive dimensions,
exact alpha, and the same whole-image quota: pixels over delta4 must be at most
0.1% of all pixels. Every original pixel over delta16 must be covered by verified
contour evidence; neither a page ID nor an entire crop receives an exemption.
Required live text, font, line, palette, paint order and bounded geometry must
match. Missing or malformed evidence fails closed.

Glyph fill masks and boundaries must correspond within one physical pixel,
with one-to-one connected components, at most 1% area/soft-mass drift and bounded
coverage redistribution. Rounded panels separately require matching opaque
geometry/fill, at most 0.1% material-area drift, and residuals no more than delta32
within one physical pixel of their contour with compatible fill blending.
Raw changed/max/pixels-over4 metrics remain intact; all source, kernel, cache
and structural assertions remain mandatory. The final16 suite and `report.py`
keep the base policy above; the Depth certificate is recorded separately with
its explicit reference directory.

Independent saved focused26 PNG/JSON/PDF verification accepted page5's
8,220 changed pixels/max32 (1,498 over4) and page9's 3,207/max104 (795 over4),
accounting for every pixel over16. It rejected 17 missing/thickened glyph,
balanced stroke redistribution and malformed semantic/geometry controls.
This corpus evidence is recorded under
`../output/native-main-integration/script-tests/contour-independent/`; it does
not claim exact pixels or universal equivalence. See the [validation snapshot](../TESTING.md#native-integration-validation-snapshot-2026-10-01)
and [audit](../test-skip-audit.json) for the completed full-ios-9 result:
2,435 declarations passed with zero skips, including all 22 Depth comparisons
and all 16 final fixtures (15 exact, one with maximum channel delta three).
Historical reports and policies are preserved.

## Fixtures

The built-in matrix has 12 offline fixtures: unchanged empty page, horizontal
Korean, vertical source text, rotated polygon, multiple cards, translucent dark
appearance, source color/inpainting, original plus translation, Japanese
vertical punctuation, small Korean word fitting, landscape fill and tall
webtoon regions outside the visible area. These are synthetic regression
fixtures, not evidence that all real comic pages are identical.

To extend with frozen real pages, place `fixtures.json` and referenced files in
`Documents/NativeRenderParity` before running. Each entry uses this shape:

```json
[
  {
    "id": "real-page-001",
    "image": "fixtures/page.png",
    "regions": "fixtures/regions.json",
    "settings": "fixtures/settings.json",
    "targetLanguage": "ko",
    "viewport": [390, 700],
    "aspectFit": true
  }
]
```

`regions.json` is encoded `[ReaderTranslationStoredRegion]` and `settings.json`
is encoded `IPhoneOverlaySettings`, identical to the inputs written by the suite.
Supply translations and all source geometry, polygons, auxiliary ink and balloon
interiors from a completed prior OCR/translation run. Keep credentials out of
these files. Device and simulator results must be reported separately; a
simulator pass is not a physical-device pass.

## Full source migration inventory

`migration-inventory.json` audits all **25 Rust pixel-kernel exports** and all
**202 named `aidoku*` JavaScript helper definitions** found in the frozen color,
restoration, segmentation, slanted-source, typography and renderer sources. This
is a static source snapshot; implementations are continuing to change.

Each entry distinguishes `exact-port` (same native Rust kernel source, or a
mapped Swift policy with bounded frozen-reference differential evidence),
`native-equivalent` (purpose covered by a different, partial or unverified
policy), and `missing` (no audited counterpart identified). Original source
locations, native implementations, actual/internal caller references and proof
artifacts are separate fields. An exported library alone does not establish
production integration. Internal calls are labelled; lexical call-site evidence
is not a full call-graph or final chronology proof.

Refresh the inventory after implementation edits:

```sh
python3 Scripts/native-render-parity/refresh-inventory.py
```

The snapshot now finds all 25 native kernel production callers and records
independent frozen WASM comparisons. The `counts` and `highestPriorityGaps`
fields are authoritative for the snapshot; they are **not coverage or pass
rates**. Missing browser helper capabilities remain listed even though the
production reader now uses native rendering and the frozen JavaScript is used
only by the independent oracle. The source-extension runtime is tracked
separately and is not claimed migrated by this overlay inventory.

`render-chronology.json` records the actual native top-level stage order and separately audits frozen conditional seams. The inventory refresh also refreshes this audit. Late unit containment, deferred forced restoration, short/balloon proposal trials and the full slanted typography search retain explicit caller limitations. A declared or fixture-tested helper is not counted as execution of that stage.

Kernel/helper fixture passes and successful iOS builds do not establish final
image equality. The declared final-export policy remains the final raster gate; differences
outside it and independent structural failures remain failures.

Focused host proof builds (from the worktree root, preserve existing caches):

```sh
swiftc -O Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationSourceStylePostPolish.swift Scripts/native-render-parity/SourceStyleMain.swift -o build/native-source-style-host/check
python3 Scripts/native-render-parity/source-style-check.py
swiftc -O Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationSourceStylePostPolish.swift Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationCaptionPanelPolish.swift Scripts/native-render-parity/CaptionPanelMain.swift -o build/native-caption-panel-host/check
python3 Scripts/native-render-parity/caption-panel-check.py
swiftc -O Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationSourceStylePostPolish.swift Aidoku/Core/Translation/NativeEngine/Overlay/NativePartialSourceProof.swift Scripts/native-render-parity/PartialSourceProofMain.swift -o build/native-partial-source-host/check
python3 Scripts/native-render-parity/partial-source-check.py
python3 Scripts/native-render-parity/source-position-check.py
swiftc -O Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationSourceStylePostPolish.swift Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationGlossPlacement.swift Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationEffectGloss.swift Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationOversizedTitleGloss.swift Scripts/native-render-parity/OversizedTitleMain.swift -o build/native-oversized-title-host/check
python3 Scripts/native-render-parity/oversized-title-check.py
swiftc -O Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationSurfacePool.swift Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationFinalRenderingHelpers.swift Scripts/native-render-parity/FinalRenderingHelpersMain.swift -o build/native-final-rendering-helper-host/check
python3 Scripts/native-render-parity/final-rendering-helpers-check.py
```

The full nested primary outlined-lettering and unified caption-packing policies
have independent durable harnesses as well:

```sh
python3 Scripts/native-render-parity/run-primary-outlined-lettering-parity.py
python3 Scripts/native-render-parity/run-caption-packing-parity.py
python3 Scripts/native-render-parity/run-spatial-crop-parity.py
python3 Scripts/native-render-parity/light-lettering/run.py
python3 Scripts/native-render-parity/final-ink/run.py
python3 Scripts/native-render-parity/frame-lines/run.py
python3 Scripts/native-render-parity/polarity/run.py
python3 Scripts/native-render-parity/late-balloon/run.py
python3 Scripts/native-render-parity/page-edge/run.py
python3 Scripts/native-render-parity/initial-joined/run.py
```

These compare frozen policy mutations with identical supplied physical metrics;
platform measurement and final PNG raster equality remain independent gates.

The light-lettering harness executes the entire frozen conditional stage with
synthetic source pixels, supplied DOM ownership and rectangle measurements. It
compares crop coordinates, the charged source-pixel budget, rejection reasons,
topology statistics and accepted style decisions against the production Swift
implementation (137 cases, including 46 accepted styles). The same command also
runs four unchanged app tests on the host for pale lettering, the dark-ink halo
veto, shared crop budgets and saturated outlines. Canvas sampling and actual
renderer call order are separate integration checks; these policy fixtures do
not certify final image equality.

The final-ink harness compares the complete frozen final contrast/cohort stage
against `.finalContrast` on 120 pages containing 720 cards. It includes changed
owning surfaces, overlapping plates, preserved source outlines and robust
restored-surface histograms. Two actual app tests also exercise retaining an
initial cohort through a changed owning surface and respecting a certified
source-position outline. Initial clustering and final contrast are distinct
renderer stages, with current geometry and surface measurements supplied at
the latter stage.

The frame-lines harness runs the whole frozen rule-repainting stage and compares
crop geometry, the shared three-million-pixel budget, layer counts and every RGBA
byte (77 cases, 37 positive). It includes horizontal/vertical rules, one-sided
contour rejection, antialiased fringes, text exclusion, fractional crops and
hidden/rotated plate rejection. The native renderer stores the resulting image
on the actual plate background, retaining its provenance for later glyph-cover
admission. `NativeSourceFrameLinesTests` separately checks that runtime adapter;
whole-page final-export acceptance remains a separate gate.

The polarity harness compares the complete late owner-tone stage on 177 cases
(80 accepted), including source confidence, polarity flips, measured ring vetoes,
CIE Lab caps, shared owners, foreign fills and overlapping lettering. CSS colour
strings are parsed at the fixture boundary before invoking the typed Swift policy.
The renderer collects all decisions from the same page snapshot and then changes
accepted owner/backing colours and fill without reshaping geometry.

The late-balloon harness compares three separate frozen blocks: plate-free
readable-floor holding, sampled balloon coverage clipping and body centering
(126 cases, 59 accepted). The page-edge harness covers 384 cases, including
successful shifts, successful shrink, manual-size refusal and complete rollback;
it also compares every font/pitch/physical-ink measurement request. Runtime
adapters have their own affected app suites; these supplied-metric policy
proofs do not replace the final image gate.

The initial-joined harness runs the frozen post-restoration, pre-typography
native-band rectangle search (112 cases, 58 accepted moves). It preserves
sequential ownership, planned line length, source/kept-caption obstacles and
the residue veto. `NativeInitialJoinedUnitTests` separately exercises the actual
layout adapter and its retained original plan.

## Plate growth and final cohort policy

`NativeTypographyPlateGrowth` ports the frozen axis plate growth and the complete
post-growth cohort block. Its caller supplies the extant readability plate,
coverage, physical Range probes and live member font state after initial font
clustering. Source pixel room inspection uses the native bounded integral table.

```sh
python3 Scripts/native-render-parity/staging/plate-growth-check.py
python3 Scripts/native-render-parity/staging/plate-cohort-check.py
python3 Scripts/native-render-parity/staging/flat-plate-room-check.py
```

The reports under `build/native-plate-growth-host` cover 250 full frozen growth
fixtures, 151 cohort fixtures with 174 live refits, and 72 exact source pixel room
fixtures. The source-colour SFX regression includes initial 60.25 growth and
subsequent 42.75 cohort refit. Word advances/physical font probes are supplied
fixtures. Actual Card callbacks now dispatch axis growth, rotated body/display
growth and display-card widening after caption packing, then restored growth
and joint cohorts through one persistent typography session.

The widening harness covers 239 frozen policies (83 accepted) and rotated
body/display covers 290 (101 accepted), with geometry compared at 1e-9.
The final display-style cohort harness covers 355 policies (104 decisions),
and backing inspection covers 110 exact raster/array/budget cases. These
reports use supplied physical probes; CoreText/DOM equivalence, caller state
chronology and final PNG equality are separate requirements. Production growth callbacks now consume integer CSS scroll/client metrics from
the actual candidate font, pitch, scale and padding. Explicit vertical fallback
is retained only when the shared vertical adapter cannot supply metrics. The
actual Card/CoreText host suite covers fourteen growth transport/layout cases and
four nested source-ink metadata cases; stored block-word style is synchronized
at raw-probe reset and both restored-session commit boundaries. Assigned CSS
width provenance and platform layout equivalence remain separate obligations.
Growth source glyph/cohort rectangles use the retained cleanup image frame,
falling back to each item frame; rotated-body peers share the baseline fallback
frame. Flat-room sampling/screening and display widening require cleanup
geometry. The offset/scale regression exercises the actual adapter mapping
without changing caption or payload coordinates. Growth plate/room/widen now
consume the shared whole-content Range adapter; rotated body rows retain their
separate nonspace word-range geometry. Every plate/room/widen probe restores
flex display, including retained controlled children; restored growth commits
retain their explicit block-display marker. Actual Card tests distinguish selected spans from a genuine full-width
wrapper and verify page mapping. Packing wrapper provenance survives an
exact text-preserving room retry, but raw textContent replacement clears it
and removes actual absolute unit children. Equal concatenated unit children
remain attached during the literal conditional room retry.
The primitive's independent WK fixtures and the final PNG gate remain separate
from these adapter transport tests; explicit-tab Range cases remain unproven.
Growth candidates preserve their inherited CSS balance flag instead of forcing
greedy layout. The immutable BUILD34 source15/card2 font9 replay changes the
original .5px containment gate from pass to rejection; card9's seven-row
primitive remains a separate pending obligation. The native balance helper's
six-row cap differs from unlimited Safari/WebKit balancing documented in
https://webkit.org/blog/15383/webkit-features-in-safari-17-5/.
This actual candidate transport proof does not establish final iOS PNG equality.
The same page-owned `PlateGrowthSession` now supplies later style-harmony
`growPlate(cap, strict, styleGlyph)` callbacks. It retains the original cards,
room/refusal cache, both layout allowances, native pixel allowances and source
reader; the caller uses temporary cards for larger transactions. Actual tests
exercise initial source-backed room growth, a later capped retry on the same
reader with consumed budgets, changed live foreign paint, original-card
restoration on failure, and closing the session. Raw probes clear preformatted
child provenance while an exact equal-text room retry retains it. The whole
production Harmony adapter is included in the strict Swift 6 host compile;
its separate two-case caller replay is opt-in via `AIDOKU_HARMONY_TEST`.

```sh
python3 Scripts/native-render-parity/staging/display-widening-check.py
python3 Scripts/native-render-parity/staging/rotated-growth-check.py
python3 Scripts/native-render-parity/staging/display-style-cohort-check.py
python3 Scripts/native-render-parity/staging/display-style-backing-check.py
```

BUILD29 independently decoded the unchanged web oracle and actual native
output: 7/16 final PNGs are exact, 9 differ, totaling 2,141,026 differing
pixels (5.92651%). Growth diagnostics distinguished pre-existing panel
placement from font mutations. Helper proofs did not relax the zero-tolerance
image gate used at that historical checkpoint.


The initial clear-region search uses `NativeEarlyBalloonGrid`, keeping the late
restored-surface grid unchanged. Its 113 frozen cases include 111 accepted grids,
exact hashes of every blocked/reached byte and Int32 summed-area entry, clear
queries and exterior read coordinates. Geometry uses 1e-9 numeric comparison.
The proof supplies identical safe masks, restored-canvas alpha, plane, interior
and other-layer pixels; those production inputs and shaping remain separate
caller obligations. Reproduce with
`python3 Scripts/native-render-parity/early-margin/early-balloon-grid-check.py`.

## Same-input forced restoration regression

`Scripts/native-render-parity/forced-policy/run-build32-forced-policy.py` executes
the complete production component and legacy force paths with the actual iOS
BUILD32 crop bytes, full native cached palette and original caller options for
real-comic-0025 regions4/14. `build/native-render-parity/build32-forced-native/report.json`
retains source and frozen-oracle hashes. Both final rejection outcomes and all16
complete painted/blocked/protected/core/outline buffers match the frozen policy
exactly; donor census matches as well. The donor/exemplar CPU25 bridge is active.
Trace insertions only capture intermediate arrays and counters.

The discovered error was absolute linear `TypedArray.fill` normalization for
off-crop kept-region rectangles: negative end indices are relative to the whole
array. `NativeTypedArrayFill` now preserves that behavior in component and legacy
row rasterization. Donor-only nested x/y loops retain their distinct semantics.
Removing only those kept exclusions accepts the same donor methods and painted
counts on both sides, establishing the causal branch. Positive counterfactual
final RGBA equality is not inferred without an output-byte capture. Cached
iOS/browser metadata equality and full final-page PNG equality are independent
gates. BUILD33's actual final-image gate still has10/16 exact images.

```sh
python3 Scripts/native-render-parity/run-plate-growth-scroll-adapter-tests.py
python3 Scripts/native-render-parity/forced-policy/run-build32-forced-policy.py
```


Persistent growth session ownership checkpoint (BUILD38 candidate):
`plate-growth-session-writeback-proof/report.json` preserves a controlled
optimized separate-module AddressSanitizer reproduction. The macro-free direct
driver reads a freed incoming one-card array after initial growth in the deferred
write-back implementation. Changing only that write-back to explicit success
assignment and catch/write-back/rethrow makes the same driver complete initial
growth, capped and style-glyph refits, failed-refit restoration, close and closed
session rejection without an ASAN error. Both direct-driver reports explicitly
record zero Swift Testing tests; dylib, executable, source and log hashes are
retained. Macro-safe assertion calls alone did not fix the failure.

The actual optimized separate Aidoku dylib / Swift Testing client then passed
20 test functions (21 parameter cases), recorded in
`plate-growth-session-fixed/tests.log` and `report.json`. These include consumed
source-room budgets, retained reader identity, live obstacle rejection,
persistent original-state refits, resource close, and cancellation write-back of
already accepted plate state. The source-room resource fixture deliberately uses
Helvetica; it is a resource/state contract, not a Korean font-parity assertion.
Actual optimized iOS crash correction and final-page PNG equality remain separate
unconfirmed gates at this checkpoint. BUILD38 will execute the focused affected
suites and the strict image gate against the immutable app/test source snapshot.


BUILD38 confirmed the persistent-session lifetime correction on actual optimized
iOS: all 15 Growth tests passed. The next scoped Growth change removes only the
two forced legacy whole-word wrapping assignments from axis plate/room and
rotated resize trials. Frozen plateTry/roomLayout do not mutate white-space,
word-break or overflow-wrap, so the copied live modes now survive. Source diff,
BUILD38 same-pass CSS evidence and hashes are in
`plate-growth-inherited-mode-proof/build38-evidence.json`.

The optimized separate-module affected suite passed 22 test functions / 38
parameter cases, including 16 actual Card wrapping/whitespace/retained-room
combinations, the explicitly named legacy balance control with its original
assertions, and captured real15/card9 full-range admission with both balance
flags. At font9 the inherited live mode measures width58.257 rather than the
legacy55.998: its full range fails the original0.5px plate tolerance even though
integer scroll/client metrics fit. No font threshold or tolerance was changed.
The rotated change is source-audited; these direct mode fixtures exercise the
axis/room adapter. Actual post-change iOS font and final PNG equality remain
independent pending gates.


The UnitParts child DIV producer now explicitly selects keep-all/overflow-normal
while retaining its parent's white-space mode, as frozen11019–11022 require.
The old whole-word-collapse flag no longer overrides that inherited distinction.
The existing removed-SPAN/block/preformatted markers are still cleared. The
actual producer and current CoreText implementation passed
`NativeBalloonUnitPartsStyleTests` (2 functions /3 cases), including first-part
trailing spaces under pre-wrap versus normal. Reproducer:
`unit-parts-style/run-app-tests-host.py`; source hashes, log and report:
`build/native-render-parity/unit-parts-style`. This verifies child style and text
range behavior; full spatial placement and final PNG equality are separate gates.
