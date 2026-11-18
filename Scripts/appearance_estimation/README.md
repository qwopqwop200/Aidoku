# Source appearance estimation

The current fused estimator estimates original fill, outline colour/presence/width, shadow presence and nearby background from original RGB, a predicted removal mask, pre-threshold primary/boundary pixel probabilities, 27 RF semantic/owner-query/bbox-confidence planes, eight OCR confidence/availability maps, and individual plus exact merged source bbox geometry. The older RGB/mask estimator remains a comparison baseline. Display outline/readability policy is separate. No page IDs, GT colours, GT pixel anchors or GT masks enter inference. Detected polygons/font size are optional source geometry.

`source_appearance.py` extracts source colour candidates, CIELAB separation, fill/contour enclosure, contact, exterior continuity and directional dark-fringe evidence. Small regularized gradient-boosted tabular models rank candidates and classify presence. This adds no CNN. Width uses original-pixel fill→outline→background rays plus a separately calibrated regression with approximate uncertainty.

`optimize_appearance.py` trains only on TRAIN and chooses hyperparameters/thresholds on DEV. The connected components of identical **source image hashes OR crop hashes** are assigned together. The existing corpus has previously been inspected; its TEST partition is not a new external generalization guarantee. The benchmark uses fixed GT-derived crops/localization and frozen predicted pixel/RF segmentation outputs. It does not establish full native-page pipeline accuracy.

Run repeated calibration using the existing environment:

```sh
task_python=./.venv-source-inference/bin/python
"$task_python" Scripts/appearance_estimation/optimize_appearance.py --gt ../labels/appearance-merged830-20261109-r64-review3/appearance-gt.json --masks ../segmentation-improvement-20261109/oof-style-pruning/actual-target --out ../appearance-estimation-20261109 --jobs 8 --rounds 8
"$task_python" Scripts/appearance_estimation/refine_heads.py --gt ../labels/appearance-merged830-20261109-r64-review3/appearance-gt.json --out ../appearance-estimation-20261109
"$task_python" Scripts/appearance_estimation/calibrate_shadow.py --gt ../labels/appearance-merged830-20261109-r64-review3/appearance-gt.json --out ../appearance-estimation-20261109
"$task_python" Scripts/appearance_estimation/calibrate_width.py --gt ../labels/appearance-merged830-20261109-r64-review3/appearance-gt.json --masks ../segmentation-improvement-20261109/oof-style-pruning/actual-target --out ../appearance-estimation-20261109 --jobs 8
"$task_python" Scripts/appearance_estimation/build_report.py --gt ../labels/appearance-merged830-20261109-r64-review3/appearance-gt.json --out ../appearance-estimation-20261109
```

Feature and width evidence caches are source-bound and overwritten/reused rather than retaining image copies per iteration. Eight role configurations plus independent field selection and nine width configurations are evaluated by the default workflow. Increase `--rounds` to extend automatic search. Progress, history, grouped-split checks, model hashes and actual saved-output metrics are retained. GT is never rewritten.

Width calibration also compares two ExtraTrees regressors per source-background context against the existing gradient-boosted regressors and retained incumbent. The same TRAIN-only fitting and DEV interval-accuracy/MAE selection apply; source measurements, feature order and standalone inference remain unchanged. The bounded `rf-seg-fusion/width-family-study` preserves the selected model, exact replay parity, one post-selection TEST comparison and a width-only promotion receipt. Its frozen 3,819 outputs differed only in predicted width and uncertainty interval after promotion.

For explicitly requested continuous search, `continuous_optimize.py --gt ... --masks ... --out ... --cycles 0` runs indefinitely. It advances the parameter-search offset, compares extra-tree families, calibrates rare shadow positives by DEV F1 and recomputes width/report outputs. The `champion/` directory contains the retained complete estimator and crop-only viewer; candidate files in the parent may change during a cycle. Only a higher combined DEV score with no per-field colour, outline-presence, shadow-F1 or width-interval regression replaces it. Failed/rejected runs restore the champion. `LOOP-STATE.json` records the live PID, phase and bounded history; `CYCLE.log` is overwritten each cycle. A termination signal stops the current child process group and restores the checkpoint. Source/GT/code changes stop the loop for explicit relaunch, preventing mixed contracts. The native app is not changed by running this search.

