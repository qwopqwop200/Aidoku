# Public canvas paint boundary after BUILD59

The pinned WebKit revision is `dd5fe1011df7e3438ac4889356abcab7681df46d`. The 19 local source hashes were verified against `source-route.json`. No production source, frozen oracle, capture, or pixel value was changed for this review.

WebKit accelerated CoreGraphics 2D is `CanvasPaintedToLayer`; it draws a native image buffer into another graphics context. This differs from direct `CALayer.contents`. `IOSurface.mm` imports the PAL SPI header and uses `CGIOSurfaceContextCreate`; its native reference path uses `CGIOSurfaceContextCreateImageReference` and transient image caching flags. These operations are absent from the reviewed public CoreGraphics/IOSurface/QuartzCore SDK headers. Public IOSurface storage, Core Image realization, VideoToolbox image conversion, and a Metal CARenderer destination do not by themselves expose that context/reference contract.

The actual public routes already tested are listed in `build/native-render-parity/source-canvas-public-capability-boundary/report.json`: CPU CG image representations, on-screen own UIView CGContext painting, CI normal/deferred, CVPixelBuffer/VT, on-screen direct contents, and detached public CA. None matches the immutable WebKit mask. UIView51 equals CPU output, but its recorded context exposes no bitmap dimensions/data, so that output equality does not establish its underlying backend. Detached59, after a fixed source-frame orientation countercomparison, equals direct layer56 exactly; this narrows its transport identity without closing WebKit minification. The original captured bytes stay unchanged.

## One bounded public selector, not a filter search

`RenderLayerBacking.cpp:606–610` enables `acceleratesDrawing` for an own accelerated canvas. `GraphicsLayerCA.cpp:2999–3003` forwards it. Crucially, `PlatformCALayerCocoa.mm:785–795` maps that property directly to the public `CALayer.drawsAsynchronously` getter/setter. The public SDK header (538–546) says the default is NO and that true may queue drawing commands for later execution. It does not promise an IOSurface graphics context.

The prior mask helpers neither set nor record this property, so their actual runtime value is unknown. An explicit false/true control on the same original-image own-layer CGContext paint, with two backgrounds, would be source-motivated rather than parameter fitting. It would need the actual flag, unchanged inherited quality/CTM/source hash, and draw/capture completeness recorded. No filter variants, LOD, guessed kernel, or fixture-specific coordinate adjustment is justified. The remote WebKit setter at563 is conditional on a dynamic-content-scaling display-list branch; it is not proof that our observed WK runtime took it.

No public faithful native equivalent is established. If the explicit asynchronous-drawing control also fails, the reviewed source supplies no further public draw route to recommend. Keep the four strict live-alpha failures distinct from the completed exact final-PNG fixture result. Do not adopt a nonmatching public route as equivalent.

## Subsequent actual iOS observations (BUILD60–63)

The bounded asynchronous-drawing selector succeeded on BUILD60's **attached**
native UIView: both unchanged-source backgrounds matched immutable BUILD53 A/C
at every full-page RGBA pixel. Setting the flag to false retained the old CPU
result. No source draw callback ran during hierarchy capture.

Attachment and capture API matter independently. BUILD61's detached plain layer
used a bitmap context. BUILD62's detached UIView used a recording context, but
public CARenderer still produced the CPU/default realization after a separately
reported source-frame orientation countercomparison. BUILD63 retained the exact
BUILD60 public `drawHierarchy(in:afterScreenUpdates:true)` call and removed only
window attachment. Its two valid, nonblank captures matched BUILD60's false-flag
outputs exactly. The true flag and recording-context metadata therefore do not
by themselves establish accelerated pixel realization.

The original GPU/native captures remain untouched. BUILD63 still differs from
immutable BUILD53 A/C by 7,607 pixels / maximum 49 on transparency and 7,576 /
maximum 29 on opacity. These observations narrow the next question to window
association without visible UI changes; they do not justify a production
minifier, private API, or fixture-fitted filter.

## Production source draw and snapshot-size boundary (BUILD64–67)

BUILD64 established a window-associated but entirely clipped native hierarchy.
BUILD65 validated the bounded source compositor on transparent, opaque and
asymmetric PMA prefixes; cancellation and cleanup checks also passed. BUILD66
integrated that compositor into the serialized render worker. Final exports
remain 16/16 exact, full-size alpha scenes are exact, foreign backgrounds are
4/4 exact, and all three async bridge tests pass.

The remaining alpha comparison is opaque half-size: 322 pixels, maximum RGB
channel delta 1. Its 960×480 native backing is exactly the corresponding Web
capture. Pinned `WKWebView.mm` and `WKWebViewIOS.mm` show direct layer-tree capture
at the requested scale, whereas this test's historical half-size comparison
reduces a flattened bitmap using the Metal compute resampler.

BUILD67 retained those original strict comparisons and added two public UIKit
controls at renderer scale 1.5: flattened backing and preserved final source.
The two controls are equal to each other but neither matches Web: transparent
22,292 pixels / max 60 and opaque 22,080 / max 34 in canonical premultiplied RGBA.
Thus the source trace identifies different contracts but does not itself supply
a pixel-equivalent public replacement. The 322-pixel failure remains unchanged;
production sources were unchanged from BUILD66.
