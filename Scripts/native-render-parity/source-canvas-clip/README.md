Source repair canvas clipping has separate display and saved-export contracts.

The frozen `BrowserOverlayView.swift:1115–1119` measures fixed px insets against
raw authored bounds. Right/bottom subtraction is left associative:
`x + width - clip.x - clip.width`. The native helper retains that order before
CSS Float32 parsing. `nil` is CSS `none`; `.zero` is an empty shape.

Twelve actual macOS WK controls cover positive/negative fractional bounds,
four-sided and sub-LayoutUnit insets, empty shapes, and positive/negative device
half ties. WKPDF's basic-shape reference box snaps authored DOM-used origin and
size independently to the device grid. Fixed px insets are not LayoutUnits.
The captured DPR is 2; nonuniform transforms and other captured DPR values are
outside this proof. The referenceRect primitive requires finite positive DOM
bounds; liveClip validates them.

The native helper matches the captured PDF clip rectangles within PDF decimal
serialization precision (maximum 0.0000378125, tolerance 0.0001). This is a
numeric geometry proof, not an image pixel-equality claim. The production final
PNG gate still has zero pixel tolerance.

The saved mask contract intentionally differs. Frozen
`ReaderTranslationImageExporter.swift:512–514` records only DOM frame, opacity,
and raw `toDataURL` PNG. Lines 552–554 hide source canvases before WKPDF;
lines 626–628 draw the full mask image. CSS clip-path is not baked into pixels.
All twelve captured raw PNGs remain uniform full 20×20 bitmaps, including empty
live clips. Production saved export therefore omits live CSS clip metadata and
keeps the DOM-used frame.

Do not use the clip reference box as a generic canvas image draw frame. Actual
WKPDF `Do` matrices can differ: the first capture uses image x363/width67 while
its clip reference uses x362.5/width67.5. Image-frame snapping remains a separate
explicit migration seam.

Reproduce the actual WK capture/native comparison with the bundled Python
runtime (Pillow and pypdf required):

```sh
/Users/ijunjae/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 Scripts/native-render-parity/source-canvas-clip/run-proof.py
```

Run the focused actual app helper suite on the host:

```sh
python3 Scripts/native-render-parity/source-canvas-clip/run-tests-host.py
```

Outputs reside in `build/native-render-parity/source-canvas-clip`. The compile
manifest records exact helper, bridge and loaded native binary SHA256 before
comparison. The verifier rejects source changes after compilation. The app
suite `NativeSourceCanvasClipTests` embeds independently captured PDF geometry
and runs one declaration with twelve cases. Main snapshot/paint integration and
actual iOS behavior are separate runtime checks.

A separate live image destination study is now staged with actual captures at
`build/native-render-parity/source-canvas-clip/image-snapshot/report.json`.
Six unclipped opaque patterned canvases match integer CSS **edge** rounding in
both WKPDF and WK snapshots: output bitmap scales 2 and 4 have exactly the same
CSS destination bounds. All twelve snapshot boundary comparisons pass with
zero pixel-bound tolerance. Independent origin/size rounding, DPR2 edge
rounding and output-scale edge rounding are distinguished by these controls.
This measures destination geometry only; it does not compare all resampled
RGBA pixels or establish iOS/rotated/nonuniform behavior. Negative child-local
origins become positive page-global positions in this study, so negative global
rounding remains explicitly unverified. Saved mask DOM frames remain separate.

The original twelve PDF image matrices and competing formulas are recorded in
`image-frame-analysis.json`; reproduce that read-only analysis with
`analyze-image-frames.py`. Reproduce the dedicated live capture with:

```sh
/Users/ijunjae/.cache/codex-runtimes/codex-primary-runtime/dependencies/python/bin/python3 Scripts/native-render-parity/source-canvas-clip/run-image-snapshot-proof.py
```

Before production promotion, run the same WK control on iOS at its native DPR.
No generic image-frame helper has been promoted from this macOS-only result.

