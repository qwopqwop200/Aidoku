"""Pool font fits on a shared numeric weight scale, without family identities."""
from functools import lru_cache

import numpy as np
from fontTools.ttLib import TTFont


@lru_cache(maxsize=32)
def nominal_weight(path, digest):
    import hashlib
    from pathlib import Path
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest:
        raise ValueError('Reference font metadata identity differs')
    with TTFont(path, fontNumber=0, lazy=True) as face:
        return float(face['OS/2'].usWeightClass)


def weight_intervals(pairs):
    def weight(record):
        return float(record['weight']) if record.get('weight') is not None else nominal_weight(record['path'], record['SHA256'])
    result = np.asarray([[weight(pair['regular']), weight(pair['heavy'])] for pair in pairs])
    if not np.isfinite(result).all() or np.any(result[:, 1] <= result[:, 0]):
        raise ValueError('Invalid reference weight intervals')
    return result


def summarize(matrix, intervals):
    """Convert measured interpolation to400..900 before pooling families.

    This is a font-axis descriptor, not a universal perceptual bold threshold.
    TRAIN/DEV calibrates the classifier; no query labels determine the scale.
    """
    intervals = np.asarray(intervals, float)
    x = np.asarray(matrix, float).reshape(len(matrix), len(intervals), 2, 32).copy()
    valid = x[:, :, :, -1] > 0
    low = intervals[:, 0][None, :, None]
    span = (intervals[:, 1]-intervals[:, 0])[None, :, None]
    for field in (0, 9, 10, 11):
        x[:, :, :, field] = np.clip((low+span*x[:, :, :, field]-400)/500, -2, 3)
    x[~valid] = 0
    out = []
    for pool in range(2):
        for group in (np.ones(len(intervals), bool), intervals[:, 0] <= 400, intervals[:, 0] > 400):
            values = x[:, group, pool]
            fit = values[:, :, 18]
            weights = np.maximum(0, fit)**8 * valid[:, group, pool]
            denom = weights.sum(1, keepdims=True)
            mean = np.divide((values*weights[:, :, None]).sum(1), denom,
                             out=np.zeros((len(x), 32)), where=denom > 0)
            out.append(mean)
    result = np.concatenate(out, axis=1)
    if not np.isfinite(result).all():
        raise ValueError('Nonfinite pooled weight evidence')
    return result
