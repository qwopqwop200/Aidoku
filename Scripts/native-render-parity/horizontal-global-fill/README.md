# Horizontal global glyph transport and centered width precision

The native helper validates all runs before painting. Upright ordinary horizontal
fill runs retain the selected CoreText font, glyph IDs and raw glyph positions.
The source FloatPoint is transported through the inverse text matrix without
translating the CGContext to a local anchor. Stroke, sideways/color fonts and
condensed layers retain the existing renderer. Text matrix, text position and
parent graphics state are restored explicitly.

Pinned primary source:

- [FontCascadeCoreText.cpp](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/coretext/FontCascadeCoreText.cpp): `fillVectorWithHorizontalGlyphPositions` maps the global point through the inverse text matrix and calls `CTFontDrawGlyphs`.
- [FontCascade.cpp](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/FontCascade.cpp): text width is returned as `float`. Effective centered line width must cross this precision boundary before calculating the line origin.

`source-anchor-control.py` reads immutable captured CoreText rows and content
rectangles. It writes a separate diagnostic PDF and never edits font resources,
colors, source masks, capture inputs or the image oracle. Its `global-only`,
`float-only`, and `both` modes separate the effects. Device scale must be supplied
from the actual capture, not guessed from a glyph position.

Actual BUILD47 real1 common Quartz raster results (3192×2254, every RGBA pixel):

| Diagnostic | White background differences | Transparent differences |
| --- | ---: | ---: |
| Original | 9 | 93 |
| Global point only | 9 | 93 |
| Float centered width only | 0 | 0 |
| Both | 0 | 0 |

The original iOS final PNG has 18 differing pixels. Diagnostic PDFs are not
replacement production output; the next actual iOS image gate must validate the
published correction. The separate real15 actual public glyph probe establishes
the global-position fill correction there; real1 does not require it.

A concrete precision boundary from captured real1 rows is raw width
19.751686426828076 → Float width19.751686096191406. Centering the latter produces
88.4600944519043, a Float tie which selects88.46009826660156, matching WebKit's
PDF88.4601; centering the former selects88.46009063720703. These are observations
of the general numeric contract, not production fixture constants.

`Probe.swift` independently compares actual public glyph painting with
`CTLineDraw`, verifies graphics/text-state restoration and refuses a later
stroke run and unsupported layer scaling. `NativeHorizontalGlobalFillPainterTests`
provides the same meaningful app-hosted checks. Hosted evidence remains separate
from actual iOS WebKit parity.