Standalone inference accepts no GT argument:

```sh
"$task_python" Scripts/appearance_estimation/infer_appearance.py --image /absolute/source-crop.png --mask /absolute/predicted-mask.png --model ../appearance-estimation-20261109/model.pkl --width-model ../appearance-estimation-20261109/width-model.pkl --geometry /absolute/detected-geometry.json --out /absolute/style-prediction.json
```

Geometry JSON may contain only `polygons` and `fontPixels`; it is optional. A model/feature-version mismatch is rejected. No source image or output resolution is changed.

Metrics distinguish candidate outline colour from actual outline presence, and width errors are computed from the emitted width (zero for predicted absent outlines), not a hidden regressor output. RGB uses CIELAB ΔE76; colours within 10 are counted as similar. Width is also checked against hand-authored GT intervals, with a separate explicit ±1 px tolerance metric. Shadow positives are rare (13 total); confusion matrices and positive recall are reported. Intrinsic shadow opacity/blur cannot be recovered uniquely from one composite and are unlabelled in this GT, so they remain null rather than fabricated.

Shadow presence alone does not establish parameter accuracy. Run `audit_shadow_parameters.py --gt GT_JSON --predictions CHECKPOINT/predictions-with-width.json --out AUDIT_JSON` to count actual emitted `shadow.rgb` and `shadow.offsetPx` against available labels. Abstentions and predicted-absent shadows count as missing parameter outputs; pixel-role palette hypotheses do not count as scalar shadow-colour predictions. Empty labelled splits report null rather than a misleading success rate. The current corpus has four colour labels across three source pages and six offset labels; its TEST split has no shadow RGB labels.

The retained `source_shadow_observation.py` combines native physical paint with a bounded bonus from the existing RF/pixel/OCR role model. `shadow_displacement_evidence.py` selects a categorical paint displacement on alternating owned source components and validates it on the rest, including an opposite-direction control. Components whose required context crosses the original crop are excluded. The v4 head fills three of four RGB labels and two of six offsets on the existing corpus. The two prior RGB estimates retain ΔE 1.28/4.44 and offset errors 1/2 px; the new local diffuse estimate has ΔE 7.85. `local_source_core.py` recovers repeated finite glyph components when a global fill/background similarity shortcut fails despite visible local contrast. `shadow_glow_profiles.py` requires native dip/recovery profiles and external background controls; `shadow_background_normalization.py` validates attenuation across disjoint components, then emits an actual dark source-pixel medoid rather than an invented intrinsic pigment. Crop-edge profiles are censored. Warm replay retains the same corroboration as fresh inference. `source_shadow_presence.py` selects a confidence threshold on TRAIN/DEV while preserving independently corroborated displacement/glow; it retains all 13 labelled positives and removes four false positives on this historical corpus. Final emitted presence, rather than the raw classifier flag, is used in the v8 objective/report and TRAIN/DEV no-lost-TP/no-added-FP guards. Policy hashes bind all helpers and paired models. Independent CLI replay of the new diffuse case matches actual batch style values; diagnostic measurement/provenance fields are recorded separately. No shadow RGB-labelled TEST cases or external validation support a broader accuracy claim.

`native_colour_neighborhoods.py` proposes native medoids using LAB neighborhoods across RGB-bin boundaries. A newly added colour must have twice the observed support of the next distinct mode before the existing component-displacement gate can accept it. Otherwise it abstains; already validated legacy estimates and emitted parameters are preserved. Sparse confident-role colours may also propose a neighbourhood, using the same dominance and geometric checks. The paired policy binds this module's hash too. Bounded source replay and standalone CLI parity are recorded in `rf-seg-fusion/shadow-palette-neighborhood-study`; probability differences of order 1e-16 are distinguished from actual style changes.

