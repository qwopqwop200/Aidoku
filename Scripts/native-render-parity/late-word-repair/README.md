# Staged late whole-word repair

This package is outside application compile inputs during BUILD41. It does not
claim that a renderer caller has been integrated or that iOS pixels are equal.

The frozen source creates `repairWords` at BrowserOverlayView.swift:5577–5726 and
calls its late mode at 9716–9721, after all size harmony/cohort passes. Production
native PostPolish presently calls only its earlier fixed-box `Context.repaired`.
That earlier call cannot implement the late widening/recentering/condensing pass.

`NativeLateWordRepair.swift` contains the late search and caller policy. It keeps
the original order: current size at full width, current size at 90% width, then
quarter sizes bounded by the 95%/8.5 floor. It preserves the 48-attempt ceiling,
profile quality checks, source/crop bounds, foreign panel/Range collisions,
proportional glyph safety margin, temporary lookup loan and borrowed pool return.
Rejected candidates restore complete caller state. The late caller combines the
original harmony rows and source rows and rejects increases in either row or page
conflicts. Absent and throwing entries do not abort the other entries.

Evidence:

- `run.py`: 104/104 frozen full-method orchestration comparisons with identical
  injected layout/Canvas/surface queries. 29 accept, including 8 condensing and
  5 smaller-size cases; failed trial CSS/children and pool restoration are checked.
- `caller.py`: 6/6 literal late-caller comparisons, including dynamic consistency
  veto, missing entries and exceptions.
- `NativeLateWordRepairGapTests.swift`: actual production macOS CoreText/Card/
  PostPolish/Harmony counterexample. Font9 `검증합니다` has bad breaks [2,4]
  before and after Harmony. The first frozen policy fixture uses that captured
  original Range and Canvas advance and accepts a same-size whole-word measure
  of40.25 with late diagnostic[2,9,9,1]. This combines actual native evidence and
  an injected-query frozen policy comparison; it is not an actual WK pixel test.

Durable reports live under build/native-render-parity/late-word-repair. Current
38/39/40 immutable fixture outputs contain no accepted lateWordRepair marker;
this missing reachable behavior is not established as their pixel residual cause.

## Renderer adapter contract still required

Integration must retain the original Entry eligibility rather than treating every
inpainted Card as registered: expensive typography capture, root child, unrotated,
non-column, Korean, automatic recovery, <=180 UTF16 units, no authored newline,
actual original transform/scale state, `sourcePanelTextFit=inside`, restored plane,
and a real panelGeometry/surface inspector/word measurer must all be represented.

Input `crop` must be projected from original c.x/c.y/c.w/c.h/c.sx/c.sy and normalized
cleanup frame; `source` must be the original OCR source projected through that
frame. `sourceGlyph` is the original positive finite source font or the exact
min(source width,height) fallback. `sourceInkLuminance` requires the real three
finite applied RGB channels. Foreign obstacles are current root panel/backing
rectangles plus every other positive Range, including invisible nodes. Do not
replace them with OCR rectangles or filter these Range obstacles by visibility.

The measurement callback must mutate the live trial before consistency checks:
raw text reset, inherited weight/family, zero padding, block/pre-wrap parent,
explicit nowrap whole-word span children, 90% centred scale and exact vertical
padding. Measure the resulting full DOM-equivalent Range/line profile. The native
whole-word DP may be reused only with the same tracked Canvas width/maxLines.
Surface callbacks must receive each guarded physical glyph rectangle and use the
retained restored/exterior inspector with the temporary lookup loan. They must
update the shared exterior debit as well as the temporary lookup remainder.

Complete Card snapshots must restore item, style, children provenance, authored
origin, shift, metadata and accepted source ownership on failure. Success publishes
actual controlled block children/preformatted provenance, raw authored CSS origin,
used physical rectangle, optional 90% scale, lateWordRepair diagnostic and the
sourcePanelFinalFont marker only when font changes. Surface/type/exterior borrowed
pools restore at method exit; only lateWordRepairBudget keeps the calculated debit.
A new independent pool for every Card would violate original page budgeting.

Invoke after cohort snap for the exact captured snap members. It must query live
page/combined row conflicts after each trial, using the already accepted state of
preceding members. Do not silently replace the existing early repair call, or use
an earlier rough shaping pass as this late caller.
