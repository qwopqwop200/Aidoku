# Source font-size estimator

The macOS host and iOS Reader load the bundled native estimator during normal
image translation. The Python reference backend and the native-model exporter
also use the artifact selected by `ACTIVE-ESTIMATOR.json`. It is stored as
ordered `model.pkl.gz.part-NN` chunks (GitHub's 100 MB blob limit; this fork
cannot host LFS objects). `split_artifact.read_bytes` concatenates them and
`modelSHA256` is checked on the joined bytes.

The accepted `accepted-font198-v1` graph computes source measurements, actual
base56 and pair61 model predictions, all accepted early/late corrections,
source-style calibration and cohort repair. It reads no query GT or saved
prediction/cohort table. Superseded and rejected experiments are excluded.

The operational graph uses the same full frozen point56 model for every query;
it never substitutes TRAIN OOF values. Verified from all 3,834 measured source
inputs, TRAIN clusters match428/428 pages and DEV153/153, with DEV point mean
relative error1.440813%. TEST remains149/150 exact pages with7 false pairs.
Fresh RGB/mask/style/member-geometry packets also execute through the old Main
entrypoint and CLI with exact output agreement. See
`main-optimization-integration-20261111/packaged-font/` and
`font-fresh-member-bridge/VERIFICATION.json` for scope and immutable model pins.

The reference bank, trained heads, public fonts and OFL notices are packaged;
macOS pinned system fonts remain system dependencies. The production Python
runtime is `Aidoku/.venv-source-inference`. The previous experiment-env location
is a compatibility symlink, not the operating dependency location. iOS18+ now
executes the full native OpenCV/FreeType/frozen-head graph through the default
reader backend. App-hosted iOS26.5 simulator tests recompute segmentation,
appearance and font from a bounded source crop; all8 affected checks pass.
Physical-device execution is not part of this verification. Host estimation
and translated-text layout fitting remain separate measurements.

The **round198 research extension** adds source-cohort repair after round196.
It reaches exact clustering on TRAIN 428/428 and DEV 153/153 pages, with
DEV mean relative point error 1.440813%. Historical TEST outputs are bitwise
unchanged from round196 (149/150 exact pages; 7 false same-size pairs). The
source-only `cohort_repair.py` requires matching measured font family, a complete
physical scale span <=1.25, mean source-pair affinity >=.95 and predicted size
span <=2. It preserves whole existing cohorts and rejects incidental rounding
collisions. No page IDs or query GT values enter the algorithm. Fifty policies
were compared on TRAIN/DEV; same-source/crop split separation is checked in
`round198/INDEPENDENT-EVALUATION.json`. Source-array replay matches all 3,834
saved outputs exactly. This accepted ancestry is now included in the operating
accepted198 bundle; these corpus metrics do not establish unseen-book accuracy.

The selected **round196 research** refinement searches 9,720 calibration settings
against the repeatedly used DEV set, with TRAIN mean-error nonregression. Its
mean point relative error is 1.440813% on 762 DEV boxes (153/153 exact-cluster
pages), and 2.711163% on 825 historical TEST boxes (149/150 exact-cluster pages;
7 false same-size pairs). TEST is an observed regression benchmark, not a fresh
holdout. These metrics are saved-prediction measurements, **not active native
runtime accuracy**. The accepted ancestry is now consolidated into the runtime
bundle described above. GT labels remain unchanged.

`style_calibration.py` extracts the last-stage calibration as a pure array-based
function: TRAIN-only reference ratios, source exclusion/diversity, measured-em
and PCA-style distances, shared cohort updates and collision-safe rounding. It
accepts no query GT, performs no file lookup and imports no experiment modules.
It requires source measurements and the correct preceding cohort/prediction
stage; applying it to round48 alone does not reproduce round196. Input hashes
and selected parameters are in `round196/INPUT-MANIFEST.json`. The round197
additional-merge experiment is rejected because historical TEST false pairs
increase from 7 to 12, despite matching all TRAIN and DEV groups.

