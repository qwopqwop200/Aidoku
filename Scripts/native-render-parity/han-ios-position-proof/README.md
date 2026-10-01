# Actual iOS Han positioning analysis

Run `run.py` with the bundled Python containing Pillow and pypdf. It reads the
immutable `verify-han-build41-snapshot` by default and writes its own separate
report under `build/native-render-parity/han-ios-position-proof`.

This is a diagnostic reader, not a replacement image oracle. It preserves every
captured PDF, PNG, and raw RGBA buffer. The four trial image translations are
reported as counts only; no shifted PNG or RGBA is saved.

The actual iOS 26.5 capture has identical embedded Type1 font bytes and Unicode
maps in native and WebKit PDFs. Every glyph has the same final linear matrix.
Native PDF origins differ by −0.5 logical point in X for all three tracking
values; positive tracking also differs by −0.5 PDF point in Y. At the captured
780 × 1400 raster size, the reported integer translation controls produce zero
changed pixels across the complete 1,092,000-pixel buffers. These observations
isolate positioning in these captures; they do not establish a universal font
baseline equation or authorize a constant translation in production.

Selection Range rectangles are a separate contract. Their X coordinates already
match in these captures. Any native paint fix must preserve that distinction,
use the actual shaped run's metrics, and apply device snapping on the writing
mode's cross axis before font translations. The positive-tracking inline
centering and negative-tracking scalar Range extents remain separate findings.

The prior macOS embedded-font contour difference is outside this iOS report's
scope. Font asset metadata read through hosted macOS CoreText is not a substitute
for the actual iOS shaped run instance.

## Public CoreText transport preflight

`NativeCTFontVerticalPainter.swift` is a staged fill-only adapter. A caller must
prepare **all** lines in a frame and validate **all** anchors before painting.
A refused later line must fall back before any accepted earlier line is drawn.
The helper preserves the selected run font, glyph IDs, and raw vertical positions;
it supplies no baseline equation or fixture offset. Stroke, sideways matrices,
color fonts, and unsupported paint attributes retain the existing frame renderer.

The reproducible hosted control is:

```sh
xcrun swiftc -O Scripts/native-render-parity/han-ios-position-proof/NativeCTFontVerticalPainter.swift Scripts/native-render-parity/han-ios-position-proof/VerticalPainterProbe.swift -o /tmp/native-vertical-painter-proof
/tmp/native-vertical-painter-proof build/native-render-parity/vertical-painter-stage/prepared
```

Its 12 fill cases (four sizes, negative/zero/positive tracking) compare every RGBA
pixel against `CTFrameDraw`. Twelve stroke cases must refuse without drawing;
an ordinary horizontal line must also refuse. The report distinguishes refusal
from accepted pixel parity and verifies CGContext transform/text-state transport.
This hosted native-to-native proof does not close the actual iOS WebKit anchor
contract; the separate iOS capture remains its gate.

Metric-source version matters: pinned WebKit commit
`dd5fe1011df7e3438ac4889356abcab7681df46d` has an iOS-only platform metric
normalization and exposes raw normalized ascent/descent in Canvas emHeight fields.
Newer main Canvas code instead rescales emHeight to the computed font size. Do not
interpret one version's observed API values using the other's formulas.
