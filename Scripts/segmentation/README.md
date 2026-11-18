# Source-pixel and RF segmentation calibration

These tools calibrate a general source-pixel segmentation algorithm against the
merged segmentation GT. They do not change GT masks or production defaults.

## Measurement boundary

`NativeSegmentationGTReplay.swift` executes the actual production source-base
and chromatic completion kernels with fixed localization. It is not the full
removal pipeline: DB-dependent stages, final protection and AOT are absent.
An improvement here must be measured after real production integration before
it can be described as an app improvement.

`evaluate_gt.py prepare` verifies source/mask hashes. Run `resplit` after prepare:
it unions encoded source identity, decoded source RGB identity and duplicate
crop/localization identity before assigning train/dev/test partitions.
All complete and ambiguous GT instances remain in evaluation. Ground-truth
background pixels are never counted as foreground accuracy.

## Full RF evidence

`NativeRFFullEvidence.swift` exports all 300 queries, 5 class logits, boxes and
162-square raw mask logits from the actual Core ML model without class/query
acceptance thresholds. Sources are hash checked; all tensor values must be
finite. The Python consumer acknowledges one source before the next source is
allowed, bounding the transient raw tensor spool to about 32 MB.

`prepare_full_rf.py` produces 27 additional source-only channels:

- Every output class: maximum and weighted mean mask probabilities, box support.
- Every output class: most relevant owner-associated query mask and affinity.
- Semantic margin and mask uncertainty.

Owner affinity uses only fixed OCR localization geometry. Instance identities
select source evidence; query IDs are not numerical classifier features.
Source-coordinate sampling follows the native half-pixel bilinear convention.
For owner-associated masks, raw logits are interpolated before sigmoid. Global
multi-query summaries are formed on the native grid and then interpolated;
they are auxiliary signals, not exact source-resolution masks. Derived cache
channels are float16; the raw logits are consumed as float32 and then deleted.
Cache schema 2 rejects the earlier probability-before-interpolation variant.

The five class logits remain available as independent sigmoid probabilities;
the fifth output is not assigned an invented semantic class. Native accepted
classes remain text0, SFX1, balloon2 and frame3.

## Calibration and deployment gates

`pixel_rfdetr_fusion.py train` fits global pixel trees on train sources only.
`--full-rf` adds all-query RF evidence, yielding 62 source features. Prediction
workers receive a whitelist of source fields without GT paths/status/splits.
`predict-dev` and `tune` select a global threshold for highest development macro
IoU subject to preserving baseline development foreground recall. Test labels
are not used for candidate selection.

`export_forest.py` exports trees without OpenCV or training source identities.
`NativePixelRFForestReplay.swift` verifies portable native tree votes. Tree vote
parity alone is not image feature parity or final production-mask validation.
Runtime integration still requires native feature extraction, source-bound RF
evidence, ownership/protection handling, and final held-out evaluation.

The output directory contains one baseline, separate coarse/full RF candidate
models and source evidence. Avoid copying original pages or accumulating raw
model tensors. Visual inspection uses only provided crops with at most 15%
context per side; no full page visual inspection is needed.

## Reproduce the shipping primary forest

The native macOS and iOS loaders use the resources in
`Aidoku/Resources/Translation/SegmentationAcceptedFinal`. From the repository
root, rebuild the packed forest from its checked-in JSON and verify it against
its pinned digest:

```sh
python3 Scripts/segmentation/pack_primary_forest.py
python3 Scripts/segmentation/pack_primary_forest.py --check
```

The optional source-only Python runtime loads its selected models, policy and
numerical helpers from `assets/accepted-final`. `accepted_assets.py` validates
the package manifest and individual resource digests. The package can be used
from a checkout without the original training workspace. Rebuilding that entire
reference package with `package_accepted_final.py` requires the original
calibration inputs under `../segmentation-improvement-20261109`.
