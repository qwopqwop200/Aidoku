# Bounded actual CSSOM investigation

`run-current.py` snapshots and compiles current production Typography and the
verbatim Post content-fit branch into a standalone macOS diagnostic. At the
BUILD47 checkpoint it reproduces the existing448 controls,24 observed input
differences and10 original-node client/scroll differences. This is not a new
app build or an iOS inference.

`capture-controls.py` captures only those10 original failures twice in actual
macOS WK: unchanged original CSS and a diagnostic `font-optical-sizing:none`
countercontrol. All10 unchanged CSSOM tuples reproduce the historical failures;
all10 `none` tuples and anonymous span inline extents equal current native.
No production optical-sizing override is proposed. The Canvas observer uses an
explicit accepted font string: computed `font` shorthand with optical properties
can be rejected by Canvas and silently retain10px sans-serif. Its recorded font
request is independent of the DOM optical-sizing control.

Actual iOS BUILD47 Canvas controls show Han widths exactly8*size at19/20/20.5/21,
while macOS WK auto width for a20px ideograph is20.38. This establishes a
platform/font-instance optical difference. It does **not** close the uncaptured
12px narrow-box CSSOM inputs. A macOS-only compensation would therefore be an
unsupported production change, especially after actual iOS Han3/3 paint parity.

`stage-ios.py` creates the separate
`NativeVerticalCSSOMParityCapture.staged.swift` helper with exactly10 original
failure descriptors and the immutable original frozen renderer style block.
It has no optical countercontrol, font override, supplied shaper rows, PDF work,
or dependency on the passing Han paint helper. Root may promote it and call
`NativeVerticalCSSOMParityCapture().run()` in a separate capture test.

The helper compares actual iOS WK client/scroll integers against production
Typography plus production Post content-fit metrics. It saves all actual
geometry and final shaped-run metrics before reporting failure. Its independent
window has explicit viewport dimensions/meta and `.never` adjusted scroll insets.
The observed viewport/DPR are saved. Output directory:

`Documents/NativeVerticalCSSOMParity/{input.html,input.js,viewport.json,web-layout.json,native-layout.json,report.json}`.

`typecheck-ios.py` passes Swift6 strict isolated simulator-SDK typechecking using
captured current production dependencies. It neither builds the app nor launches
a simulator. No iOS pass is claimed until the parent executes the10 controls.

Reports and source hashes are preserved under
`build/native-render-parity/vertical-content-fit/current47-audit/`:
`shaping-report.json`, `optical-controls-report.json`,
`ios-stage/typecheck-report.json`. Original descriptor SHA256:
`20af2aa9f6b702a60078ce9d046de92b92bbbc73439613d275218ac984759d42`.
Frozen style block SHA256:
`4f6b6525bd4a6a775d375a68b9e57c31061300b51e9f0b4ff9625581ae172cbc`.

## Actual iOS49 closure

The parent executed the isolated capture on iOS26.5. `close-ios49.py` independently
verifies the immutable files under `verify-vertical-cssom-build49-snapshot`:
exactly10 original descriptors and indices, unchanged HTML/meta and frozen style,
no optical-sizing countercontrol, identical native/web inputs, and strict equality
of every `[clientWidth,clientHeight,scrollWidth,scrollHeight]` tuple. **10/10 exact**.
The viewport is390×700 with DPR3. All original input/capture hashes and literal
native shaped ranges/advances are saved in
`build/native-render-parity/vertical-content-fit/current47-audit/ios49-closure.json`.

These10 previously open macOS optical CSSOM cases are closed for the actual iOS
production scope. This does not claim all448 cases or arbitrary vertical paint
parity. The separately executed actual Han3/3 pixel equality remains its own gate.
No production optical compensation or fixture substitution was necessary.
