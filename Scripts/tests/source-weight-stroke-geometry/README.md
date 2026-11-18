# Bounded source-weight stroke geometry prerequisite

Only new files are owned here:

- `Vendor/SourceInference/SourceWeightStrokeGeometry.h`
- `Vendor/SourceInference/SourceWeightStrokeGeometry.mm`
- this focused test directory (`main.mm`, `parity.py`, `README.md`)

Existing SourceWeightInk helpers are reused without editing them. No shared
kernel, registration, Swift, nativeStage, runtime, default, policy or app build
file is changed. There are no trained heads, classifiers, GT, IDs, font loading,
model inference or whole-page image views.

## API mapping

| New API | Actual Python operation |
| --- | --- |
| `sourceWeightOpposedWidths` | `ink_weight_geometry.opposed_widths` |
| `measureSourceWeightDirectional` | `directional_ink.measure` |
| `measureColorBackedSourceWeightDirectional` | `directional_ink_rules.measure_source_page` colour preparation followed by `measure` (measurement only, no policy/hash gate) |
| `observeSourceWeightStrokeGeometry` | `ink_weight_geometry.observe` |
| `observeSourceWeightStrokeAlpha` | Same observe geometry stages from explicitly supplied alpha/observed, without palette reobservation |
| `observeReconstructedSourceWeightStrokeGeometry` | `segmented_ink_geometry.measure` post-reconstruction neutral-signal preparation and `observe` stages (no outer audit/model-provenance metadata) |

Alpha is CV_32FC1, RGB is CV_8UC3 in RGB order; all known/observed/ownership/mask
maps are CV_8UC1, nonzero=true. Inputs may have arbitrary row strides. Caller
retains bounded original source crop provenance and aligns its evidence.
Typed observations preserve Python field names and zero-array/null structures.
`directionContrast` is optional and stays null unless at least two groups have
12 rays; directional quantiles are [.1,.25,.5,.75], and observe paired quantiles
are [.25,.5,.75,.9]. Component median/upper each contain eight values in the
original order. No output is itself a classification or admission decision.

Directional component bound defaults to the original 1.7em; explicit nullopt
allows long connected components. It does not silently change the source
policy. Observe retains its original fixed 1.7em qualification at all three
cutoffs. Reliable known edges are eroded exactly as Python, independent of the
component mask. Rays sample row-major edges, truncate using linspace-to-integer
indices, step in half pixels, use nearest-even pixel rounding, and terminate at
the FIRST non-mask hit even when that hit is rejected. No ray jumps an unknown
pixel to find a later, more convenient boundary. Floating expression contraction
is disabled inside the new implementation to preserve NumPy's operation order.

Observe also preserves the 800-pixel long-axis INTER_AREA resize, >.99 known
threshold, nearest ownership resize, scaled bbox slices/overlap, padded component
precise distance transform, medial ridges, all CCOMP contour perimeters and hole
areas, and component-balanced quantiles. It does not dilate the input alpha.

Scale/shape failures throw std::exception with the corresponding Python error
messages. Relevant nonuniform error semantics are retained: directional rejects
nonfinite alpha; opposed_widths does not add that validation. Directional NaN
unit returns its original zero structure, while infinite unit errors; observe
and opposed reject nonfinite/nonpositive scales. Typed APIs enforce their matrix
types rather than silently casting arbitrary buffers. The new reconstructed
bridge additionally requires finite alpha in [0,1].

## Two source policies must stay distinct

The old directional source path uses clean_fill_style/observe_palette and
**color * ownership**, with its palette known map. When cleaning yields no fill,
that path uses zero alpha and known=ownership. It must not silently receive
reconstructed alpha. By contrast, observe with no clean fill uses zero alpha
and known=all-ones; that distinct observedFraction is preserved.

Reference eligibility uses the BASELINE segmented reconstruction (default
1.7em), then an in-memory neutral signal:

```
signal = repeat(rint(255*(1-alpha)).astype(uint8), 3)
neutral = black fill / white background
observe(signal, bbox, em, ownership & reconstructed_observed, neutral)
```

