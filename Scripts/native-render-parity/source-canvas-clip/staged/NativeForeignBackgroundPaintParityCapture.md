# Strict live foreign background controls

Staged outside app inputs. `NativeForeignBackgroundPaintParityCapture.run()` saves `Documents/NativeForeignBackgroundPaintParity`, initializes a fresh `expectedCount=4,count=0,passed=false` report, and requires four strict full-page RGBA comparisons at zero tolerance. Root alone promotes/schedules the serialized actual iOS run.

The four independent literal CSS scenes are positive local offset, negative local offset clipped by a fractional owner, owner moved while its local image declarations remain unchanged, and overlapping two constant gradient image layers (first declaration above second). The exact source inputs are saved and hashed. Each source panel has CSS border-radius0, no border/padding, base sRGB237/232/215 and page background41/65/87. Gradient colors and no-repeat positions/sizes are declared directly in JavaScript from these literal inputs, without any Native helper or expected geometry generation. Original/final DOM rectangles, CSS declarations before/after move, computed CSS properties and actual viewport/DPR are saved.

The negative owner origin200.125/10.125 is chosen to expose outward device rounding; its local offset-3/-4 and size30/24 select the supported vector-image branch at DPR3 while reaching the clipped owner edges. The fractional alternative -3.19/-4.22 and30.7/24.9 would select a genuine pattern branch after snapping, which is outside the current helper's supported path. This staged control intentionally isolates the vector/live boundary contract; no actual captured oracle has been changed, and the unsupported pattern route is not claimed covered.

Native creates the actual production Card/Panel/ForeignFill transport and calls `NativeTranslationRenderer.draw(...paintsBackground:false,paintsText:false,paintsSourcePanels:true,pixelSnapScale:nil)`. Radius0 matches CSS0. ForeignFill retains original global evidence and original local CSS declarations, including after owner movement. It does not call the gradient helper directly. The consumer is Main's live source-panel branch, which is staged separately after BUILD52. One actual WK snapshot width320 per320×160 scene is compared to native at the actual screen scale (DPR3 means960×480). No source canvas, Metal sampler or whole-page resize is involved. PNG/raw canonical sRGB PMA8 RGBA, CGContext properties, retained declaration order/geometry and exact differences are saved before the final assertion.

Parser validation can run immediately. SDK semantic checking waits until Root's BUILD52 module contains the actual retained background transport:

```sh
python3 Scripts/native-render-parity/source-canvas-clip/ios/typecheck-foreign-background-capture.py --build-label BUILD52
```

The SDK script imports the actual Root-built module and records its hash. It does not generate a mocked Card/painter, build the app or access the simulator. SDK success supplies no actual pixel equality claim. Existing original canvas10, alpha4, transform8 and backing6 controls stay separate and unchanged.
