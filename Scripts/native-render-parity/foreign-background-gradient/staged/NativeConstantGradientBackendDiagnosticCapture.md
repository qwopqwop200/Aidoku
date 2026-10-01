# Actual iOS constant-gradient backing diagnostic

`NativeConstantGradientBackendDiagnosticCapture.run()` saves `Documents/NativeConstantGradientBackendDiagnostic`. Eight capture/source controls are two literal colors (`rgb(220,30,40)` and `rgb(30,40,220)`) through four routes: WK CSS gradient, direct CPU CGContext CGGradient, on-screen UIView.draw CGGradient, and public CAGradientLayer hierarchy capture. Diagnostic `passed` means only valid inputs/callbacks/captures/completeness. `pixelParityAsserted=false`; all pixel comparisons and palettes are descriptive. The existing four strict foreign-background controls remain untouched.

Every route uses integer CSS rectangle `[20,20,96,96]` on a 320×160 page with RGB41/65/87 backing and the actual screen scale. Border/radius/padding are zero; no source canvas, transform, resize, sampler or synthetic dither is introduced. A separately saved border-free rectangle `[22,22,92,92]` isolates constant interiors from edges. Both full-page PNG/canonical sRGB premultiplied RGBA8 and cropped interior RGBA/hashes/palettes are saved. Literal input and JavaScript hashes, DOM dimensions/declarations, viewport/insets/DPR, CGContext depth/stride/bitmapInfo/colorSpace/CTM and public layer geometry/scales are retained.

The pinned WebKit evidence in `build/native-render-parity/foreign-background-gradient/source-report.json` and the parent README selects a CGGradient color-components constructor with bounded Float components promoted to CGFloat, sRGB, two alpha1 endpoints at locations0/1, and CGContextDrawLinearGradient before/after extensions. CPU and UIView use that public components constructor. Gradient drawing retains inherited antialiasing; the unrelated canvas-image disable-AA rule is not applied. CAGradientLayer has explicit sRGB CGColor stops using the same promoted components, axial start/end0.5/0→0.5/1 and locations0/1. Declared CGColor space/components and output canonical space are recorded; private CoreAnimation working/compositing color space is explicitly unobserved. CAGradientLayer is a backend control, not the literal pinned WebKit CGGradient path.

UIView is genuinely attached to an owned test window, receives a public UIKit draw callback, and is captured by drawHierarchy(afterScreenUpdates:true). It is not replaced with renderInContext. Available raw own-context bytes and every invocation's metadata are saved. CAGradientLayer likewise stays attached and is captured through public hierarchy drawing. No arbitrary settling sleep is used. Views and gradient layers are detached, the owned window is hidden, and the original key window is restored without changing the app root.

Actual iOS observation remains Root-owned. Semantic SDK check imports the actual BUILD54 Aidoku module (no new app build or simulator):

```sh
python3 Scripts/native-render-parity/source-canvas-clip/ios/typecheck-foreign-background-capture.py --build-label BUILD54 --helper Scripts/native-render-parity/foreign-background-gradient/staged/NativeConstantGradientBackendDiagnosticCapture.swift --expected-count 8
```

SDK report: `build/native-render-parity/source-canvas-clip/ios-sdk-check/NativeConstantGradientBackendDiagnosticCapture/report.json`. No native render equivalence is inferred from diagnostic completion or SDK success. Adoption would require exact pixel evidence in the independent strict controls.

## Staged offscreen controls after actual55

Original55 script, literal source declarations, eight original route records and their capture consumer calls remain unchanged. The staged next helper adds four separately counted records: each color through `ca-layer-render-detached` and `ca-layer-render-attached`. `originalExpectedCount=8`, `offscreenExpectedCount=4`, total `expectedCount=12`. Both new modes call the public `CALayer.render(in: CGContext)` into an explicit sRGB premultiplied RGBA8 CPU bitmap at the same CTM/DPR and dimensions; no drawHierarchy substitutes for their output.

The detached root/layer is created without a UIView or window attachment. The attached mode renders the very same native host and CAGradientLayer after its original hierarchy capture. Public attachment/root-superlayer flags, retained frame/bounds/scales, declared stop space/components, start/end/locations, CGContext metadata, PNG/raw RGBA and interior palettes are saved. The offscreen painter itself never accesses a window or calls drawHierarchy; the surrounding test window is still needed for the separate original WK/UI controls, so complete independence from global compositor state is not assumed. All layers are detached after capture. Private working color space remains unobserved.

Independent55 analysis (`Scripts/native-render-parity/foreign-background-gradient/analyze-backend55.py`) verified all eight PNGs against saved RGBA and source/script hashes. At integer96×96@DPR3 for the two opaque colors, public CAGradientLayer hierarchy capture equals WK every full-page RGBA byte. Direct CPU and actual UIView.draw buffers are identical to each other but differ from WK by at most1 in each channel. This is not proof that offscreen render matches, nor general source-panel equivalence.

```sh
python3 Scripts/native-render-parity/source-canvas-clip/ios/typecheck-foreign-background-capture.py --build-label BUILD55 --helper Scripts/native-render-parity/foreign-background-gradient/staged/NativeConstantGradientBackendDiagnosticCapture.swift --expected-count 12
```

The staged12 helper passed SDK semantics against actual55 module; runtime12 remains Root-owned and pending. The compiled8 helper is preserved until Root explicitly promotes the next stage.