`apply_source_shadow.py` attaches this head to saved predictions after fill-palette inference and records exact model/source-code bindings in `SHADOW-OBSERVATION-POLICY.json`. Standalone `--estimator` enables the paired policy automatically; explicit `--source-shadow-observation` requires the complete RF/segmentation/OCR payload and pixel-role model. Continuous fused search now runs this stage and scores actual parameter accuracy with missing outputs counted, preserving TRAIN/DEV colour/offset hits and precision and rejecting extra known-negative emissions. Score version v7 reserves 1% for shadow parameter accuracy, so its absolute score is not directly comparable with v6. Only the standalone estimator/calibration pipeline changes; native-app integration remains separate.

`shadow_direction_evidence.py` is an unpromoted source-only experiment: exterior colour samples vote on nearest owned glyph-paint direction, with sublinear component support and rotation-independent agreement. Synthetic checks cover rotated displacements, symmetric non-shadow halos and disjoint fill-colour ownership. The bounded `shadow-direction-study-v2` recovers both DEV observed-colour labels and rejects the earlier TRAIN false emission, but still emits one colour on a historical TEST shadow-negative item. Expanding to all predicted fill colours (`v3`) reduces DEV recovery to one while retaining that false emission. These studies do not replace the retained predictor or fill its missing intrinsic RGB/offset fields. Their saved decisions precede GT scoring; archived source-rule copies preserve the earlier feature contracts. A coherent direction alone is insufficient evidence of the same glyph boundary repeating at a displacement.

The crop-only `review/index.html` displays GT alongside saved predictions and filters error candidates. It links existing crops with at most 15% context per side. The native app's runtime/default renderer is unchanged by this experimental estimator.

Background colour now also supports `background_palette.py`: `train_background_palette.py` learns multiple valid surrounding colours rather than forcing mixed artwork into one RGB. Target labels use the union of supplied GT text masks across overlapping crops; those masks are used only for supervision and evaluation. Source features instead use the union of available **predicted** text masks, preventing neighboring text from becoming background evidence. Dense non-text pixel coverage and selected-colour validity are reported separately from the unchanged primary-RGB score. No clean background hidden beneath glyphs is claimed.

For standalone palette inference, add `--background-palette-model /path/to/background-palette.pkl` and, where available, `--context-mask /path/to/predicted-text-union.png`. The context mask must match the original crop exactly. Without it, own-mask-only context is explicitly recorded; empty visible context has unknown mixture weights. `--apply-to ESTIMATOR_DIRECTORY` in the palette trainer attaches colours and observed-context weights to saved predictions while preserving their primary RGB. Continuous search now includes this stage and checks DEV colour validity and background coverage before publishing.


Observed outline rings now have a separate source-only head (`outline_layers.py`). Normal profiles must agree on colour order across multiple directions, have a sharp outer boundary, and show the proposed ring colour disappearing outside its narrow annulus. This rejects background artwork and soft shadows that look like a second colour along individual rays. Antialias transitions contribute half their width to neighbouring rings. The retained width model enables this head through its versioned `sourceOutlineLayersVersion`; standalone inference adds `observedLayers` and `totalObservedRingWidthPx`. Original scalar `widthPx` and all legacy colour/presence outputs remain unchanged: some hand-labelled nominal total widths disagree with their own sum of layer widths, so silently replacing one with the other would corrupt benchmark semantics. GT is not rewritten.

The exploratory 3,819-crop audit recovered four of eight labelled multi-ring regions with zero extra multi-ring outputs (TRAIN 2/2, DEV 1/5, TEST 1/1). These small, repeatedly examined counts are not an unseen-data precision guarantee. `OUTLINE-LAYERS-RESULTS.json` and `outline-layers/ATTACHMENT-PARITY.json` record scope and legacy-output parity. Continuous search audits and attaches this additive head before palette/report generation; a DEV false positive rejects that candidate. Separate silhouette/component shadow-offset experiments (`shadow_template_fit.py`, `shadow_component_fit.py`) have not recovered dependable offsets on the real labelled crops, and remain unpromoted; strong synthetic results do not establish real-crop accuracy.


