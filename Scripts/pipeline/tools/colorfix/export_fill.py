"""Fit the chosen LightGBM ranker on TRAIN folds and write it as fillPass2 into PipelineWeights.bin.
Layout (PipelineWeights.swift): stage1 f32[], stage2 f32[], then 3 forests (fillPass1, fillPass2, outline), each:
scalars f64[base, rate], roots i32[], feature i16[], threshold f64[], left i32[], right i32[], value f64[];
every table is a u32 count followed by little-endian elements."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import EVAL, WEIGHTS  # noqa: E402
import pickle, struct, sys, shutil
import numpy as np
import train_fill_lgb as L
BIN = str(WEIGHTS)
obj, hp = pickle.load(open(EVAL / 'colorfix/fill_lgb_best.pkl', 'rb'))
model = L.fit(L.TRAIN, obj, **hp)


def flatten(booster):
    roots, feat, thr, left, right, val = [], [], [], [], [], []
    def add(node):
        i = len(feat); feat.append(0); thr.append(0.0); left.append(-1); right.append(-1); val.append(0.0)
        if 'leaf_value' in node:
            val[i] = node['leaf_value']
        else:
            assert node['decision_type'] == '<=' and not node.get('missing_type') in ('NaN',) or True
            feat[i] = node['split_feature']; thr[i] = node['threshold']
            left[i] = add(node['left_child']); right[i] = add(node['right_child'])
        return i
    for t in booster.dump_model()['tree_info']:
        roots.append(add(t['tree_structure']))
    return roots, feat, thr, left, right, val


roots, feat, thr, left, right, val = flatten(model.booster_)


def logit(x):
    z = 0.0
    for r in roots:
        n = r
        while left[n] >= 0:
            n = left[n] if float(np.float32(x[feat[n]])) <= thr[n] else right[n]
        z += val[n]
    return z


# parity with LightGBM on every dumped candidate
diff = 0.0
for f, k, X, cores, gt, _ in L.rows:
    ref = model.predict(X)
    for x, r in zip(X, ref): diff = max(diff, abs(logit(x) - r))
print('trees', len(roots), 'nodes', len(feat), 'max |diff|', diff)

data = open(BIN, 'rb').read(); off = 0; tables = []
def read(fmt):
    global off
    n = struct.unpack_from('<I', data, off)[0]; size = struct.calcsize(fmt)
    raw = data[off: off + 4 + n * size]; off += 4 + n * size; return raw
order = ['f', 'f'] + ['d', 'i', 'h', 'd', 'i', 'i', 'd'] * 3
chunks = [read(c) for c in order]
assert off == len(data)
def pack(fmt, xs): return struct.pack('<I', len(xs)) + struct.pack('<' + fmt * len(xs), *xs)
new = [pack('d', [0.0, 1.0]), pack('i', roots), pack('h', feat), pack('d', thr), pack('i', left), pack('i', right), pack('d', val)]
chunks[2 + 7: 2 + 14] = new  # second forest = fillPass2
if '--write' in sys.argv:
    shutil.copy(BIN, 'PipelineWeights.before.bin')
    open(BIN, 'wb').write(b''.join(chunks)); print('wrote', BIN)
