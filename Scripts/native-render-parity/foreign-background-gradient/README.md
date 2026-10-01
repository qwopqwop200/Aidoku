# Constant CSS gradient interiors

This investigation reads the immutable actual iOS BUILD53 foreign-background captures. It performs no rendering, pixel replacement, noise fitting, app edits, or simulator work.

Run these scripts from the worktree:

```
python3 Scripts/native-render-parity/foreign-background-gradient/audit.py
python3 Scripts/native-render-parity/foreign-background-gradient/source-report.py
```

Results are saved under `build/native-render-parity/foreign-background-gradient`. `interior-audit.json` retains original input/capture hashes and complete interior palettes. A fixed three-raster-pixel inset excludes the fractional image/owner edges; every other gradient rectangle is excluded from each layer's sample, so overlap order cannot contaminate the constant-color evidence.

All four base interiors are exact. Five isolated gradient interiors differ in 1,512/2,544, 2,369/3,922, 2,786/4,620, 1,655/2,760, and 1,619/2,668 sampled pixels. Each native interior is one constant RGBA color. Each WebKit interior contains 26 distinct RGB colors within one byte of the declared color in every channel; alpha stays 255. Maximum interior channel difference is 1. Border antialiasing and overlap order are separate defects.

## Pinned source contract

Revision: `dd5fe1011df7e3438ac4889356abcab7681df46d`. The report records URLs and SHA256 hashes for ten source files.

- [CSS image parser](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/css/parser/CSSPropertyParserConsumer%2BImage.cpp#L330) selects premultiplied sRGB for these legacy integer RGB stops. The actual declarations contain no explicit interpolation-space override.
- [GradientRendererCG strategy](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/cg/GradientRendererCG.cpp#L399) chooses CGGradient for sRGB stops with resolved components. Opaque stops also choose this route on the older premultiplication fallback. Non-sRGB interpolation or unresolved components can select CGFunction/CGShading; neither applies to these controls.
- [Component construction](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/cg/GradientRendererCG.cpp#L465) resolves bounded sRGB components as Float, promotes them to CGFloat, and uses an sRGB CGColorSpace. The native control already narrows channels to Float, but its initial CGColor-array constructor differs from the source's components constructor.
- [Gradient creation](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/cg/GradientRendererCG.cpp#L530) uses the components constructor, with a platform premultiplication option when available. No dither flag appears in this path.
- [Drawing](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/cg/GradientRendererCG.cpp#L683) uses CGContextDrawLinearGradient. The ordinary gradient extends beyond both endpoint locations. [GradientImage](https://github.com/WebKit/WebKit/blob/dd5fe1011df7e3438ac4889356abcab7681df46d/Source/WebCore/platform/graphics/GradientImage.cpp#L43) clips and transforms direct image drawing; its pattern-buffer route is separate.

There is no source-level constant-color shortcut or synthesized noise in this selected path. Equal opaque endpoints define a constant ideal color, including under premultiplied interpolation. Spatial variation is compatible with closed-backend quantization/dithering, but this observation does not derive its kernel or identify whether gradient rasterization or later composition introduces it.

## Public native controls

The closest public constructor control is CGGradient with the source's Float-promoted components, sRGB space, and two locations 0/1. Compare it with the initial CGColor-array constructor using identical coordinates and CGContext state. This is a constructor check, not evidence that it fixes dithering.

The next bounded actual iOS comparison should draw that gradient in a CPU bitmap context and in an on-screen UIView drawing context, plus an independent CAGradientLayer control. Use an integer CSS rectangle, the same DPR, two identical opaque RGB stops, and the same background. Keep source components and original output bytes; record color space, context CTM, output scale, and public layer properties. UIKit/CA tests should capture the visible hierarchy rather than substitute a bitmap renderer for the on-screen draw.

CAGradientLayer is a backend diagnostic, not the literal WebKit CGGradient route. The platform-private premultiplication constructor has no public counterpart, but alpha 1 makes its ideal color semantics equal to the public constructor. Their raster implementations still require actual evidence. A successful public route must reproduce all RGBA bytes without noise overlays or offsets before adoption.
