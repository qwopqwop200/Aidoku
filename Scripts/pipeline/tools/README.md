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
| `convmask/mscore.py DUMP` | S6 masks (`AIDOKU_PIPELINE_DUMP_MASKS`) vs GT glyph masks |
| `colorfix/errors.py PREFIX` | S8 fill / outline colour vs appearance GT |
| `consistency_metrics.py RUN` | painted size consistency inside GT font-size classes |
| `../eval.py RUN --split S` | detection recall / precision and grouping F1 |

## Training (writes `Aidoku/Resources/Translation/PipelineWeights.bin` or the MaskNet package)

- S8 fill / outline forests: `colorfix/train_fill_lgb.py`, `train_peaks.py`, `train_outline.py`, `export_fill.py`
- font-size correction forest: `colorfix/train_font.py`
- line-end regressor: `bboxagent/learn.py`, `fit.py`, `export.py`
- MaskNet U-Net: `convmask/prep.py`, `train.py`, `evalrun.py`, `convert.py`; Swift parity harness in `convmask/harness`

These read Swift-side feature dumps under `$AIDOKU_EVAL_DIR/runs/imp/...`.

## Running

- `lock.zsh`: at most two heavy jobs machine-wide (`take_slot NAME`)
- `speed/replay.zsh WT NAME [png|nopng] [splits]`, `speed/ab.zsh REF WT NAME ...`, `speed/compare.py`: same-slot
  A/B with output identity (JSON, PNG pixel stats), stage timings and peak RSS
- `retune/retune.py NAME --models DIR`: re-fit the `PipelineTuning` knobs for new model versions on train folds,
  then compare old / new / fitted on dev and test
