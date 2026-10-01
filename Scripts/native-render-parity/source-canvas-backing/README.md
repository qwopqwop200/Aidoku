# Canonical source-patch backing transport

The texture primitive, backing helper and source-patch caller are published for checkpoint53. Main creates the owner's explicit fresh bitmap capability; the actual iOS53 consumer suite passed two declarations / three cases.

The capability's owner attests normal source-over, alpha one and the fresh rectangular clip. Public CGContext getters cannot prove ambient alpha/blend or actual clip shape. A capability must not be manufactured from an arbitrary UIView, PDF or already-clipped drawing context. The helper additionally refuses changed context identity, CTM, format, extent and clip bounds; those checks are not a substitute for the owner declaration.

Supported bytes: encoded sRGB, 8-bit components/32-bit pixels, premultiplied RGBA big-endian or BGRA little-endian. Reads retain padded row strides. `convertToDeviceSpace` includes Quartz's bitmap base transform, so it supplies memory-row coordinates; raw CTM Y alone does not. Fractional clips, rotations/nonuniform transforms, other formats, virtual contexts and minification retain the previous path. The tile has already been composited and the caller uses explicit UIImage `.copy`, alpha one.

Host proof (no simulator):

```sh
xcrun swiftc -O -swift-version 6 -strict-concurrency=complete \
  Scripts/native-render-parity/source-canvas-backing/Probe.swift \
  Scripts/native-render-parity/source-canvas-backing/staged/NativeCanvasBacking.swift \
  Aidoku/Core/Translation/NativeEngine/Overlay/NativeCanvasTextureResampler.swift \
  -o /tmp/aidoku-backing-proof
/tmp/aidoku-backing-proof
```

Eight actual CG bitmap controls combine two byte formats, both Y orientations, transparent/opaque current backgrounds. Full RGBA equality checks row/format extraction, bounded full-UV crop, exact one-composite copy, unchanged CTM/clip and refusal conditions. The promoted iOS suite additionally invokes the actual source-patch method and explicit UIImage copy, which is separate from host Core Graphics draw proof. Root ran this consumer suite successfully in iOS53. The four actual alpha captures each have zero RGBA differences outside the captured actual minified-mask bounds; both binary expansion and overlap rectangles are exact. Whole alpha captures remain unequal inside the minified mask. `analyze-alpha53.py` reads immutable iOS artifacts without rerendering, and writes `build/native-render-parity/source-canvas-backing/actual53-region-report.json`.