The reconstructed bridge implements that conversion, including float32
arithmetic and nearest-even quantization; it reobserves the neutral palette.
It is not equivalent to passing alpha/observed directly to the alpha-stage API.
Reference source subsequently uses color_consistent_ink reconstruction for its
word measurement; it must not substitute that uncapped/direct-colour result
for the earlier baseline eligibility geometry. Parent owns all admission
thresholds (including pairedQuantiles/components), raw/paired/bands composition,
source policy/hash checks and imagepolicies.

## Focused numeric oracle

From the Aidoku Git root:

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Scripts/tests/source-weight-stroke-geometry/parity.py
```

The runner imports original unmodified Python functions, without monkeypatches,
rewrites or replacement arithmetic in the measured algorithms. It compares all
returned numeric arrays/scalars, counts, field sets, strings, flags and nulls;
14 invalid inputs are checked against original Python errors (the negative
linspace sample count checks error presence, not NumPy's version-specific text).
It checks original Python and existing SourceWeightInk hashes before/after.

Passing host run 2026-11-12:

- 308 observations: 81 opposed-widths, 103 directional, 32 RGB observe,
  33 explicit-alpha stages, 32 colour-backed directional, 27 reconstructed
  neutral-signal eligibility observations; 14 additional invalid inputs.
- Counts, vector lengths, group names, null/zero structures and flags match
  exactly. 39,242 floating numeric fields compared; maximum absolute error
  1.862645149230957e-9 (assertion tolerance 2e-6).
- Includes empty/full/unknown maps, reliable-edge holes, first-hit ray failure,
  anisotropic/diagonal/ring strokes, thin/thick and long connected components,
  explicit uncapped variant, exact alpha and squared-EM area gates, fractional
  ray-length limits, heterogeneous >6000-edge populations and maximumEdges
  6000/5999/73/71/37/31/3/2/1/0, nested contours/counters, palette gradients,
  outlines/shadows, ownership holes, bbox overlap/fractional/clipped/empty slices,
  800-pixel resize boundary, baseline-reconstruction reference signal, neutral
  quantization and 18 deterministic random crop families.
- Every native input uses a padded ROI to exercise borrowed row strides.
- Private temporary standalone build: 4.827s; native fixture execution: 0.827s.
  Python OpenCV 4.13.0, native vendored OpenCV 4.11.0; macOS arm64 host only.

The runner compiles ONLY the new .mm, existing SourceWeightInk.mm, and its new
focused test driver into a private TemporaryDirectory against the existing
vendored OpenCV archive. It never invokes shared build tooling or an app build.

## Remaining parent integration / policy gaps

The normal feature build recursively discovers root-level .mm sources, but its
core-only scan of `SourceInference/Sources` does not include this module. No
build/umbrella registration or ObjC/Swift adapter was added. Parent must wire
its source-bound nativeStage inputs, carry the typed outputs, maintain original
colour-only directional versus reconstructed-neutral reference eligibility,
and select policies explicitly before changing defaults. Full830 verification,
raw/paired/bands/imagepolicies integration, iOS and end-to-end quality acceptance
remain the parent's work; focused parity does not claim any of those outcomes.

Oracle identities:

```
directional_ink.py 9373c42e6c31604fc7f222c1e969615a4f3db0a7e863d59567ba059d53367d48
ink_weight_geometry.py f3cffe6f2fdd8a6048be38c7b7946294780a5a31a795db94fc59c66671aa835c
palette_word_pairs.py c3f00592c0bb928c4b0c8d8a595b408ebe7880352496d475d9104d384307ba02
segmented_ink_geometry.py b8cca34ce65ba1a3edaddd63a151d0cfb9174e1956d94378db572bbcf87a3060
color_consistent_ink.py 4de277eb96739c3dc8663eb916ba4a22ae908264e5a47473c2d9e09468065c8f
SourceWeightInk.h 2f8a74dab17b09707a8c01060219fad21d6e0d93640d5f70b1f676529d38473b
SourceWeightInk.mm 61232566621eaa7819392a030bedccaee0a963b1459c379bd2da294c5c734bd8
```
