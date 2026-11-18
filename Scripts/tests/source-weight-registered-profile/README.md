# Registered hard / soft stroke profile native prerequisite

Owned new files only:

- `Vendor/SourceInference/SourceWeightRegisteredProfile.h`
- `Vendor/SourceInference/SourceWeightRegisteredProfile.mm`
- this focused test directory (`main.mm`, `parity.py`, `README.md`)

No existing modules, shared kernels, build settings, registration, Swift,
source runtime or policy files are edited. The module is C++17/OpenCV in an .mm
file; it uses no Foundation, models, fonts, registration/word fitting, source
IDs, GT, classification, trained heads, filesystem or inference dependencies.
The other worker/parent supplies already aligned source/regular/heavy alpha.

## Input and output contract

`SourceWeightRegisteredProfileInput` contains aligned bounded source, regular,
heavy, known and unit. Alpha matrices are single-channel float32 or float64.
Known is uint8, float32 or float64, cast to uint8 with NumPy truncation/wrapping
before erosion; normal boolean known maps are uint8 0/1. No alpha clamping,
resampling, fitting or registration occurs. Borrowed matrix row strides and
crop-local borders are preserved, with BORDER_ISOLATED where needed so parent
cv::Mat storage cannot silently become context.

Entry points:

| Native API | Original Python |
| --- | --- |
| `sourceWeightRegisteredSignedDistance` | `registered_stroke_evidence.signed_distance` on binary 0/1 uint8 |
| `sourceWeightSoftProfileDepth` | `soft_stroke_profile.depth` |
| `measureSourceWeightRegisteredProfile` | `registered_stroke_evidence.profile` |
| `measureSourceWeightSoftStrokeProfile` | `soft_stroke_profile.profile` |

Signed distance uses a one-pixel zero pad for the inside and a one-pixel ONE
pad for the complement, crops both transforms back, and subtracts float32
precise-L2 distances. Empty-mask distance-transform values are preserved; they
are not replaced by fabricated zero distances. Soft depth casts alpha to
float32, uses >= for each level, subtracts +/- .5 edge corrections, accumulates
with the original float64 correction / float32 assignment sequence, and divides
by nine in float32. The exact alpha-level list is:

```
[0.1, 0.2, 0.30000000000000004, 0.4, 0.5, 0.6, 0.7000000000000001, 0.8, 0.9]
```

Both profiles retain positive normal-depth medial ridges qualified by
`nd >= dilate(nd)-.001`, 3x3 eroded trusted known, and positive heavy depth.
Hard informative centres require `bd-nd >= .75`; soft requires `>= .5`.
At least eight informative centres are required for usable numeric evidence.
The returned observation always contains:

- `correspondingCentres`, `informativeCentres`
- `newModelCreated=false`, `modelTrainingPerformed=false`, `usable`

`alphaLevels` is present ONLY for soft results, including unusable soft results.
The optional `measurements` aggregate is present ONLY when usable. Flatten its
six fields into the result dictionary when serializing to match Python:

- `medianWeightFraction`, `lowerWeightFraction` (.25), `upperWeightFraction` (.75)
- `correspondingSourceSupport`
- `medianNormalRadiusEm`, `medianSourceRadiusEm`

Do not emit zero/null placeholders for these six fields when unusable. Fraction
values are not clipped to [0,1]. Hard support is `source_depth > 0`; soft support
is ORIGINAL source alpha `> .5`, retaining float64 source precision even though
its soft depth is float32. Median and scalar quantiles preserve NumPy float32
arithmetic; normalized radii follow Python-float unit semantics (float32 division
of the float32 medians). NumPy float64 scalar unit promotion is not a separate
input type in this C++ double API.

Shape/nonpositive-unit errors throw `Registered stroke geometry differs` for
hard, and `Invalid soft stroke geometry` for soft. Nonfinite hard evidence
throws `Nonfinite registered stroke evidence`; soft uses its single geometry
error. Original hard NaN/+infinity unit behaviour is retained: no finite-unit
check, with NaN/zero normalized radii when usable. Soft requires finite positive
unit. The typed API additionally rejects empty/wrong-type matrices; callers
must honor the declared two-dimensional buffer contract. Standalone signed
helper requires binary 0/1 uint8. No input validity gate silently selects a
fallback reference/profile or classifies the source.

## Original Python oracle

Run from the Aidoku Git root:

```sh
PYTHONDONTWRITEBYTECODE=1 .venv-source-inference/bin/python Scripts/tests/source-weight-registered-profile/parity.py
```

The runner imports the unmodified original profiles, depth, signed_distance and
LEVELS directly. No oracle monkeypatches, replacement distances, source files,
fonts, models, IDs or saved image crops are used. Arrays are generated bounded
numeric calibration patterns. Native inputs are padded borrowed ROIs surrounded
by hostile values, so incorrect use of storage beyond the crop boundary fails
against Python. SHA256 checks cover both original Python files and all four
existing SourceWeightInk/SourceWeightStrokeGeometry files before/after.

Passing host run 2026-11-12:

- 384 comparisons: 110 hard profiles, 108 soft profiles, 83 signed-distance
  matrices, 83 soft integrated-depth matrices.
- Hard profiles: 74 usable; soft profiles: 75 usable. Unusable field omission,
  exact soft alphaLevels, both centre counts and flags match exactly.
- 888 finite profile numeric fields compared; maximum absolute error 0.
  Signed-distance and soft-depth array maximum absolute errors also 0.
  Assertions allow 2e-6 absolute error, zero relative tolerance.
- 26 invalid-input controls rejected with exactly the original Python messages.
- Includes regular/heavy endpoints, same-binary antialias changes, intermediate
  fractions, unrelated thick paint, integer shifts and fractional interpolation,
  source occlusion versus unknown occlusion, all unknown/empty/full arrays,
  absent/equal references, exact 0/1/7/8/9 centre-count controls, all nine alpha
  levels with nextafter neighbours, soft radius gates, counters/rings/diagonal
  junctions, all four crop borders, one-row/one-column/tiny arrays, float64 source
  threshold neighbours, known uint8 truncation/wrapping, nonfinite evidence,
  distinct hard/soft unit semantics and 24 deterministic random shape families.
- Python OpenCV 4.13.0; native vendored OpenCV 4.11.0. Private standalone build
  2.005s; native fixture execution 0.985s; macOS arm64 host only.

Only the new .mm and new test driver are compiled and linked against the existing
vendored OpenCV archive in a private TemporaryDirectory. No shared/app build,
whole-page views, public-source inference, full830 or device verification runs.

Original file identities:

```
registered_stroke_evidence.py f2ec9c037c745f3e1ab5a737201c52dc5d650e4e16569213c71887c82fa44ab1
soft_stroke_profile.py 08678b50fe99fd040a86643ac8c898f8b5d24fd0e81e236642b64fe9a66e604f
```

## Remaining parent handoff

No registration/umbrella or ObjC/Swift packet adapter is added. A future normal
feature build discovers root .mm files recursively; the core-only Sources scan
does not include this module. Parent owns native policy orchestration, mapping
these typed sparse observations into its exact policy dictionaries, selecting
which already aligned source/reference alpha to measure, reference callback and
word-fit integration, unit provenance, policy/hash gates and default decisions.
The other worker remains responsible for word fit/fonts callbacks. Parent owns
full830 public-source inference and end-to-end acceptance. These numeric-only
profiles make no source-weight classification or visual quality claim.
