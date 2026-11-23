# Sourced by the shell tools: the same paths as workspace.py.
TOOLS=${${(%):-%x}:a:h}
REPO=${TOOLS:h:h:h}
WORKSPACE=${AIDOKU_WORKSPACE:-${REPO:h}}
EVAL=${AIDOKU_EVAL_DIR:-$WORKSPACE/port-eval}
MANIFEST=$WORKSPACE/pipeline-generalization-20261117/evaluation-audit/CANONICAL-GROUPED-SOURCE-MANIFEST.json
REPLAY=$WORKSPACE/release-830-live-20261119/full-d
PYTHON=$EVAL/langprobe/.venv/bin/python
