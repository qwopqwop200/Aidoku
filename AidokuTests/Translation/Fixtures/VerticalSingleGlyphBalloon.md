# Vertical single-glyph balloon

User-supplied original crop from the 2026-09-29 merge-fragment report (225 x 404).
The on-device full-page cache separated the high-confidence glyph 早 from its
vertical sentence. The image contains the original lettering, not a generated
fixture. `suppliedBalloonRecognizesAsOneCompleteUtterance` runs the bundled
medium-tier Core ML pipeline and checks that the crop becomes one complete
source region. Cache-coordinate regressions separately cover overlapping
single-glyph fragments using neutral replacement text.
