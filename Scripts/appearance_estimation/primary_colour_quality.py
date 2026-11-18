"""Score actual emitted primary colours, separately from palette cardinality."""
import numpy as np
from source_appearance import lab
from paint_palette_metrics import targets

VERSION = 'emitted-primary-colour-mean-nonregression-v1'


def measure(rows, predictions, group_of):
    """TRAIN/DEV only; metadata callback decides split before GT extraction."""
    if len(rows) != len(predictions):
        raise ValueError('Primary colour correspondence length changed')
    errors = {'train': [], 'dev': []}
    for row, prediction in zip(rows, predictions):
        if row['itemID'] != prediction['itemID']:
            raise ValueError('Primary colour output correspondence changed')
        group = group_of(row)
        if group not in errors:
            continue
        colour = prediction['fill']['rgb']
        error = float(np.linalg.norm(lab(targets(row))-lab([colour])[0],axis=1).min())
        if not np.isfinite(error):
            raise ValueError('Nonfinite primary colour error')
        errors[group].append(error)
    if any(not values for values in errors.values()):
        raise ValueError('Primary mean guard requires TRAIN and DEV')
    return {group: dict(n=len(values), within10=float(np.mean(np.asarray(values)<=10)),
                        meanDeltaE=float(np.mean(values)))
            for group, values in errors.items()}


def preserves(before, after):
    return all(after[g]['n'] == before[g]['n']
               and after[g]['within10'] >= before[g]['within10']
               and after[g]['meanDeltaE'] <= before[g]['meanDeltaE'] + 1e-12
               for g in ('train','dev'))


def strictly_improves(before, after):
    return preserves(before, after) and after['dev']['meanDeltaE'] < before['dev']['meanDeltaE'] - 1e-9
