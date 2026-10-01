# Whole late Korean stack-repair differential

Run `python3 Scripts/native-render-parity/korean-stack-repair/run.py`.

The harness extracts the complete frozen11594–11964 late stack-repair block
from the immutable BrowserOverlayView reference. Only Swift-string escape
sequences are decoded; the policy body is unchanged. The frozen typography and
convex geometry helpers remain original. A lexical wrapper observes calls to the
original Korean line breaker; no candidate or decision branch is replaced.

Deterministic DOM walkers expose initial glyph rows and final span layout.
Canvas width advances, plate/source pixels, clips and neighbor polygons are
fixture adapters. The native executable uses the actual production
NativeKoreanStackRepair, NativeTranslationTypography.koreanLines,
NativeTypographyPostPolish.reduplicationBreak and NativeSlantedGeometry.

The60 cases include stacked syllables, columns, stranded fragments, balloon-unit
word splits, reduplication, font shrinking/90% condensation, calibrated advances,
rotation, native source density, plate clipping, foreign ink and mismatched page
surface. The strict equality gate covers accepted/declined records, every
candidate line-layout query/result and canvas advance call in order, actual
source drawImage crop arguments, and full RGBA SHA256 for the preplate source
page and final composite read by the policy. No numeric tolerance is applied.

These are policy/glyph/raster fixture adapters; real Core Text/UIKit/CoreGraphics
rasterization and the final iOS PNG equality gate are verified separately by the
root implementation owner. In particular this proof does not certify Quartz
source-image interpolation or polygon-edge antialiasing against Canvas.

Artifacts: build/native-render-parity/korean-stack-repair/{report,fixtures,web,
native}.json. The host compile excludes only application-only integration from
NativeTypographyPostPolish using the existing font-policy boundary.