Estimates nominal main-glyph em in original source pixels from a native bbox crop,
prior OCR em and geometry. Dark/light/contrast connected components and projection
autocorrelation provided the original 45 scalar features. The v2 base model
uses 96 measurements, adding native component occupancy, cell-center gaps and
interior distance summaries. A v3 experiment adds 36 broad-period measurements;
these did not beat the v2 incumbent on DEV and are not used at runtime.
The active v4 extractor adds 60 color-separated core summaries. The frozen
base still receives exactly its original 96 features; the context head receives
156 source summaries plus 15 peer summaries. Five fixed dark/pale/chroma masks
separate possible glyph bodies from colored halos and edge-connected background.
These are observable source measurements, not GT masks or per-page rules.
The base/context regressors consume no OCR transcript or learned token identity.
The optional physical stage rasterizes original OCR glyphs as reference shapes,
never the translated output. No image identifier, GT value, GT confidence,
reviewer interval or GT font cohort is a learned or physical inference feature.
No CNN is added. Same-source predicted scales are optionally harmonized with
complete-link maximum/minimum <=1.12; distinct emphasis sizes remain separate.

`optimize.py` fits TRAIN only and compares configurations on DEV. `--incumbent`
retains a stronger previous checkpoint when new candidates do not improve DEV.
Correction bounds may widen using TRAIN target range only, so a grossly wrong
OCR prior is not permanently locked to the old fixed +/-0.85 log correction.
Connected
components of identical source OR crop hashes share a partition, including
transitive duplicate links. TEST is evaluated after DEV selection, never used to
fit or choose a configuration. Subsequent rounds explicitly record that this
historical TEST has already been observed; it is a regression check rather than
a fresh external validation. Approximate agent-authored GT and repeated corpus
use limit any claim about new books or exact font-family em accuracy.

`predict.py --model MODEL --manifest MANIFEST --out OUTPUT` accepts `items` with
`crop`, `bboxInCrop`, `priorReferenceFontPx`, `sourceImageSHA256` and transport-only
`itemID`. Optional `page` separates independent page packets of identical source
bytes; it defines batch membership, never a numeric model feature. It does not
read GT labels. `model.pkl` is a trusted local pickle: never
load one supplied by an untrusted source. Inference needs the existing NumPy,
OpenCV, Pillow and scikit-learn environment.
Physical evidence additionally uses fontTools and the recorded system fonts.
Extended source-only manifests accept `sourceOCR` (packet path/hash), `regionID`,
`predictedMask` (predicted-only flag, source/mask hashes and dimensions),
`cropSHA256`, `cropBounds` and `pageSize`; OCR strings need not be duplicated.
`--jobs 4` measures independent crops in parallel. Missing evidence is supported
by the same model; malformed or mismatched identities are rejected.

The host text-render preparation path selects the active estimator in
`font-size-estimation-20261110/ACTIVE-ESTIMATOR.json`, or an explicit
`--font-size-model`. Source geometry and output resolution stay unchanged;
`FONT-SIZE-ESTIMATES.json` records the old and estimated references. Existing
rendered images and all historical GT are preserved. This host connection does
not implement or certify native iOS font-size estimation.

The context head adds 15 peer-scale summaries to the 96 native measurements.
`optimize_context.py` trains it on 5-fold out-of-fold TRAIN predictions grouped
by transitive source/crop identity. Each held-out TRAIN row is predicted by a
base model that never fitted that row or its duplicates; correction bounds are
derived from that fold's fit subset. DEV selects correction strength, cap and
final harmonization. No GT page cohort, interval or confidence enters inference.
The round-4 head applied half-strength corrections, capped at 0.15 log units,
then harmonized predicted scales within 1.06. The active round-7 color head uses
0.75 strength and a final 1.12 complete-link ratio; distinct emphasis remains
separate. Singleton packets retain zero peer summaries. Sorting tie-breaks are
deterministic, with tests for permutation and cross-page independence.

`audit_runtime.py` evaluates the actual source-image bridge over every retained
bbox without visually displaying a page. The round-4 audit covers 830 pages /
3834 bboxes and finds zero numerical mismatches above 1e-8 pixels relative to
saved crop inference. This validates source em inference, not final translated
text fitting or native iOS behavior.

