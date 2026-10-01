# Bounded rotation capture repeatability

The strict transform gate remains zero tolerance. No capture below is selected as
a preferable oracle, and no shader/color correction is derived from its values.

Immutable actual iOS52 and56 have byte-identical source RGBA and full recorded DOM
(including literal matrix, source PNG strings, viewport and transformed boxes).
The current native56 output is byte-identical to the independently compiled host
replay in all eight transform captures. However, Web52 vs Web56 changes eight
full-resolution rotation pixels and four half-resolution pixels, all max1; the
other six transform captures are unchanged. This explains why the observed
rotation mismatch count moves from8/3 in52 to2/1 in56 without a native arithmetic
change. Code-script provenance is current and preserved-stage evidence, not an
independent decompilation of historical binaries.

A separate diagnostic was then run in actual iOS57. Its JavaScript is copied
verbatim from the strict helper; it creates the same two20×20 opaque sources,
local CSS frames and literal rotation matrix, reads source before applying the
parent transform, and waits the same two RAFs. It uses three fresh WKViews in one
controlled window. Each view requests160→320 snapshots twice, without DOM/source
mutation between pairs. Completeness and canonical-source controls are asserted;
all thirty same-width pairwise pixel comparisons are descriptive only.

Independent PNG decoding confirms all twelve captured PNGs equal the saved
canonical RGBA bytes, all six source PNG/RGBA buffers equal the original recipe,
and all three full DOM files are byte-identical. The independently recomputed
metrics and hashes agree with every runtime pairwise report. Snapshot CGImages
also have the same sRGB8bpc32bpp, alpha-info and stride metadata across views.

Within this batch, both repeats in each fixed view match exactly. Views0 and1
match each other. View2 differs from them at two full-resolution pixels,
(170,37) and(80,223), and one half-resolution pixel(85,18), max channel delta1.
Compared with immutable native56, views0/1 have one remaining full-resolution
pixel difference(99,109) and no half-resolution difference; view2 has three full
and one half differences. Those results are all retained; no acceptance gate is
relaxed and no observation is discarded.

This establishes **bounded cross-view output nonrepeatability with the declared
code, source, DOM, setup and captured screenshot formats equal**. It does not
establish global randomness, identify private framebuffer/backend state, or
prove the precise filtering/rounding cause. It also does not make the remaining
strict transform failures pass. A source-derived production change needs
independent cause evidence rather than fitting to one view's output.

Reproducer: `audit-rotation-repeat.py` with the bundled Python runtime's Pillow
and NumPy. Immutable input: `verify-canvas-rotation-repeat-build57-snapshot`.
Result: `source-canvas-clip/rotation-repeat57-audit/report.json`. Prior52/56
source/DOM/code and pixel point comparisons are under
`source-canvas-clip/affine56-vs-host`.
