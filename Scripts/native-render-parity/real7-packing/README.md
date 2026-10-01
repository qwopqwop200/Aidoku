# BUILD33 real7 preferred caption partition

Run `python3 Scripts/native-render-parity/real7-packing/run.py` from the worktree.

The probe uses the immutable BUILD33 actual native card/neighbor ink snapshot,
production CoreText typography and production `NativePanelGeometry` admission.
The captured card16 candidate repeats exactly: ink `[3,397.28125,28.140625,29]`.
The first rejection is the source-anchor displacement guard, before the final
Range-inside-cell test. Its width exceeds the padded boundary by 0.375pt, so a
source-anchor shift is unavailable; displacement 11.5043 exceeds old4.2447+4.
The same font, cell, source and obstacles with raw text and block flag disabled
passes with a real measured anchor shift and displacement 2.5650.

This control isolates the native controlled-row choice. It does not prove that
all controlled captions should reset: frozen `prepareCaptionText` preserves
actual children only with the `koreanLineLayout=word-aware` marker. Actual early
word-aware admission still needs a native/frozen stage trace. Frozen final fonts
are not treated as observations of earlier packing fonts. This is not a page
pixel parity result.

Output: `build/native-render-parity/real7-packing-admission/report.json`.