Rounds 5--8 tested scale augmentation, color-based base replacement, a
color-conditioned context head and a guarded global head mixture. Only the
color-conditioned context head was promoted. Scale and context mixture branches
are experimental and absent from the active model. Experiments use DEV for
selection and explicitly document the already-observed historical TEST.
The selected head slightly lowers DEV +/-10% coverage (95.67% to 94.88%) while
lowering mean DEV error and keeping DEV +/-20% coverage. Historical TEST mean
error, +/-10% coverage and GT-interval coverage improve. Actual resized DEV
mean error and scale drift also improve slightly. These mixed results are
recorded rather than described as every metric improving.

Rounds 9--12 tested four additional families without changing the active model:
common-size consensus (median, mean, geometric and trimmed geometric means),
oriented component/nearest-body measurements, numeric OCR confidence, and
TRAIN-only relative-loss weighting. None lowered DEV mean relative error, so
all were rejected. V5's 40 oriented measurements are experimental and are not
extracted by the active v4 model. Synthetic rotated-body controls and exact
prefix tests cover the new measurements without claiming corpus accuracy gains.

`measure_features.py` builds only native measurement caches, without launching
unnecessary base-model searches. `optimize_context.py --oof-cache` validates GT,
base model hashes, train indices and duplicate-component separation before
reusing existing TRAIN OOF forecasts. `--coverage-reference` can require recovery
of an earlier DEV +/-10% rate; `--relative-loss-power` uses TRAIN target ratios
as bounded sample weights, not runtime GT. The generic base search now forwards
the incumbent context feature count rather than assuming the old 96-feature
head contract.

The active checkpoint remains round 7. The rounds9--12 research receipt is
round12/RESEARCH-COMPLETION.json; rejected study model copies were deleted after
confirming all saved predictions match the retained incumbent. Reports, source
signals, feature caches and cross-fit integrity receipts remain available.

Rounds 13--21 studied frozen predicted ownership masks at both the correction
and base stages, technical OCR character statistics, TRAIN-only source/crop
resampling, linear/robust log regressors, and sparse-source peer rules. None
produced a validated accuracy improvement, and none is active. Predicted-mask
provenance asserts `GTMaskUsed:false`; no GT mask pixels were opened. Mask
support exists for 3826/3834 boxes; 3793 boxes have complete page-level support.
The offline masked features neutralize non-owned RGB numerically, never write
altered images, and preserve the original 156 features exactly.

One sparse-peer study was falsely selected by a 6.94e-18 DEV mean difference.
`is_improved` and `score_better` now ignore absolute <=1e-12 / relative <=1e-10
differences, retaining coverage tie-breaks when those represent actual counts.
Identity peer corrections preserve original float values, and non-finite metric
inputs/correction trials are rejected. The numerical control rerun selects the
incumbent. A separate Ridge probe produced finite values matching `einsum` to
1.32e-16 despite BLAS floating warnings; this does not establish the warning's
backend cause or certify every possible linear fit.

The current receipt is `round21/RESEARCH-COMPLETION.json`. It records 29 focused
checks, fast host checks, all3834 fresh crop CLI comparisons, rejected-model
cleanup and unchanged GT/model hashes. Additional source modalities and sparse
peer policies remain studies; the active model still needs no OCR strings or
prediction masks at runtime. The repeated-improvement goal remains active.

Rounds 22--26 tested source-witness consensus guards, TRAIN-derived witness
uncertainty bounds, raw-output blends, and refitted raw-aware context heads.
Across 170 comparison records including controls, none qualified for promotion.
The DEV-selected round23 witness guard regressed historical TEST and was rejected;
rounds22,25,26 retained the incumbent. Raw TRAIN OOF forecasts were reconstructed
with zero source-component overlap and reproduced the previous normalized OOF
cache within 1e-10. Optional witness/raw-context flags remain inactive.

Round24 repeated inference and tiny source-value perturbations showed no output
changes above 1e-8px. An initial suspicion of instability came from comparing
different checkpoints and was corrected; no quantization fix was introduced.
Consensus now preserves fractional medians for integer callers. Regression tests
cover raw-output/context separation, displacement feature contracts, witness
ordering and valid rejoining. All34 focused checks and fast host checks passed.
Fresh inference from all3834 source crops agrees with round7 within 1e-8px.
See `round26/RESEARCH-COMPLETION.json` for hashes, metrics and cleanup receipts.
Rejected model copies were retired; GT, active/fallback models and reports remain.