Actual iOS42 follow-up used immutable
`build/native-render-parity/verify-source-canvas-build42-snapshot` inputs.
The `ios-pdf-factor/report.json` controlled derivatives apply the general
integer CSS edge formula to each actual DOM frame and translate by the integral
PDF crop origin. Geometry alone removes all 11637 original-scene and 687
negative-global PDF pixel differences. The cropped control needs the fixture's
full-media white background as well (1463 → 756 with geometry, then 756 → 0
with background). No oracle or raw source bitmap was modified. The native PDF
`/Interpolate` flag differs from WK, but changing it does not affect these
rasterizations, so it is not a supported sampling fix.

The source-canvas live fixture originally used automatic safe-area insets,
where the frozen reader sets `.never`. Its snapshot has a 62 CSS px content
offset; the Tests author owns the corrected capture. `ios-live-factor` only
shifts immutable Web pixels in memory for diagnosis, never for the strict gate.
At output scale 1.5, the host CoreGraphics raw/default draw matches the actual
native iOS42 raw bitmap byte-for-byte, establishing that limited surrogate.
Integer edge snapping then reduces maximum delta, but many interpolation pixels
remain different. At scale 3, the host route has a small native iOS mismatch and
is explicitly qualified. A genuine corrected `.never` iOS capture remains
necessary. Web image boundary transitions are approximately linear in encoded
RGB; the observed CG transition uses coarser nonlinear weights. Gamma or CG
interpolation-flag changes are not supported by this evidence.

The production helper `NativeSourceCanvasImageFrame.liveFrame(domRect:)` is
limited to the live, untransformed source-canvas image destination. The saved
raw-mask branch continues to use the original DOM rectangle. Eight exact helper
controls pass: seven immutable iOS42 DOM/image-Do observations and one separate
macOS negative-half capture. The additional iOS signed-half control is pending
batch43. This geometry proof does not claim live RGBA resampling equivalence.

The actual corrected iOS43/44 controls supersede the pending statuses above.
All four PDF controls (including signed negative half and negative crop) are
exact; all six live controls still differ under CG filtering. The native screen
backing is DPR3. WK snapshot reduction to output1.5 is a second whole-page
operation, rather than per-patch sampling directly at output1.5.

`metal-linear43.swift` established that Float Metal linear sampling in
`rgba8Unorm`, followed by the same whole-page linear reduction, matches all six
opaque iOS43 RGBA buffers exactly on the host Apple M4 Pro. Half sampling and
the CPU bilinear approximations are rejected controls, never relaxed gates.
The published `NativeCanvasTextureResampler` reproduces those six results;
`production-resampler-proof/report.json` records the exact compiled source,
driver and binary hashes, and fifteen observed driver checks. Its alpha checks
prove PMA identity, channel bounds and full-versus-cropped sampling only.

The source-backed mac WK alpha study (`staged/capture-alpha.swift`) contains two
overlapping binary-alpha patterns and an immutable BUILD44 actual source mask.
PMA8 prefilter followed by CG source-over does not match those snapshots. This
does not establish the precise iOS cause, and no alpha compositing equivalence
is claimed. Actual iOS45 transparent and opaque backing controls are required.
The live production path is experimental in this worktree while that strict
obligation remains open. PDF and saved raw masks never use this Metal path.

The module bounds source and output tile to twelve million pixels and axes to
16384. A large complete destination allocates only its visible tile and retains
the full source UV mapping. The shared pipeline is locked, optional sessions
are page-scoped and closed after rendering, and cancellation never retries CG.
Unsupported source size, rotation, nonuniform CTM or fractional device-grid
coordinates keep the prior qualified CG fallback; none is counted as an exact
canvas migration. `resampler-app-tests/report.json` covers the actual four app
test declarations under optimized strict Swift6. `consumer-sdk-typecheck`
checks the exact production draw method and SourcePatch declaration with real
helper files, without claiming a full application build or live runtime pass.
