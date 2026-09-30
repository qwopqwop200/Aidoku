# Device contour-fringe replay

Run `node Scripts/tests/source-inpainting-frame-fringe.cjs` for the bundled,
compressed pixel crops. They were captured from the production background copy
on an iPhone, plus a resampling control. The checks retain contour pixels and
verify the full white source outline is repaired; they do not merely assert
that a flat panel was hidden.

For an explicit native replay, place `payload.json` and `original.image` in the
app's `Documents/CachedLayoutReplay/` directory and select
`ReaderCachedLayoutReplayTests`. The JSON contains the cached `items`,
`appearance`, and `viewport`. Optional `expectedInpaintedIDs` and
`minimumErasedPixels` assert final ownership and repair coverage. The test
writes `prepared.png`, `audit.json`, and `render.png` next to those inputs.
A missing fixture fails explicitly. Do not bundle private whole pages or
credentials. No provider call is needed.

Inspect the physical-device output. A desktop canvas or simulator resample can
change a single contour pixel and the donor-surface classification, so passing
those replays alone is not physical-device proof.
