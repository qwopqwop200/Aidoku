# Vertical optical tracking and literal letter spacing probes

All production changes remain with the typography owner. These host probes use
real Core Text and the original captured WK CSS rather than a mocked shaper.

The public CTTracking correction is now production-owned by the typography
author. Its original tracking-only checkpoint contained64 Han,48 Korean and36
Japanese controls: it retained ten existing Han CSSOM failures, introduced none,
and corrected Japanese196/197 last-punctuation selection height. Explicit
newline rows and positive/negative/zero tracking controls were recorded
separately. `run-tests.py` now runs the three unchanged cases against actual
production source and dependencies. No final PNG/iOS equality follows from
those geometry tests.

The broader `NativeVerticalOpticalKern` and `NativeVerticalOpticalTracking`
experiments remain unshipped. Their earlier148/148 CSSOM/inline checkpoints did
not establish mixed-font correctness: the original WK `です。` PDF selects
Apple SD Gothic Neo Heavy for kana and PingFang SC Semibold for punctuation,
whereas named PingFang Core Text shaping selects available PingFang kana.
Every new script run records its actual source digests; historical reports are
not claims about a newly modified core.

Primary contracts: public Apple `kCTTrackingAttributeName` applies trailing
cluster spacing and honors zero `kCTKernAttributeName`; public font descriptor
orientation/optical-size and direct vertical glyph advances expose the optical
tracker. WebKit `fontHasVerticalGlyphs` checks the vhea or VORG table; the real
PingFang font has both, disproving the broken-ideograph explanation for this
case. See the SDK CoreText CTStringAttributes.h and
[Apple tracking](https://developer.apple.com/documentation/coretext/kcttrackingattributename),
[WebKit font implementation](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/platform/graphics/coretext/FontCoreText.cpp).

## Bounded ideograph stage and actual paint evidence

`NativeVerticalIdeographOpticalTracking.swift` remains experimental and is not
an app module input. It admits only nonempty, bounded, all-ideograph text with
one real Core Text run, one nonmissing glyph per scalar and a uniform public
optical advance delta. It refuses kana, Latin, spaces and mixed font runs.
Positive terminal tracking also needs a centering adjustment: Core Text excludes
that terminal width while centering, while the original CSS includes it.

The older broad checkpoint is preserved separately as
`build/native-render-parity/vertical-optical-tracking/ideograph-148-controls-report.json`:
64 Han, 48 Korean and 36 Japanese controls had exact CSSOM/inline results.
A fresh focused run with the then-current production dependencies contains the
10 open Han CSSOM cases and Japanese196/197, and is12/12 exact. This is a metric
result only. `run.py --ideographs` emits the copied core and its source digests;
`paint-proof.py` uses that copied core for actual glyph painting.

The actual macOS all-Han scene `天地玄黄宇宙洪荒` at20px/24px in100×160 with3px
padding has **2,878 changed RGBA pixels** out of1,092,000 for each explicit
tracking of-1,0,+1. Both WK and native PDFs are rasterized by the same sRGB
Core Graphics routine at780×1400. No pixel tolerance is applied.

`pdf-outline-proof.py` preserves each actual embedded font program and SHA,
its ToUnicode map and the glyph contours paired by literal draw order. Subset
glyph identifiers are not interpreted as physical font indices. Both PDFs map
`玄` and`黄` to their radical aliases in the embedded ToUnicode data, so those
aliases are recorded explicitly rather than rewritten in the input. All eight
actual embedded contours/bounds differ. A horizontal WK capture has contours
exactly equal to the vertical WK capture, so this outline difference is not
specific to vertical shaping.

`font-instance-proof.py` exercises32 real public font/draw combinations:
CT named font, actual vertical CTRun font, public CG named font and NS named
font; optical auto/none; horizontal/vertical descriptor; CTFontDrawGlyphs and
CGFont.showGlyphs. All32 direct paths and embedded native font payloads agree.
Only auto+horizontal descriptor restores the20.38 optical advance; the others
return20.0. Therefore descriptor-only optical restoration does not reproduce
the WK embedded outlines. The underlying font selection/serialization cause
remains open; identical PostScript names do not prove identical glyph shapes,
and differing subset names do not prove different physical font files.

These paint/outline observations are **macOS host evidence only**. They do not
establish an iOS paint defect. The frozen staged iOS helper under`ios-stage/`
compares the actual production typography and production native PDF capture
against the original scoped CSS for all three tracking signs. It writes actual
PDFs, RGBA/PNG, range geometry, embedded font bytes/SHA/ToUnicode and a separately
labeled public named-font lookup/path control. The parent owns promotion and
simulator execution. `ios-stage/typecheck.py` passed using the real production
dependencies and simulator SDK, without building or launching the app.

The PDF inspection scripts use the bundled Python with pypdf and diagnostic
fontTools4.59.0 under`build/native-render-parity/vertical-ideograph-paint/probe-deps`.
No font program or experimental optical workaround is shipped by these probes.
