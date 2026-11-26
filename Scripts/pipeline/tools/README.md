# Pipeline evaluation and training tools

Code only. The GT, the fold manifest, saved translations, GT-derived caches, run outputs and the Python
environments stay outside the repository (`workspace.py`):

- `AIDOKU_WORKSPACE`: GT JSON, `CANONICAL-GROUPED-SOURCE-MANIFEST.json`, saved translations (default: the
  directory that contains this checkout)
- `AIDOKU_EVAL_DIR`: `runs/`, caches, dumps, model scratch, venvs (default: `$AIDOKU_WORKSPACE/port-eval`)

Python: the eval venv (`workspace.PYTHON`: numpy, PIL, scipy, shapely, lightgbm); the mask tools need
`workspace.MASK_PYTHON` (+ torch, cv2). Scorers print numbers only and never open images for viewing.

## Scorers (GT vs a run directory)

| tool | measures |
|---|---|
| `reclass/compare.py BASE VAR` | render items per block, gains - losses vs noise, per fold (`cmp_test.py` for test) |
| `merge_gt_eval.py RUN...` | grouping vs the reviewed merge GT: exact pages, line P/R, frag / wrong / missed |
| `lineasm/score.py PREFIX`, `bboxagent/boxscore.py PREFIX` | S2b lines and boxes vs GT line boxes |
| `convmask/mscore.py DUMP RUN_PREFIX` | S6 masks (`AIDOKU_PIPELINE_DUMP_MASKS`) vs GT glyph masks |
| `colorfix/errors.py PREFIX` | S8 fill / outline colour vs appearance GT |
| `typeset_score.py RUN...` (`--cmp BASE VAR`, `--selftest RUN`) | one score: per GT text region, (share of its text a reader gets: grouping, text kept, place, balloon, overlap, page, art, contrast) x (how well it is set: mean of size, consistency, margin, position, line breaks, style), scored on what the painter draws; page JSON + GT only (`typeset_gt.py` holds the GT caches); reads the page record's `paints` (what S10 painted each block with, after the legibility outline) when a run has it |
| `consistency_metrics.py RUN` | painted size consistency inside GT font-size classes |
| `../eval.py RUN --split S` | detection recall / precision and grouping F1 |

## Training (`retrain/<part>/train.py`, driven by `retune/retrain.py`)

Each learned part has a trainer that fits on train pages of a host run (`RUN_PREFIX_{train,dev,test}` with
`--save-stages`), writes its resource, checks it against the shipped one (`--check`) and prints its metric on train
folds and dev/test (`--eval`). `retune/retrain.py NAME` retrains them in pipeline order, making each part's input run
on the already retrained parts before it, then compares old vs retrained resources on full runs.

| part | stage | resource |
|---|---|---|
| `assembly` | S2b line joiner | `PipelineLineJoin.json` |
| `linekeep` | S3 keep gate (input run with `lineKeepScale` 0) | `PipelineLineKeep.json` |
| `linebox` | S3 line-box refinement | `PipelineLineBoxes.json` |
| `grouping` | S4 cascade + hyb rules | `PipelineGrouping.json` |
| `interior` | S4b balloon interior (`rasterdump.swift`: the app's gray raster) | `PipelineInterior.json` |
| `lineends` | S6 line-end classifier + regressor | `PipelineLineEnds.json`, `PipelineWeights.bin` slot 4 |
| `fontsize` | S8 font size | `PipelineFontSize.json` |
| `outline` | S8 outline width (`--full`: also the presence forest) | `PipelineOutlineWidth.json` |
| `fill` | S8 fill colour | `PipelineFillPeaks.json`, `PipelineWeights.bin` fill forests |

`retrain/augment.py`: training-time augmentation shared by the trainers (mix real upstream variant runs; jitter S3
boxes by the measured S3-vs-GT error). A trainer's `SPEC['augment']` is its adopted setting, which `retrain.py` passes
as `--augment` (runs it names that do not exist are dropped; `--no-augment` trains on the run alone). Keep the mixed runs
(`runs/speed2/all830`, `runs/speed2/base830`, `runs/retune/snap2/ref`) or replace them with newer upstream variants.

`colorfix/forest.py` reads and writes `PipelineWeights.bin` slots. MaskNet U-Net: `convmask/prep.py`, `train.py`,
`evalrun.py`, `convert.py`; Swift parity harness in `convmask/harness`.

## Running

- `lock.zsh`: at most two heavy jobs machine-wide (`take_slot NAME`)
- `speed/replay.zsh WT NAME [png|nopng] [splits]`, `speed/ab.zsh REF WT NAME ...`, `speed/compare.py`: same-slot
  A/B with output identity (JSON, PNG pixel stats), stage timings and peak RSS
- Stage checkpoints (Mac host only): `--save-stages` keeps S1-S4b, the S6 mask and the S7 restore per page in
  `OUTPUT/stages`; `--from-stages RUN --from s4|s5|s7|s8` reuses them and recomputes from that stage on (output
  identical). `--from s8` (S8-S10 changes) runs dev in seconds; s5/s7 stay bound by S7 inpainting
- `retune/retune.py NAME --models DIR`: re-fit the `PipelineTuning` knobs for new model versions on train folds,
  then compare old / new / fitted on dev and test. After a model or stage change, run `retune/retrain.py NAME` first
  (learned parts in pipeline order), then retune the knobs on top. `--objective typeset` decides the render knobs on
  `typeset_score.py` (a gain whose 95% interval is above 0) instead of the render items; the report lists both. The S9 layout
  knobs (`layout*`: balloon inset, cap, whole-word ratio, tall-paragraph width, family share, row-span rescue) were
  fitted on that score from saved stages (`--from s8`, a minute per train run)