`nested_outline.py` adds an independent bounded-contour recovery path. It requires multiple owned fill components enclosed by a bounded colour component, repeated exterior contrast, and a contour following the glyphs rather than a rectangular sign panel. This supports source fill→white→dark configurations even when the fill and outer edge share a colour and the initial classifier says no outline. It is enabled by the retained width model's `sourceNestedContourVersion` and takes only RGB/predicted masks/source geometry at inference. The raw classifier probability is preserved and explicitly distinguished from the final source-corrected presence decision. Width is recomputed with the same frozen source width regressor.

`recover_nested_contours.py` applies this path before multi-ring/palette stages and evaluates the **actual corrected saved outputs**. Both `BEST.json` presence metrics and `WIDTH-RESULTS.json` emitted-width metrics are updated; the latent classifier score is not substituted for the final decision. The current exploratory corpus adds two DEV contours with no new false positives across the 3,819 crops, changing DEV outline FN 7→5; both recovered widths lie in their GT intervals. All TEST outputs remain unchanged. DEV false-positive, false-negative and emitted-width-interval guards protect future candidates. Three initially proposed rectangular panels were rejected by the source topology rule; GT was not changed.


The RF fusion branch is under `../appearance-estimation-20261109/rf-seg-fusion`. `prepare_fused_features.py` consumes the authenticated existing native RF and soft-pixel observations and whitelisted source OCR fields. Raw RF/pixel arrays are not retained per experiment; only compact candidate statistics are cached. The current 209 features include per-colour RF mask/class confidence/owner affinity, primary/boundary posterior disagreement, OCR detection/recognition/token confidence, individual and merged box ownership distances, relative axes, and RF×pixel interactions. Candidate colours cover the complete predicted text mask; boxes never discard colours outside their bounds. Source OCR text, GT reference IoU, target masks, keep decisions and page identity are excluded from features. Tests explicitly verify this exclusion.

`train_fused_appearance.py` fits on grouped TRAIN and selects on DEV; `refine_heads.py`, fine shadow calibration, source corrections, width and background-palette calibration consume the same fused packets. `audit_fusion_usage.py` records the actual tree split variables, proving that RF, soft pixel, OCR and geometry evidence reaches the estimators. Ordered physical-layer colour/width accuracy is reported separately from merely detecting two rings; only two of eight labelled multi-ring cases currently meet the complete ordered colour/width criteria. This remains active work, not complete layer reconstruction.

Standalone fused inference requires a source-only NPZ containing aligned RF/soft pixel/OCR arrays, RGB and predicted-mask hashes, RF weights hash and embedded source geometry. `export_fused_source_evidence.py` creates that payload from existing source producer receipts and a whitelisted source packet; it accepts no style GT. The model rejects absent evidence, mismatched RF weights, RGB/mask identities, geometry or feature versions. Six actual crops have exact prepared-feature and standalone-prediction parity. No whole-page visual inspection, source RGB resizing or GT rewrite is involved.

Use the active checkpoint through `infer_appearance.py --estimator ../appearance-estimation-20261109 --image ... --mask ... --source-evidence ... --out ...`; explicit `--model`, `--width-model` and `--background-palette-model` remain available. `continuous_optimize.py --fused --gt ... --masks ... --out ../appearance-estimation-20261109/rf-seg-fusion --cycles 0 --rounds 8` iterates the fused branch without regenerating large source tensors. The native iOS app is unchanged by this Python estimator work; the historical, repeatedly inspected fixed-crop corpus is not an unseen-page accuracy guarantee.


Pixel paint-role estimation now uses TRAIN annotation points as supervision, with RGB/local contrast, all 27 RF planes, both soft segmentation posteriors, all eight source OCR maps, exact source box geometry, predicted paint-colour distances and source outline evidence. `train_pixel_roles.py` fits four bounded tabular configurations on TRAIN only and selects on DEV; annotation coordinates/roles never enter `pixel_role_estimation.py` inference. The initial retained 71-feature head changes held-out TEST point-role accuracy from 89.21% (mask-conditioned nearest source paint colour) to 98.55% on 2,410 annotated points. These are point-role metrics, not dense-mask IoU or intrinsic-shadow accuracy. Shadow pixel supervision has only eight TRAIN samples and does not identify physical shadow opacity/blur.

