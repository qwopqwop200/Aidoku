"""Append the line-end forest (model-fin, trained on TRAIN folds 2-4) to PipelineWeights.bin as the 5th forest
`lineEnds`. Forest layout: f64[base, rate], roots i32, feature i16, threshold f64, left i32, right i32, value f64;
each table a u32 count + little-endian elements. usage: export.py BIN [--write]"""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import EVAL  # noqa: E402
import struct, pickle, os, numpy as np, lightgbm as lgb
os.environ['ALL'] = '1'
from learn import BINS
BIN = sys.argv[1]
b = lgb.Booster(model_file=str(EVAL / 'bboxagent/model-fin.txt')); cols = pickle.load(open(EVAL / 'bboxagent/model-fin.pkl', 'rb'))[0]
names = [f'p{d}_{x:.1f}' for d in (0, 1, 3) for x in BINS] + ['T', 'len', 'score', 'vert', 'which', 'rfText', 'rfBalloon', 'gap', 'bg']
rows = pickle.load(open(EVAL / 'bboxagent/rows32.pkl', 'rb')); ci = [names.index(c) for c in cols]
X = np.array([r[3] for r in rows], np.float32)[:, ci]
roots, feat, thr, left, right, val = [], [], [], [], [], []
def add(node):
    i = len(feat); feat.append(0); thr.append(0.0); left.append(-1); right.append(-1); val.append(0.0)
    if 'leaf_value' in node: val[i] = node['leaf_value']
    else:
        assert node['decision_type'] == '<=', node['decision_type']
        feat[i] = node['split_feature']; thr[i] = node['threshold']
        left[i] = add(node['left_child']); right[i] = add(node['right_child'])
    return i
for t in b.dump_model()['tree_info']: roots.append(add(t['tree_structure']))
def logit(x):
    z = 0.0
    for r in roots:
        n = r
        while left[n] >= 0: n = left[n] if float(np.float32(x[feat[n]])) <= thr[n] else right[n]
        z += val[n]
    return z
ref = b.predict(X); mine = np.array([logit(x) for x in X[:5000]])
print('features', len(cols), 'trees', len(roots), 'nodes', len(feat), 'max |diff|', np.abs(mine - ref[:5000]).max())
np.save('pred-fin.npy', ref)
data = open(BIN, 'rb').read(); off = 0
def skip(fmt):
    global off
    n = struct.unpack_from('<I', data, off)[0]; off += 4 + n * struct.calcsize(fmt)
for c in ['f', 'f'] + ['d', 'i', 'h', 'd', 'i', 'i', 'd'] * 4: skip(c)
keep = data[:off]
def pack(fmt, xs): return struct.pack('<I', len(xs)) + struct.pack('<' + fmt * len(xs), *xs)
new = keep + b''.join([pack('d', [0.0, 1.0]), pack('i', roots), pack('h', feat), pack('d', thr), pack('i', left), pack('i', right), pack('d', val)])
print('bin', len(data), '->', len(new))
if '--write' in sys.argv: open(BIN, 'wb').write(new); print('wrote')
