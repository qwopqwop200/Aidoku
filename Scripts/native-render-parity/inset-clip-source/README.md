# Inset clip declaration source

This bounded source audit distinguishes CSS inset percentages/pixels from CSS SVG path() coverage. Source revision is `dd5fe1011df7e3438ac4889356abcab7681df46d`. No app files, builds, simulator controls or pixel offsets are introduced.

## Reference box

[RenderLayer::computeClipPath](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/rendering/RenderLayer.cpp#L3459) first device-snaps the shape's reference box. [RenderLayerModelObject](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/rendering/RenderLayerModelObject.cpp#L750) enables snapping for ordinary HTML renderers; only certain layer-aware SVG descendants bypass it. Its FloatRect overload first constructs LayoutRect, so its components enter 1/64 layout units before snapping.

[LayoutRect](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/LayoutRect.h#L265) snaps the origin and size separately. [LayoutPoint](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/LayoutPoint.h#L217) derives each snapped size from the difference of rounded fractional-origin-plus-size and rounded fractional origin. [LayoutUnit](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/LayoutUnit.h#L635) performs the device rounding in Double and returns Float. Negative half-way values use a translated-origin rule; a blanket Swift `.rounded()` is not the complete snapping policy.

The reference box is not obtained by snapping the final global DOM rectangle directly. [RenderLayer::setupClipPath](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/rendering/RenderLayer.cpp#L3498) first device-snaps `offsetFromRoot + subpixelOffset` with a zero-origin size snap and stores that result in LayoutSize. [referenceBoxRectForClipPath](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/rendering/RenderLayer.cpp#L1662) moves the renderer's LOCAL reference box by this already-snapped offset. Only then is the moved reference box snapped by computeClipPath. For the supported ordinary zero-origin border box, this yields an independently rounded size: its origin is already on the device grid. Thus a fractional global DOM origin must not force the inset width to use the painted border's edge-snapped width. Nonzero local padding/content-box origins require the complete two-stage operation and are not proven by an independent global size-rounding shortcut.

The staged helper accepts the already-snapped Float reference box. It does not reimplement or override the existing source-proved snapping helper.

## Inset evaluation

[StyleInsetFunction](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/style/values/shapes/StyleInsetFunction.cpp#L65) evaluates horizontal sides against the snapped width and vertical sides against the snapped height. [LengthPercentage](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/style/values/primitives/StylePrimitiveNumeric.h#L213) uses Float dimension and percentage values.

For a simple percentage, [Evaluation](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/style/values/primitives/StylePrimitiveNumericTypes%2BEvaluation.h#L48) computes `Float(Double(Float(p))/100.0*Double(referenceFloat))`. The literal `100.0` makes division and multiplication Double operations; narrowing occurs at the return. A pixel length at zoom 1 is its canonical Float value. Font-relative units, zoom and calc have additional conversion policies.

With evaluated Float sides L/R/T/B and snapped Float reference X/Y/W/H, the inset rectangle is:

```
x = Float(L + X)
y = Float(T + Y)
width = max(Float(Float(W - L) - R), 0)
height = max(Float(Float(H - T) - B), 0)
```

Do not compute its right edge independently as X+W−R or substitute an original absolute coverage rectangle. Those expressions have different rounding order. Percent declarations remain ratios and respond to the current snapped reference dimensions; converting them once into pixels loses their meaning.

## Path construction

The source creates a FloatRoundedRect and uses a PreferBezier path. [PathImpl](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/PathImpl.cpp#L43) emits Float move/line and optional curve coordinates. At zero radii it emits four corner lines, including the final line back to the first corner before close. Right/bottom corners use Float rectangle origin-plus-size arithmetic. This is a distinct shape computation from parsing, accumulating and translating an SVG path byte stream.

`NativeInsetClip.staged.swift` exposes only simple px/percent rectangle evaluation and zero-radius path construction. It requires genuine inset unit provenance and an already-snapped reference box. It does not publish a production adapter or claim pixel equality.

## Limits

Unsupported in this staged helper: calc expressions, relative/font units, non-default zoom, nonzero round radii and constraints, vertical writing/reference-box changes, SVG snapping exceptions, saturation/extreme values, and unobserved live compositor behavior. Existing source descriptors stay unchanged. Actual native/WebKit controls are needed before promoting this distinct declaration mode.

Run `python3 Scripts/native-render-parity/inset-clip-source/report.py` to reproduce the source checks and SHA-256 manifest at `build/native-render-parity/inset-clip-source/source-report.json`. The report records source scope separately from the compositor agent’s actual WebKit controls.
