# Source font-weight inference (in progress)

The user requires exact agreement with the current corrected weight reference,
preferring a direct image algorithm and permitting ML as a fallback. The target
is **not achieved**. No candidate has been activated in the production renderer.

`pixel_rules.py` measures source-crop body strokes separately from hollow outline
rings and compares source-em-normalized widths within a page. `line_weights.py`
splits source lines from projection gaps and detects mixed thickness. It takes
no image/region IDs. On the specified mixed source crop it independently finds
three columns with 0.10/0.10/0.20 em strokes, matching regular/regular/bold.
`features.render_policy` returns regular whole-region rendering for mixed source
weight. The native host compositor now consumes `sourceFontWeight` and forces
an actual regular Core Text font for mixed input, even when `renderBold=true` is
also supplied. Actual0744 crop -> generic mixed detector -> saved translation ->
native regular rendering is verified under `case0744-source-to-render`. The full
binary classifier and iOS integration remain unverified in production.

`experiment.py` and `optimize.py` compare source-measurement classifiers, never
GT lookups at inference. Source RGB, bbox and OCR em are inputs. Optional original
OCR is reduced to pooled physical reference-glyph metrics; token identity is not
a learned feature. Page grouping only defines runtime peer batches. Identical
source images and identical crop/target pairs share a transitive split group.
TRAIN fits models, DEV selects configurations. The already observed TEST is
reported as a regression partition, not a fresh external validation.

The corrected reference has 3,833 ordinary-weight regions and one mixed region.
It still includes provisional agent-authored labels. Full 100% reference matching
would establish performance on this corpus, not universal accuracy on new books.

Use the existing `Aidoku/.venv-source-inference/bin/python`. Artifacts and precise
continuation state are in `../../../font-weight-estimation-20261111/WORK-STATE.json`.
`test_weight.py` covers body measurement, page-order invariance, duplicate split
isolation, generic mixed-line detection, and suppression of whole-region bold
for mixed source text. Inspect only crops with at most the existing 15% context.

The previous conservative candidate is `white-physical-correction`: TRAIN0
errors, DEV8 (all missed bold), observed TEST2 (all missed bold). No reference
labels were changed to achieve those numbers. Polarity augmentation and broader
source-family context have not yet beaten that incumbent on DEV. Source-only
per-page array inference is implemented in `runtime.py`; `candidate-source-runtime`
reproduces all3,833 ordinary reference-case predictions without reading query GT
or identifiers. This is parity, not proof of 100% accuracy or a fresh pixel run.

Additional measurements include paired regular/heavy fits, source-predicted fill
strokes, complete owned components within the 15% crop, and final-source-em
script-separated glyph residuals. All remain experimental until the full quality
target and real operational-path checks pass. Earlier feature versions are kept
in frozen measurement arrays; do not pass new fill measurements to a candidate
trained with legacy fill summaries without verifying its feature contract.

`source_runtime.py` measures the selected raw866 and paired48 feature contracts
directly from bounded source crops. It uses original OCR prior for raw597/direct7
and the final source-estimated em for paired regular/heavy fits. The legacy262
glyph residual is either freshly reconstructed with authenticated reference
fonts or reused from the same fresh source-font graph call in packet order.
No query GT, item-ID lookup, or measured-feature archive is read. Crops exceeding
15% context and batches mixing source pages are rejected. This is a candidate
frontend; it does not silently change the active renderer's binary classifier.

`full-reference-refit` reproduces all3,834 current labels, including the separate
qualified mixed rule, after training on all3,833 ordinary labels. That is
resubstitution, not independent validation. The frozen heldout result remains
DEV8/TEST2 errors and the accuracy goal remains unmet. Pointwise signed stroke
displacements, both alone and in a hybrid, failed to beat that incumbent.

The qualified mixed rule has been audited across all3,834 crops with zero false
mixed and zero missed mixed cases on this reference. The host producer in
`inpainting_compare/font_weight_runtime.py` is connected after fresh font-size
inference; actual OCR geometry for0744 and synthetic conflicting render flags
have been checked. These checks do not certify a full830 render or native iOS.

The newer `conservative-complementary` candidate combines the prior primary and
TRAIN-only polarity-augmented heads. Its errors are TRAIN0/DEV7/observedTEST2,
with no false bolds. The fixed union rescues one additional bold, without fitting
another threshold or consulting query labels. All3,834 predictions have been
verified from fresh bounded source-crop measurements. `runtime.py` exposes
`predict_complementary_page`; `source_runtime.infer_page` dispatches bundles
marked `sourceComplementaryHeads`. The polarity head needs explicit legacy
fill-v1 measurements: `fill_body.measure(..., version=1)`. Default fill-v2 retains
complete owned bodies and is unchanged. Do not interchange equal-width schemas.

Expanded same-family regular/heavy matching (`native_pairs.py`) and TRAIN-only
font-rendering augmentation have been measured, but do not improve quality on
their own. A broader head consensus reduces DEV errors to5 but introduces a
new false bold in the observed regression partition; it is not promoted.
Source-group out-of-fold confidence calibration is explored separately. Binary
classification remains staged until the requested quality/integration gates
are met; the current operational host hook enables mixed protection only.

