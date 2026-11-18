"""Select an authenticated operational font model; no research selection here."""
import hashlib
import json
from pathlib import Path

from split_artifact import read_bytes


def resolve_active_model(selection):
    selection=Path(selection)
    record=json.loads(selection.read_text())
    model=Path(record['model'])
    if not model.is_absolute():model=(selection.parent/model).resolve()
    expected=record.get('modelSHA256')
    if expected and hashlib.sha256(read_bytes(model)).hexdigest()!=expected:
        raise ValueError('Active font model identity differs from selected production artifact')
    return model


def resolve_default_model():
    """Use the packaged selection even after historical experiments are removed."""
    return resolve_active_model(Path(__file__).with_name('ACTIVE-ESTIMATOR.json'))
