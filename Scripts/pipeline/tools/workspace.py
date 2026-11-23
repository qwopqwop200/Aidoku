"""Paths shared by the pipeline evaluation and training tools (Scripts/pipeline/tools).

Only code lives in the repository. Datasets, GT-derived caches, run outputs and the Python environments stay
outside it:
  AIDOKU_WORKSPACE  directory holding the GT JSON, the fold manifest and saved translations
                    (default: the directory that contains this Aidoku checkout)
  AIDOKU_EVAL_DIR   working directory for runs/, caches, dumps, trained-model scratch and venvs
                    (default: WORKSPACE/port-eval)
Every tool imports this module (`sys.path.insert(0, <tools dir>)`; `from workspace import ...`).
"""
import os
from pathlib import Path

TOOLS = Path(__file__).resolve().parent
REPO = TOOLS.parents[2]
WORKSPACE = Path(os.environ.get('AIDOKU_WORKSPACE', REPO.parent))
EVAL = Path(os.environ.get('AIDOKU_EVAL_DIR', WORKSPACE / 'port-eval'))
RUNS = EVAL / 'runs'
GT = WORKSPACE / 'aidoku-unified-gt-20261116.json'
SIZE_CLUSTERS = WORKSPACE / 'review-source-size-clusters830-20261112/algorithm-cv/predicted-clusters830.json'
MANIFEST = WORKSPACE / 'pipeline-generalization-20261117/evaluation-audit/CANONICAL-GROUPED-SOURCE-MANIFEST.json'
REPLAY = WORKSPACE / 'release-830-live-20261119/full-d'
WEIGHTS = REPO / 'Aidoku/Resources/Translation/PipelineWeights.bin'
PYTHON = EVAL / 'langprobe/.venv/bin/python'        # numpy, PIL, scipy, shapely, lightgbm
MASK_PYTHON = EVAL / 'convmask/.venv/bin/python'    # + torch, cv2


def data(*parts):
    """A path under EVAL (data a tool keeps between runs), parent directories created."""
    p = EVAL.joinpath(*parts)
    p.parent.mkdir(parents=True, exist_ok=True)
    return p