The five-fold source-group OOF calibrator completed with all2,284x4 confidence
values finite and no image/augmentation relatives crossing folds. Its new heads
tie0/7/2 and are rejected. Additional BIZ regular/heavy32 and previously unused
regular/handwriting-fit130, heavy-fit66 and paint-area40 source-font signals also
tie the incumbent. Keep the small OOF cache; do not repeat these completed
studies unchanged. The next missing evidence is coherent glyph/word alignment,
not another confidence-only threshold search.

The current staged candidate is `differential-complementary`: TRAIN0/DEV4/
observedTEST2 errors, with zero false bolds and six missed bolds. It combines
the complementary heads with differential-stem evidence. `affine_pairs.py`
selects shared pose using the stronger regular/heavy fit and a second visible
glyph witness. `weight_bands.py` isolates added stems and contracted counters
from shared glyph shape, using 700/900 reference intervals. Source-head agreement
needs physical band confirmation; a separately TRAIN-fitted stem head rescues
another missing bold. No page/word identity or query weight lookup is used.

`runtime.predict_band_page` consumes raw866, legacy fill71, physical paired48,
source styles/mixed flags and differential112. `source_runtime.infer_page` runs
the actual image frontend for bundles marked `sourceBandHeads`. The complete
frontend was executed on all3,834 crops: zero class disagreements and exactly
equal primary/polarity/stem scores versus the offline array adapter. Source
style/em were saved upstream predictions; geometry was frozen and OCR was not
rerun. The one mixed case remains regular in translation rendering. Evidence:
`../../../font-weight-estimation-20261111/differential-complementary/FRESH-VERIFICATION.json`.

Broad400/heavy bands, two-interval bands and explicit observed/unknown-pixel
bands do not improve0/4/2 and are not promoted. Explicit observation tests show
why a palette-rejected pixel is not a known background pixel, but corrected
stem estimates alone did not fix the remaining six. The binary model is still
staged; full-reference accuracy100% and operational iOS integration are unmet.

`word_pairs.py` fits whole ordered OCR lines instead of independently searching
for each glyph anywhere in the crop. Both reference weights share advances and
pose. `word_source_members.py` binds original line OCR by authenticated source
hash and polygon overlap; detector-array indices from unrelated stages are not
interchangeable. OCR strings render physical references and are not token
identity features. The original whole-word576 corpus and both tree/smooth-head
studies tie the incumbent0/4/2 and are not promoted.

`masked_word_pairs.py` uses original line geometry and source-estimated em as
scale candidates when only part of a word is visible. Correlation and differential
bands ignore unobserved pixels and require observed reference foreground support.
Synthetic tests retain scale and character order when half the text is occluded.
Do not interpret improved registration scores as proven weight classification.

`palette_word_pairs.py` additionally considers distinct colours from the source
predictor's fill palette. A colour cannot serve simultaneously as predicted fill
and known negative background. This recovers recoloured visible strokes under
translucent overlays without reading appearance GT. `measure_palette_words.py`
remeasures only rows with fill colours separated by more than35 RGB units and
reuses frozen masked-word measurements elsewhere. Source manifests, palette/em
predictions, reference fonts and implementation hashes bind the patch archive.
`--combine-only` publishes a complete feature matrix once the baseline finishes.

`study_word_heads.py` fits smooth classifiers on TRAIN only and selects thresholds
on DEV, then reports the previously observed TEST regression partition. Source
palette/word studies remain experimental until genuine accuracy improvement and
fresh pixel-frontend/runtime verification establish the requested full target.

Masked and palette whole-word corpus measurements subsequently completed. Both
tree and smooth heads, including font-family-invariant numeric weight pooling,
still tie0/4/2 and are rejected. Better image registration alone did not produce
better classification. Their small frozen feature arrays remain reusable.

`source_vision.py` now explores a frozen pretrained image-only ViT encoder
(`facebook/dinov2-small`, pinned commit). It receives no OCR strings or source
IDs, and performs local inference on paired RGB/predicted-fill glyph
neighbourhoods. At most six geometry-sampled neighbourhoods are extracted from
each already bounded crop, and the15% parent context limit is enforced. Source
images are not uploaded. `measure_source_vision.py` binds pixels, predicted
styles/em/masks and implementation hashes and saves resumable prefix checkpoints.
The encoder is frozen; separate TRAIN-only weight heads and DEV-selected
thresholds must establish whether these new descriptors actually improve the
staged incumbent. No production activation or accuracy claim follows from
successful feature extraction.

The complete3834-row frozen-ViT extraction finished locally in419.1seconds.
Tree, smooth and TRAIN-only cosine-prototype classifiers did not improve0/4/2.
1280 same-content font-metadata renderings (640 per class) were encoded with the
same source frontend. Adding their prototypes introduced one observed-TEST false
bold and is rejected. A learned normal-to-heavy direction from512 matched
family/text/layout/appearance pairs also ties0/4/2. These are negative findings,
not deployed improvements. Direct typography adaptation of the encoder is the
next untested hypothesis; do not rerun these frozen-descriptor sweeps unchanged.

`study_native_pairs.py` now retains generic source-feature metadata and permits
image descriptors without a font-pair manifest. Its first image-tree study wrote
valid unchanged-quality metrics but failed serializing a font-only metadata key;
the empty candidate was removed, the assumption fixed, and that rejected model
was not wastefully refit. All published image/word decision scores are finite.
Explicit dot-product comparison agrees with accelerated BLAS within4e-15 despite
the platform's spurious floating-point-status warnings; see source-vision
`NUMERICS.json`. No new binary classifier has been activated.
