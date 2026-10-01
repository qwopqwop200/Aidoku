# Actual iOS canvas backing diagnostic

`NativeSourceCanvasBackingDiagnosticCapture.run()` is a separate observation helper, staged outside the app target. Output: `Documents/NativeSourceCanvasBackingDiagnostic`. `expectedCount=6` means capture/source/control completeness for transparent and opaque backgrounds, each with default WK 2D, WK `willReadFrequently:true`, and a public native `UIView.draw(_:)` / `drawHierarchy(afterScreenUpdates:true)` capture. It is not a pixel-parity acceptance gate. Descriptive full RGBA differences remain in the report even when diagnostic controls pass.

The immutable original BUILD44 PNG is loaded from the existing unprocessed `.bin` test resource, SHA256 `47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d`, intrinsic 412×527. Both Web and native use the original source and CSS frame `[135,7,91,121]` on a 320×160 page. Opaque backing is sRGB `[41,65,87]`; the other backing is transparent. No input resizing or resampler substitution occurs. The existing four strict alpha comparisons and their literal script are unchanged.

WK saves `getContextAttributes()`, smoothing flags, DOM rect/intrinsic dimensions, viewport/DPR/insets, emitted source PNG/canonical RGBA, and the actual snapshot PNG/canonical RGBA. Native records the actual public system CGContext inside `UIView.draw(_:)` (bitmap dimensions, depth, stride, bitmap/alpha/color-space properties, interpolation before drawing, CTM, clip), public UIView/CALayer geometry/scales, and available raw backing bytes. The CGImage is flipped only for UIKit orientation; inherited interpolation is retained. The pinned GraphicsContextCG image draw temporarily disables edge antialiasing, mirrored inside saved state here; integer CSS bounds at DPR3 are unchanged by its device-pixel rounding. `layer.displayIfNeeded()` is synchronous, and capture uses public `drawHierarchy(afterScreenUpdates:true)` without an arbitrary settling delay. Each invocation and phase is recorded. The maximum full page at screen DPR3 is 960×480.

The pinned WebKit source route (`build/native-render-parity/source-canvas-minification/source-route.json`, Layout author) reads the inherited CGContext interpolation in GraphicsContextCG. `image-rendering:auto` introduces no override. The image-buffer draw applies a destination-height Y flip and CGContextDrawImage; source-over applies here. Public UIKit drawHierarchy is a backend control; equivalence to private WK display capture is not assumed or asserted. No private context-type or IOSurface SPI is called.

SDK check only (no app build/runtime proof):

```sh
python3 Scripts/native-render-parity/source-canvas-clip/ios/typecheck-capture.py --helper Scripts/native-render-parity/source-canvas-clip/staged/NativeSourceCanvasBackingDiagnosticCapture.swift
```

Root alone promotes/inserts the serialized test method and runs actual iOS capture. Original alpha48/50 strict failure artifacts remain authoritative until their own four comparisons pass.
