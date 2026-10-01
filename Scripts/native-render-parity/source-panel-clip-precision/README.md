# CSS SVG coverage clip precision

Pinned revision: `dd5fe1011df7e3438ac4889356abcab7681df46d`. This source-only investigation supports the actual BUILD54 real25 panel7 clip residual. No app/test edits, build, simulator, or case offset is introduced.

The actual declaration is CSS `path()` SVG commands, rather than a polygon basic shape. CSSOM serializes the displayed local width as `33.8438`; that is not proof the authored input was rounded to that value. Frozen coverage writers emit raw JS differences/widths, with the actual coverage width 33.84375.

## Exact transport

[RenderLayer](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/rendering/RenderLayer.cpp#L3459) snaps the reference box and computes its path. [StylePathFunction](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/style/values/shapes/StylePathFunction.cpp#L51) builds the stored SVG byte-stream path and translates it by the reference-box FloatPoint.

[SVGPathParser](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/svg/SVGPathParser.cpp#L115) normalizes H/V commands into Float current points. Absolute commands assign their parsed endpoint. Relative commands add the parsed Float argument to the current Float point. A reverse relative h adds negative width; it does not restore the original M.x by assignment. For nonzero local origins, those two operations can differ.

[PathStream](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/PathStream.cpp#L207) transforms each segment before platform conversion. [Move/line transforms](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/PathSegmentData.cpp#L81) map their Float points. [AffineTransform](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/transforms/AffineTransform.cpp#L284) evaluates in Double and narrows the result back to FloatPoint.

[Platform conversion](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/cg/PathCG.cpp#L118) then supplies the already-rebased Float coordinates to CGPathMoveToPoint and CGPathAddLineToPoint. GraphicsContextCG clips that path with CGContextClip. It does not explicitly rewrite an SVG rectangle into CGContextClipToRect.

The staged proof helper `NativeSVGClipCoverage.staged.swift` preserves both absolute M/H/V/H and relative M/h/v/h forms. Its caller must provide genuine producer provenance. An existing CSS marker that survived later changes does not identify the last writer by itself.

## Actual panel control

Restoration's independent public control is retained under `build/native-render-parity/build54-panel7-clip`. Mode0 uses CGFloat addRect and retains 300 differing edge pixels, maximum1. Mode4 constructs move/line/close vertices independently rebased through Float and yields zero difference in that edge ROI. It naturally serializes to the same rectangular PDF clip as the frozen path. Fill geometry and color operators remain unchanged.

For this absolute command case, snapped x117.33333587646484 plus local right33.84375 narrows to Float151.17709350585938. Subtracting the independently rounded left gives 33.84375762939453, matching the frozen PDF width33.84376. This is a consequence of source coordinate arithmetic, not an authored width change.

A normalized CGContextClipToRect also passes this one case, but normalized CGPath.addRect does not. Therefore replacing all coverage by ideal rectangles is not justified. The source-correct primitive is the actual move/line/close command sequence with Float point transport. Quartz's final rectangular PDF serialization is an observed platform optimization, not a WebKit source policy.

## Scope

The current pixel proof covers the selected absolute panel and its edge ROI. Relative commands, multiple pieces, clipping-order interactions and live iOS drawing need their own actual producer transport/controls. Preserve fill geometry and unchanged original coverage descriptors; do not globally narrow unrelated CGRect values.
