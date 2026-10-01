# Lettering-unit palette differential

`python3 Scripts/native-render-parity/lettering-unit/run.py` evaluates the
complete frozen BrowserOverlayView lettering-unit block14104–14223 plus its
original luminance function, with deterministic DOM/style geometry adapters.
It compares every accepted palette/stroke/contrast record and foreign-cell fill
against the actual production NativeLetteringUnitPalette Swift policy.

Cases include2,3,12 and13-member units, detached owner fallback, missing or
unverified source colors, measured surfaces, glyph ratio/orientation/alignment,
plate luminance classes, typography contrast thresholds, stroke transfer,
foreign-ink vetoes and foreign-cell recoloring. The native renderer extension
updates actual owner panels/backings/styles, clears the old ink cluster and
retains unrelated source-erasure plate colors.

`python3 Scripts/native-render-parity/lettering-unit/run-app-tests-host.py`
executes the actual3 app-test methods on macOS with only the Aidoku import
removed. The app-hosted suite is NativeLetteringUnitPaletteTests. Actual iOS
builds and final RGBA rendering parity are owned by the root implementation.

Outputs: build/native-render-parity/lettering-unit/report.json,
app-tests-report.json,fixtures.json,web.json,native.json.
