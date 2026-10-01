# Public image realization controls

The unchanged BUILD53 producer observations expose a timing/image-realization seam, not a demonstrated canvas-backend switch. All six serialized source PNGs are byte-identical to the original `.bin` fixture (`47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d`), and their canonical sRGB premultiplied RGBA buffers are equal. Draw/readback before display (A) and put/readback before display (C) produce identical final captures. Delaying draw/readback until two RAFs (B) changes 5,172 transparent pixels (max9) and 5,052 opaque pixels (max6). Input color conversion therefore does not explain those differences.

Pinned WebKit source `dd5fe1011df7e3438ac4889356abcab7681df46d` selects the rendering mode when CanvasBase allocates its ImageBuffer. The 2D `toDataURL` path serializes that existing buffer. PNG encoding obtains a native image reference; IOSurface native references use a private CG creation function with transient cache flags, and external reads flush pending draws. These facts motivate a realization/caching hypothesis, but provide neither a source-proven mode switch nor a closed-platform filter equation. Local source hashes and exact line ranges are in `build/native-render-parity/source-canvas-realization/pinned-source-proof.json`; all19 source hashes match the existing source-route manifest.

The staged `NativeSourceCanvasRealizationDiagnosticTests.publicImageRealizationRoutesPreserveSameSourceControls` has exactly12 controls: CIContext normal identity, CIContext deferred identity, and IOSurface-backed BGRA CVPixelBuffer through VTCreateCGImage; each has source readback before the first display or after two display ticks, on transparent or RGB(41,65,87) backgrounds. No image filters, resizes, filter-weight searches, private API or fixture-specific corrections are involved. Deferred source buffers are deliberately not inspected before display in the late branch. Each public native UIView paints the image at [135,7,91,121] in a 320×160 window. Initial staging passed strict Swift6 iOS26.5 SDK semantic typecheck. Root subsequently promoted the capture helper only and executed it from the existing serialized parity suite in BUILD55; the separate staged test suite was not promoted.

The diagnostic retains CIContext/CVPixelBuffer ownership through both paint and readback. It records original and realized source PNG/RGBA, image metadata, source IOSurface presence, CGContext draw metadata, display observations, actual OS/screen scale, and final public hierarchy capture. Same-source equality and valid display/capture controls are prerequisites for a comparison. The test asserts only completeness of these controls; it makes no pixel-parity assertion. CI/VT realization need not be the private WebKit source route. UIView.drawHierarchy is a different capture transport from the frozen WK snapshot, so similarity or failure must be interpreted with that limit.

Compare its immutable output without modifying pixels:

```sh
python3 Scripts/native-render-parity/source-canvas-clip/realization-source/analyze.py \
  --native /absolute/path/to/NativeSourceCanvasRealizationDiagnostic \
  --producer build/native-render-parity/verify-source-canvas-producer-build53-snapshot
```

The analyzer compares each same-input native capture against all three original WK producer captures and records intra-route timing differences. The original strict alpha gate and frozen renderer stay unchanged. Only the root-authorized capture helper was promoted into AidokuTests; production renderer and original WebKit oracle are unchanged.


## Actual BUILD55 observation

All12 source/display/capture completeness controls passed on reported iOS26.5. The original fixture PNG hash remained `47f099...`; every realized source canonical RGBA equals the BUILD53 buffer (`170fc21b...`). Reencoded realization PNG hashes are separately recorded; byte equality of those encodings is not asserted. Each background has only one distinct native final RGBA hash: all3 public source routes and both readback timings are exactly equal. All6 native before/after comparisons therefore have zero changed pixels.

No native route matches any original WK producer capture. On transparency, all public controls differ from WK A/C by7,607 pixels/max49 and WK B by7,707/max49. On opacity they differ from A/C by7,576/max29 and B by7,682/max29. CIContext reports Metal, and the CV routes report IOSurface-backed buffers, but those resource changes do not alter this final UIView output. This rejects the tested finite hypotheses; it does not establish a native equivalent or prove all public routes impossible. Descriptive results and draw metadata are in `build/native-render-parity/source-canvas-realization55/{comparison,summary}.json`.
