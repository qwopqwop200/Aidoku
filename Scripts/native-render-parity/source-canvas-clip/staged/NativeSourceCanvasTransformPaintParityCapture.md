# Strict affine source-canvas controls

This separate staged helper runs `NativeSourceCanvasTransformPaintParityCapture.run()` and saves `Documents/NativeSourceCanvasTransformPaintParity`. Root alone promotes it and schedules the serialized iOS run. It does not modify the existing original ten controls, four alpha controls, or six backing diagnostic observations.

| Literal CSS parent matrix | Source conditions | Requested WK widths | Strict count |
| --- | --- | --- | --- |
| identity `[1,0,0,1,0,0]` | positive fractional local frame and negative half-origin frame | 160,320 | 2 |
| nonuniform `[.9,0,0,1.1,0,0]` | same | 160,320 | 2 |
| fractional translation `[1,0,0,1,.25,.375]` | same | 160,320 | 2 |
| rotation `.035` radians around literal parent origin0 | same | 160,320 | 2 |

Each scene uses the unchanged literal script, two opaque 20×20 canvases, original local frames `[10.25,10.5,93.25,77.75]` and `[-10.5,-10.5,100.25,99.25]`, and sRGB `[41,65,87]` backing. The independent Swift source recipe RGBA `(23+x*9,17+y*10,201,255)` is saved/hashed and must exactly match every decoded source. Literal local frames and parent matrices are separately validated. The scene saves DOM geometry before applying the parent transform, actual transformed bounds/computed CSS matrix, and immutable source PNG/canonical RGBA. None of these values are chosen from output differences.

Native rendering calls the actual production `NativeTranslationRenderer.drawSourcePatch(...usesLiveTextureSampling:true)` under the same literal parent CTM, at actual screen scale. Full 320×160 native backing at DPR3 is 960×480. Only when actual WK captured pixel dimensions differ does it call the actual production whole-page resampler to match the public snapshot capture size. Metadata includes CGContext properties, CTM, inherited interpolation, and the actual consumer. The current integral/uniform eligibility predicate is saved as a *predicted guard classification*, not an instrumented branch claim. Nonuniform, fractional-origin and rotation are specifically outside the currently proven integral uniform path.

`expectedCount=8` means eight actual full-page comparisons. All captures precede per-scene comparisons; both web and native PNG/canonical RGBA buffers, hashes, changed pixels/bytes and maximum deltas are saved. The final test requires all eight comparisons to have exactly equal RGBA, with zero tolerance. SDK typechecking alone supplies no runtime pixel claim. Fresh report initialization prevents old results from being accepted after an interrupted run.

These opaque enlargement controls do not close or depend on the separate large-mask minification and alpha-over defects. A future production module update is exercised naturally through the same actual consumer; the oracle and input controls stay literal. The original ten passing controls alone do not establish these affine cases.

```sh
python3 Scripts/native-render-parity/source-canvas-clip/ios/typecheck-capture.py --helper Scripts/native-render-parity/source-canvas-clip/staged/NativeSourceCanvasTransformPaintParityCapture.swift
```