Round27 added144 source-only multi-scale grouping measurements: dark/pale body
masks, three short-gap scales, and horizontal/vertical/square closing. Padding
preserves bbox-edge strokes; odd kernels avoid translation. Nearby detached
strokes can form a body while widely separated glyphs remain separate. Its
144 new candidates did not improve DEV mean error; the active feature contract
remains156 native measurements, without this extra extraction at runtime.

Round28 tested a separate residual correction after the complete active pipeline.
Five outer source-component folds each contain five inner folds, so the context
head and base used to predict an outer item never fit that item's labels or
duplicate images. The193 comparisons including the control selected a
morphology-based residual on DEV (mean3.4406% to3.4046%, +/-10%94.88% to95.80%).
It regressed historical TEST (mean3.4197% to3.5985%, +/-10%94.67% to94.06%), so
it was rejected without test-driven reselection. Its model file was retired;
the small measurement/OOF caches, predictions and cross-fit lineage remain.
All39 focused checks and the fast host checks pass. Active inference was not
modified. The evidence receipt is `round28/RESEARCH-COMPLETION.json`.

Rounds29--31 studied physical reference fonts rather than additional generic
pixel statistics. Four macOS Japanese reference faces supply pooled glyph-body
dimensions and source-body/expected-body ratios (146 scalars). Source OCR is
bound to the exact original-image SHA for all3834 items. Raw text and glyph IDs
are never learned features. Font files and face indices are recorded by hash;
these remain offline macOS studies, not a portable runtime dependency.

Source template matching evaluates up to two main-body glyphs per bbox against
dark/pale masks at eight physical em scales, retaining66 size/confidence scalars.
Only the authorized crop target is processed; native source/output images are
unchanged. A synthetic glyph control recovers the known0.85 scale, but this does
not establish accuracy for unknown fonts. Actual source matching is available
for3827/3834 items; missing evidence preserves incumbent output.

The146-font-metric and212-combined-signal heads did not improve DEV. A separate
score-weighted physical-template blend gained slightly on DEV but regressed
historical TEST mean error and +/-20% coverage, so it too was rejected. Across
339 comparison records including controls, no model was promoted. All45 focused
checks and fast host checks pass. A deterministic duplicate combined cache was
retired with its input order/hash receipt; original measurements remain intact.
See `round31/RESEARCH-COMPLETION.json` for results and source lineage.

A DEV-only diagnostic shows selecting even the oracle best single coarse grid
size has3.8915% mean error, versus the active3.4406%. This is a quantization
limitation of that raw physical expert, not a bound on a learned estimator or
ensemble. Continuous/local scale refinement is an untested next hypothesis;
no claimed improvement follows from this diagnostic alone.

Round32 implemented local physical scale refinement (`measure_templates.py
--refine`). After the coarse match, nine nearby scale factors are evaluated
within0.1 of the coarse factor, restricted to the same glyph neighbourhood.
Exact raster-score plateaus use their geometric centre instead of the largest
tied size. The synthetic off-grid0.925 control improves from the coarse1.0
estimate/NCC0.702 to0.925/NCC0.964. Locality and plateau controls are covered.

Across the same760 eligible DEV items, the raw physical expert's mean error
falls from9.3452% to7.7593%, and +/-10% rises from76.32% to83.55%. This is a
component improvement, not a gain for the retained final estimator. Joint
DEV-only selection among144 learned candidates and48 physical blends chose
a refined blend. Its historical TEST error regressed3.4197% to3.4337%, and
+/-20% dropped one item, so it was rejected without test-driven reselection.
The active round7 model and GT remain unchanged. All47 focused checks and fast
host checks pass. Refined measurements remain small offline caches; rejected
parameters and a duplicate concatenation cache were retired with receipts.
See `round32/RESEARCH-COMPLETION.json` for exact provenance and metrics.

Round33 tested width/rotation freedom (`--refine --affine`). Joint width/scale
search avoids a coordinate-descent trap demonstrated by a compressed synthetic
glyph: expected em factor0.925, uniform estimate0.825, affine estimate0.9275.
Width transforms preserve vertical em; rotation uses an expanded canvas to avoid
clipping. The optional physical blend now also studies agreement between two
source glyphs, since multiple reference fonts can share one false radical match.