The active checkpoint attaches sampled per-role observed colour palettes and probabilities as `pixelRoleEvidence`, preserving all original scalar colour/width/presence outputs and GT. `--estimator` automatically loads the checkpoint's paired `pixel-role-model.pkl`; inference verifies its source appearance-model hash. Fused continuous search with a pixel-role checkpoint requires `--source-root ../segmentation-improvement-20261109 --ocr-evidence ../model-refresh-20261106/retraining-fp16-830/evidence`; each candidate refits this role head against its own final colour predictions and enforces DEV point-role accuracy/macro-F1 no-regression before publication.

Source normal profiles now reject every coordinate or boundary-contrast window extending outside the original RGB crop, without widening the permitted context. A paired 3,819-region audit excluded 244,129 unobserved coordinates and changed no retained scalar colours or ring widths. Archived paired evidence is under `rf-seg-fusion/bounded-profile-audit`; `source_profile_sampling.py` is the shared retained implementation. Retained source ring and primary-contour versions are v4 and v2 respectively.


`final_background_refinement.py` applies a frozen TRAIN-fitted local exterior palette ranker after the learned, width, shadow and paint-role heads. The independent gradient-contour observation may follow it without feeding corrected RGB back into any earlier conditioned head. It combines native non-text exterior colour support, visible/border palette support, existing observed context weights and RF/seg/OCR-derived pixel-role evidence. It changes only `background.rgb` and correction provenance; palettes, original ranker indices, fill, outlines, widths and shadow outputs remain untouched. Warm replay restores the pre-correction RGB before remeasurement, avoiding cumulative corrections. The policy binds six model identities and the helper hash. `apply_final_background.py` reconstructs context from overlapping predicted text masks; no GT styles, anchors or masks enter inference.

The retained historical-corpus replay improves 13 background representatives with no categorical losses or other-field changes: TRAIN mean ΔE 1.36079→1.35489, DEV 2.24528→2.20981, and descriptive TEST 2.11507→2.08128. The fixed 10-ΔE failure counts remain unchanged. Source-only standalone CLI replay matches the batch style and evidence, apart from context provenance labels and item identification. These small paired changes do not establish unseen-page accuracy. `appearance-common-causes-study/PROMOTION.json` records the admission and scope.

Continuous scoring v9 keeps the existing aggregate quality score, then breaks a score tie using lower actual emitted DEV background mean ΔE. TRAIN/DEV background mean and within10 rates must not regress. This uses the final emitted RGB rather than the original ranker index, which remains provenance after this post-head correction. Each cycle rebinds the frozen background classifier to its current complete checkpoint and evaluates the actual candidate outputs before promotion.

The `width-normal-study` measured source-band normals on all 3,819 crops and passed synthetic width/angle checks. Its DEV improvement did not retain the held-out interval hit count, so its measurement and model remain experimental. `observed-shadow-boundary-study/v2` passed real positive-control observability but recovered no missing scalar parameters. `layer-recovery-common-study/v2` introduced false multilayers without recovering labels. Neither is connected to inference. Their diagnostics support further boundary/gradient work rather than threshold-only rescue or a claimed quality gain.


`source_gradient_core.py` measures finite native colour-connected interiors with repeated, parity-validated spatial gradients. `source_gradient_contour.py` confirms at least three fill seeds with the existing pixel-role classifier plus direct RF owner affinity, soft segmentation and OCR evidence, then `native_gradient_contour.py` follows the actual body edge. A bounded dark band must have sharp entry and recovery, repeated opposing profiles on multiple components, and coherent hue. Observed antialias/composite shades contribute to a native RGB medoid with recorded colour spread; no intrinsic pigment or new width is inferred. Model/classifier confidence and original ranker indices remain provenance.

