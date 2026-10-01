# Actual iOS patterned canvas capture

`AidokuTests/Translation/NativeSourceCanvasPaintParityCapture.swift` is a
capture helper, not a separate suite. The parent calls
`try await NativeSourceCanvasPaintParityCapture().run()` from the serialized
`ReaderTranslationNativePixelParityTests` suite. Only one helper window is
active. Do not run a concurrent app build or simulator capture.

The original six JSON controls are unchanged from the independent macOS
`capture-image-snapshots.swift` experiment. The extra scene contains one canvas
crossing the global top/left viewport edges. No input cleanup clip is applied
as CSS; the input clip values remain provenance. The iOS HTML adds an explicit
viewport meta wrapper, and saves the resulting inner/visual viewport and DPR.

The original seven comparisons are preserved: PDF and live snapshots at requested widths
320/640 for each scene, plus a fractional negative-origin PDF crop. The page
and literal parents/canvases remain640×1000. At DPR3 the largest live bitmap is
1920×3000 (5.76MP). A separate negative-global-half scene appends PDF and
two live captures, making10 comparisons total. The quarter-negative original
scene is unchanged. The half control observes signed rounding ties on iOS;
macOS observations do not replace its pixel result. Actual image sizes/scales are observed, not inferred from
macOS DPR. All WK PDFs, PNGs, canonical sRGB premultiplied RGBA8, DOM rectangles,
source toDataURL PNGs and saved-mask metadata are written before the final exact
pixel assertions. Saved masks retain their full source bitmap and fractional
DOM frame. Native controls call actual production `usedRect`, `SourcePatch`,
`drawSourcePatch` and `NativeTranslationPDFCapture`; no speculative snapping
rule replaces those APIs. Every RGBA byte is compared with zero tolerance.

Runtime output is the app Documents directory:
`NativeSourceCanvasPaintParity/{original-six,negative-global,negative-global-half}`
plus `report.json`. Each scene records actual scroll insets/adjusted insets,
safe area, content offset and visual viewport. The helper now matches the frozen
reader's `.never` content inset adjustment and fills the entire actual capture
clip with the literal white page background, including negative PDF crop strips.
A failure is retained evidence of a platform/backend difference, not a reason
to substitute macOS observations or relax the image gate.

The bounded compile check uses the installed iOS SDK without building/launching
the app or using a simulator:

```sh
python3 Scripts/native-render-parity/source-canvas-clip/ios/typecheck-capture.py
```

Its report explicitly distinguishes SDK typechecking from actual iOS pixel
proof. The parent exclusively owns app compilation and test execution.

The read-only actual42 capture audit is reproducible separately:

```sh
xcrun swiftc -O Scripts/native-render-parity/source-canvas-clip/ios/audit-capture.swift -o /tmp/aidoku-canvas-capture-audit
/tmp/aidoku-canvas-capture-audit build/native-render-parity/verify-source-canvas-build42-snapshot build/native-render-parity/source-canvas-clip/ios-audit42
```

Its optional indexed62CSS comparison diagnoses the omitted safe-area setting;
it does not write translated pixels or replace the strict gate. All source PNGs,
source frames, decoded RGBA buffers and captured PNG roundtrips were exact in42;
the original failed artifacts remain immutable.

## Screen backing and actual iOS alpha capture

The original helper's native live path now invokes production
`drawSourcePatch(usesLiveTextureSampling: true)` at the actual screen scale,
saves that backing image, and invokes production
`NativeCanvasTextureResampler.resample` only when the requested snapshot's
actual pixel size differs. It reduces the whole page after canvas painting.
The PDF branch keeps the explicit sampler's defaultfalse contract and does not
use the experimental Metal path. Original10 literal controls remain intact.

`NativeSourceCanvasAlphaPaintParityCapture.run()` is a separate helper called by
`sourceCanvasAlphaPaintMatchesActualIOSWebCapture()` in the same serialized
suite. Its atomic fresh report starts `expectedCount:4,count:0,passed:false`.
It captures transparent and opaque sRGB[41,65,87]320×160 scenes at requested
widths160/320. Each contains literal binary20×20 alpha pixels at[10,10,93,77],
an overlapping copy at[49,31,71,93], and the unmodified BUILD44 mask412×527 at
[135,7,91,121]. No source resizing or source PNG replacement is permitted.
The exact original mask fixture has SHA256
`47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d`.
The native mask input remains that original PNG; the canvas's toDataURL PNG is
saved separately and its canonical source equality is recorded diagnostically.

Outputs are under app Documents/NativeSourceCanvasAlphaPaintParity. Four exact
comparisons remain failures unless actual iOS pixels agree. No macOS alpha
surrogate or successful opaque control establishes this alpha/compositing gate.
Both helpers save actual native CGContext width/height,bitsPerComponent,
bitsPerPixel,bytesPerRow,bitmapInfo,alphaInfo,colorSpace,dataAvailable and CTM.
This diagnostic readback is test-only and does not select production backends.

The SDK checker accepts a separate helper and records independent source hashes:

```sh
python3 Scripts/native-render-parity/source-canvas-clip/ios/typecheck-capture.py --helper AidokuTests/Translation/NativeSourceCanvasAlphaPaintParityCapture.swift
```

Actual iOS execution remains the parent agent's exclusive responsibility.
