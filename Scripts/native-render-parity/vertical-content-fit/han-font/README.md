# Han optical-size diagnosis

Run `vertical-content-fit/run.py`, then `han-font/run.py` to reproduce the frozen
CSS Han case396 in actual host WKWebView and inspect its real PDF font resource.
The production CoreText font attributes/advances are measured separately.

Both paths use `PingFangSC-Semibold`. CSS `font-optical-sizing:none` changes the
single-glyph inline extent from20.140625 to19.765625; disabling synthesis does
not. CoreText optical size20 changes raw advance20 to20.38, reproducing the
actual WK canvas advance20.379999. Font names and weight remain unchanged.

The public `kCTFontOpticalSizeAttribute` supports `auto` on iOS12/macOS10.14.
WebKit's official `UnrealizedCoreTextFont::addAttributesForOpticalSizing` applies
that attribute for CSS auto, and `none` for disabled optical sizing. The fixture
number selects a diagnostic case; production rendering has no fixture switch.
This proof does not assert final PNG or iOS equality.

A further public CT counterexample is essential: with the auto-sized font and
kern -0.24, ordinary CTLine advances20.14, whereas enabling kCTVerticalForms
advances19.76. Thus descriptor-only auto does not fix the native vertical
adapter. A private exact same source checkpoint with descriptor auto remains
28 observed input differences and10 actual CSS metric differences out of448.
The typography owner must preserve the optical tracking in vertical metrics
without assuming the horizontal and vertical glyph advances are identical.