The final contour stage changes only `outline.rgb` and its own correction metadata. Warm replay restores the prior RGB first. Policies bind six frozen models and every participating source helper. Source arithmetic explicitly promotes RF scalar products so the same quantized RF payload yields identical evidence from fp16 CLI and fp32 cached replay. The full 3,819-region historical audit changes one DEV contour from gray to observed brown (ΔE 50.81→9.95), with no other style outputs changed. The threshold hit is close to10 and is not an external accuracy guarantee or successful recovery of both outline layers. Synthetic dark/light/soft-shadow/hue-conflict controls, source ownership and warm/pairing tests accompany the source-only CLI/batch comparison.

`evaluate_predictions` now scores actual emitted RGB, including native colours absent from the coarse candidate palette. Candidate indices preserve the earlier ranker choice; `candidateCeilingWithin10` describes only that original palette and is not an upper bound after source-native corrections. Continuous scoring v10 and saved reports consume the final emitted predictions. The native iOS app remains unchanged by these host estimator calibrations.

The v11 final primary-colour head also handles bright native interiors when the
ranker confuses fill with a similarly bright ground. `source_bright_ring.py`
requires three repeated bounded interiors, thin surrounding source bands,
substantial native ring support, and independent RF/soft-segmentation/OCR
ownership. A small closure only proposes topology; emitted RGB is witnessed at
an actual native pixel. Local witnesses at the crop edge are excluded without
rejecting a valid interior merely because unrelated connected artwork reaches
the edge. Native colour sample mass precedes hole count in candidate ranking,
avoiding weak antialias shades winning by fragmentation. The established
gradient-body observation retains precedence; warm v1/v2 evidence is restored
before source remeasurement.

The paired 3,819-crop replay changes one additional DEV outline RGB (DeltaE
49.77 to 8.86) and preserves every other style value exactly. All 3,115 labelled
primary outline colours are now within DeltaE10 on this historical corpus;
outline-presence errors, multi-layer reconstruction, widths, and missing shadow
parameters remain separate unresolved tasks. Source-only full CLI parity covers
the new bright case, the prior gradient case, and a solid-colour control.
`bright-interior-ring-study/PROMOTION.json` records paired output and model/code
identities. This is not an unseen-image accuracy claim. The bright path uses
first-detector OCR confidence and repeated source topology; unlike the gradient
seed gate, secondary-detector confidence is not currently an independent veto.

`source_outer_shell.py` and `source_outer_shell_geometry.py` reconstruct finite
native fill bodies from the fresh primary head's in-memory RF/seg/OCR ownership
certificates. They trace fill -> primary -> white -> distinct stable exterior,
requiring repeated components, opposing directions and coherent band distances.
Four translated body controls must have lower coherence than the aligned body;
the excess threshold is frozen from TRAIN negatives. Missing exterior transitions
are censored, and equal white halo/background cannot be identified. A native RGB
witness and observed width interquartiles accompany each added secondary band.

The final head only attaches `outline.observedLayers` and its own warm-reset
provenance, preserving existing multiple layers and all scalar colours, presence,
nominal total width, probabilities and shadows. The six paired models, primary
source policy and runtime helpers are hash-bound. `apply_outer_shell.py` rebuilds
ownership from original source evidence for all items rather than consuming a
study result. Standalone inference uses that same fresh diagnostic directly.

The 3,819-crop replay adds one correct ordered layer pair: DEV colour/width
matches 1/5 -> 2/5, with no new false multilayers and all other output values
exact. Across the historical corpus, complete ordered matches become 3/8.
Full source-only CLI replay covers the addition and two unchanged controls.
TRAIN contains no white-outer positive and both white-outer DEV positives share
a page, so this is scoped source-observation evidence, not established unseen
precision. `owned-outer-boundary-study/PROMOTION.json` records the admission;
the earlier bounded probe's sparse-data rejection is retained as research history.

Continuous objective v12 reserves 0.5% for the final ordered colour-and-approximate
width F1. Missing audits earn zero in this component, and additional incorrect
layers reduce it. TRAIN/DEV strict matches and false-layer counts must also
retain their previous quality. Ordered layers are audited after the final source
head, preventing a stale earlier audit from scoring the new output. v12 scores
have a different scale from v11. Original crop context remains <=15% per side;
this is not a crop-area/page-area limit. The native iOS app is unchanged.

