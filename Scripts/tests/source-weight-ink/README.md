# Bounded native source-weight ink reconstruction

New implementation only: `Vendor/SourceInference/SourceWeightInk.h/.mm`.
The API is C++17 with OpenCV matrices; the .mm implementation needs no
Foundation, model, GT, identifier, font, filesystem or renderer dependency.
No existing kernels, registration, runtime, Swift/default policy or shared
build files are edited by this task.

Run the focused host oracle from the Aidoku Git root:

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Scripts/tests/source-weight-ink/parity.py
```

The runner imports the actual unmodified Python `reconstruct` functions in
`segmented_ink_geometry.py` and `color_consistent_ink.py`, plus
`palette_word_pairs.observe_palette` and `ink_weight_geometry.clean_fill_style`.
It checks hashes before/after; no oracle function is patched or replaced.
Its only compilation is a standalone executable in a private TemporaryDirectory,
linked against the existing macOS-arm64 OpenCV archive. No shared/app build,
whole-page view, model inference or fonts are involved. Every native input has
padded row stride, including the interleaved 27-channel RF matrix.

Validated 2026-11-12: 84 bounded synthetic crops, each evaluated through default
segmented, explicitly uncapped segmented, and color-consistent rules (252
reconstructions); seven malformed-input rejection cases. Alpha and palette
alpha maximum absolute error: 0. Observed/known maps, clean-style availability,
all counts, booleans and other scalar parameters match exactly. Maximum mean
error: 1.7881393421514957e-7 (NumPy float32 reduction versus native accumulation).
Tolerance is 2e-6 for numeric alpha/means; discrete outputs require exact equality.
Python OpenCV 4.13.0; native vendored OpenCV 4.11.0. Last private build 2.408s;
native fixture execution 1.244s. Host-only verification, no device/full830 claim.

Cases cover palette sorting/deduplication and tied residuals, gradient/highlight
unknowns, outlines/shadows and outline erosion, nested/enclosed/single-pixel
counters, validity holes, unowned pixels, foreground outside segmentation,
explicit unknown observation, supported/unsupported bridges, RF text/SFX and
owner-query channels, semantic/boundary float32 threshold neighbours, seed count
and area-fraction gates, 1.7em boundary/long components, context mass threshold,
border-connected background, morphology border behaviour and nearest-even EM
rounding, no clean fill, full/empty foreground, and 32 seeded random crops.
The fixture asserts that its long-component, counter, outline/shadow, supported
bridge and known-background suppression controls actually exercise those rules.

## API and parent handoff

- `SourceWeightInkInput` takes original RGB, ownership, style, existing
  primary/boundary/native/RF27/valid, cutoff and optional final sourceEm. RGB is
  uint8 RGB order, probabilities/native/RF are float32, masks uint8 nonzero=true.
  Caller must enforce source-local crop provenance/context bounds and align all
  evidence in the same original crop coordinates; this helper does no resampling.
- `SourceInkStyle` retains primary/alternate fill, primary/context background,
  observed context weights, outline/shadow present flags and RGB, outline width.
  Missing primary fill/background or malformed geometry/nonfinite inputs throw.
  No contrasting cleaned fill is a valid unknown observation, not an error.
- `reconstructSegmentedSourceWeightInk` defaults to 1.7em maximum components;
  nullopt disables only that rule. `reconstructSourceWeightInk` explicitly
  selects Segmented or ColorConsistent (default). The latter follows the Python
  uncapped baseline and then gives known direct colour priority, including
  suppressing known background. This is a rule choice, not a classifier.
- `alpha` alone is insufficient: carry `observed` (valid | palette-known), and
  preserve caller ownership separately. Unowned validity can remain observed
  exactly as Python; do not equate unknown with known zero. The standalone
  palette helper also exposes `known` explicitly. Audit recoveredPixels is
  measured before the final direct-colour override, exactly as the oracle.

Registration/policy gaps intentionally remain with the parent:

1. `Scripts/native-source-cv/build.py` recursively discovers new .mm files on a
   future normal full-feature build; core-only scans `Sources/` and will not
   include this root-level .mm. No build was invoked here. There is no ObjC/Swift
   packet adapter, umbrella declaration or runtime call wired for this API.
2. `FontWeightFeatures.mm` still uses existing `sourceFillAlpha(input)`; this
   task does not silently replace that shared kernel. Parent must map the
   predicted style/evidence packet into the typed input, explicitly select the
   rule, retain audit/observed/ownership, and connect alpha to the other worker's
   FontWeightBands path when intended.
3. Python source_runtime/affine_pairs/weight_bands currently use their existing
   `optimized_features.fill_alpha.predicted_fill_alpha` producer. Numeric parity
   of these reconstruction rules does not establish parity of that producer or
   authorize changing source runtime/default policy. Decide/document the common
   ink producer and any unknown-mask consumer policy explicitly before promotion.
4. Parent owns source runtime/Swift integration, default selection and full830
   verification. This prerequisite supplies no page-level, model, typography,
   source-weight accuracy, iOS or end-to-end acceptance claim.

Oracle SHA256 identities from the passing run:

```
segmented_ink_geometry.py b8cca34ce65ba1a3edaddd63a151d0cfb9174e1956d94378db572bbcf87a3060
color_consistent_ink.py 4de277eb96739c3dc8663eb916ba4a22ae908264e5a47473c2d9e09468065c8f
palette_word_pairs.py c3f00592c0bb928c4b0c8d8a595b408ebe7880352496d475d9104d384307ba02
ink_weight_geometry.py f3cffe6f2fdd8a6048be38c7b7946294780a5a31a795db94fc59c66671aa835c
```
