"""LightGBM trees in the PipelineWeights.bin forest layout (written by retrain/fill and retrain/lineends), their Swift-style evaluation, and
appending one forest to the weights file."""
import struct
import numpy as np


def flatten(booster):
    """-> (roots, feature, threshold, left, right, value); leaves have left = right = -1."""
    roots, feat, thr, left, right, val = [], [], [], [], [], []
    def add(node):
        i = len(feat); feat.append(0); thr.append(0.0); left.append(-1); right.append(-1); val.append(0.0)
        if 'leaf_value' in node:
            val[i] = node['leaf_value']
        else:
            assert node['decision_type'] == '<='
            feat[i] = node['split_feature']; thr[i] = node['threshold']
            left[i] = add(node['left_child']); right[i] = add(node['right_child'])
        return i
    for t in booster.dump_model()['tree_info']:
        roots.append(add(t['tree_structure']))
    return roots, feat, thr, left, right, val


def logit(forest, x):
    """Sum of leaf values, comparing float32 features like PipelineWeights.swift."""
    roots, feat, thr, left, right, val = forest
    z = 0.0
    for n in roots:
        while left[n] >= 0:
            n = left[n] if float(np.float32(x[feat[n]])) <= thr[n] else right[n]
        z += val[n]
    return z


def write(path, keep, forest):
    """Rewrite the weights file as its two stage tables + the first `keep` forests + `forest` (any later ones dropped)."""
    data = open(path, 'rb').read(); off = 0
    for fmt in ['f', 'f'] + ['d', 'i', 'h', 'd', 'i', 'i', 'd'] * keep:
        off += 4 + struct.unpack_from('<I', data, off)[0] * struct.calcsize(fmt)
    tables = zip('dihdiid', ([0.0, 1.0],) + tuple(forest))
    tail = b''.join(struct.pack('<I', len(xs)) + struct.pack('<' + fmt * len(xs), *xs) for fmt, xs in tables)
    open(path, 'wb').write(data[:off] + tail)