Real-source results contradicted the synthetic gain. On the same760 DEV items,
raw mean NCC rose0.7840 to0.8033, but font-size error worsened7.7593% to9.1364%.
The241 joint comparisons selected a DEV blend that then regressed historical
TEST mean error3.4197% to3.4511% and lost one +/-20% item. Neither affine matching
nor the blend is active. This establishes a limitation of raw contour agreement
as nominal-em evidence, not proof that more shape flexibility improves sizing.
All50 focused checks and fast host checks pass; GT/active/fallback models remain
unchanged. Rejected parameters and a duplicate combined cache were retired.
The full evidence is `round33/RESEARCH-COMPLETION.json`.

Round34 restricted physical matching to frozen source-predicted glyph masks.
Otsu uses only owned pixels, and unowned RGB is neutralized in a temporary array
before area resizing. Unrelated outside-mask pixels therefore cannot affect
the result even after downsampling. No GT mask pixels are opened. On760 common
DEV items, raw physical error falls7.7593% to7.5011%. The per-box candidate still
regressed TEST mean, so it was rejected.

Round35 pooled concordant physical evidence from at least two source bboxes in
the same predicted-size cohort (complete-link1.02), without GT cohort labels.
Missing-mask/text items retain their prior outputs.33 DEV comparisons selected
the policy; historical TEST mean improves3.4196824% to3.4182976%, with unchanged
+/-10% and +/-20% coverage. DEV mean also improves slightly; fitted TRAIN mean
increases slightly. The effect is tiny, not evidence of statistical significance
or unseen-book accuracy. The physical stage adds compute and depends on the
recorded OCR/mask/font evidence; absent evidence uses the retained round7 result.

The verified policy is packaged in `round35/model.pkl` and selected by
`ACTIVE-ESTIMATOR.json`. `physical_consensus.py` contains inference-only rules;
training tools are not imported by that runtime stage. The render bridge accepts
original OCR separately from translated text and validates source/mask identities.
All59 focused checks and fast host checks pass. Fresh crop CLI inference covers
3834 items; actual source-image bridge inference covers830 pages/3834 items.
Both agree with the selected study within1.43e-14px, with no differences above
1e-8px. GT and prior/fallback models remain intact. Existing renders and native
iOS were not regenerated or validated. Exact receipts, dependency hashes and
limitations are in `round35/COMPLETION.json`.

The final runtime optimization is round36. The base/context estimate is computed
first; the same complete-link predicted-size cohorts then determine whether two
possible source witnesses can exist. Impossible cohorts skip physical matching.
Every member of a possible cohort remains eligible for measurement, including
short-text members that may receive the common correction. No score threshold,
font estimate, GT label or selected policy was changed. This eliminates183 of
3834 requested physical measurements (4.77%) on the retained corpus, with exact
cached-output parity. The host bridge and crop CLI use the same plan. This is a
reduction in requested comparisons, not a measured wall-clock speedup claim.
The user ended that repeated-improvement goal after this optimization; its final checks
and active model hashes are recorded in `round36/COMPLETION.json`.

The subsequent explicit clustering request produced round37. A shared source
cohort is now finalized together after physical corrections; a missing mask on
one member cannot leave it at the old size while its peers receive the new one.
The common representative is selected before rounding to original-pixel units,
so a rounding boundary cannot split the cohort. This stage also runs without
physical evidence. Internal baseline computation explicitly skips finalization,
which prevents an early snap from changing the physical measurement plan.

Broad similarity snapping increased wrong-size pairs and was rejected. A
source-pair tree classifier, trained with nested OOF base predictions, added no
clustering benefit and was retired. Rejected experiment code is kept only in
round37, outside the runtime modules. GT cohorts/values are never runtime inputs.
The selected deterministic stage reproduces all3834 cached source predictions
exactly.63 focused tests and fast host checks pass. Historical TEST mean error
changes3.4183% to3.4054%, with unchanged +/-10% and +/-20% coverage.17 approximate
GT same-size groups still have multiple inferred sizes; this is not a claim of
perfect true-group recovery. The guarantee is exact equality inside each inferred
shared cohort. It standardizes source fontReference; native translated-text fit
may still choose another rendered point size. No image rerender was requested.
See `round37/COMPLETION.json`.