`width_resolution.py` calibrates the nominal scalar output on a global native
pixel grid. The prespecified choices are unchanged, 0.125, 0.25, 0.5 and 1 pixel;
TRAIN/DEV interval hits and mean absolute errors must not regress, then DEV hits
and error choose the resolution. It uses no image/page/category key. The retained
0.5-pixel choice changes any existing positive nominal estimate by at most0.25px,
keeps the 0.25px lower bound, and is idempotent. This is annotation-aware nominal
width calibration, not new pixel evidence or a remeasurement of physical rings.
The width artifact binds the helper bytes and recalibrates the DEV uncertainty
radius. Legacy artifacts with no resolution remain unchanged.

All four emitters use the same predictor: ordinary inference, width calibration,
nested-presence recovery and primary-colour recovery. The optimizer retains the
calibration when considering an incumbent and reselects only on TRAIN/DEV for
new fitted models. TEST labels cannot affect this selector. v13 keeps v12's
score weights and evaluates the actual final emitted width values.

The cold full source replay adds13 width-interval hits with no lost hits:
TRAIN1781/1789 unchanged, DEV679->685/693, and descriptive TEST597->604/633.
TEST MAE becomes0.41090px from0.43218px. Replaying width-conditioned shadow
geometry also changes one validated displacement from[3,2] to[3,3], reducing its
GT error2px->1px; other shadow parameters and all colours/presence/palettes/layer
widths remain exact. Seven source shadow diagnostic records are recomputed rather
than reused. Six standalone CLI cases, including nested recovery, primary recovery,
shadow displacement, final outer layers and a solid control, match batch outputs.
`width-resolution-study/PROMOTION.json` records the pairing and limits. This is
still a historically inspected fixed-crop benchmark, not external validation.

The v14 final background classifier uses102 source features: the preserved15
colour/support features plus87 exact-local RF/soft-segmentation/OCR descriptors.
`source_local_background_fusion.py` evaluates all native non-text collar pixels
within clamp(0.12*fontPx,2,12), retaining all27 RF channels, both segmentation
posteriors, eight OCR maps and six physical interactions. Conditional candidate
means and joint masses preserve colour order, include explicit empty support,
and never clip to individual/merged boxes. Float16 payloads are promoted before
source arithmetic to reproduce the float32 replay. No new palette colours,
resampling, context expansion or crop/page-area exclusion is introduced.

`final_background_refinement.py` validates the exact102 names/version and helper
hash; policy hashes bind both helpers and all six estimator models. Legacy15
models remain numerically supported, with checkpoint policies explicitly rebound
to the current helper. Old warm correction tags are restored before recomputation.
`apply_final_background.py` authenticates original RF/seg/OCR evidence in bounded
worker processes and checks RGB/mask/feature/context/model snapshots. Workers
receive only allowlisted source metadata and predictions; style labels enter
coordinator evaluation after source processing. CLI and continuous inference use
the same helper and original aligned payloads. All other style fields remain exact.

The frozen TRAIN-only model/gate(.1/.95) and full3819 source replay improve three
TRAIN and two DEV representatives, with no worsened TRAIN/DEV colour or lost
within10 pass. Mean DeltaE TRAIN1.354887->1.347791 and DEV2.209811->2.193299.
The selected model's descriptive TEST mean slightly worsens2.081281->2.083828,
with one improved and two worsened representatives; within10 counts remain
unchanged in every split. The15 DEV colour failures remain unresolved. Six cold
CLI cases match batch results, including three background changes, retained
source outer rings and the calibrated shadow displacement. Ten focused runtime/
batch tests and the five original frozen-source compatibility tests pass.
`final-background-local-fusion-study/PROMOTION.json` records admission and limits.
The corpus is historically inspected; no unseen-page accuracy is implied.

Continuous v14 keeps v13's score weights and uses the lower actual emitted DEV
background mean to break a quality-score tie, retaining TRAIN/DEV categorical
and mean guards. The native iOS app is unchanged by these host estimators.
