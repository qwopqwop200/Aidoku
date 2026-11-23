"""prep.py TN: per page cache/tnTN/<pid>.npz with each annotated block's pooled input (uint8) and soft label."""
import sys, json, numpy as np
from pathlib import Path
from multiprocessing import Pool
from PIL import Image
sys.path.insert(0, str(Path(__file__).parent))
from blocks import load, META, S
from common import factor, inputs, pool, align
TN = float(sys.argv[1]); MODE = sys.argv[2] if len(sys.argv) > 2 else 'round'
OUT = S / 'cache' / (f'tn{int(TN)}' + ('c' if MODE == 'ceil' else '')); OUT.mkdir(parents=True, exist_ok=True)

def page(pid):
    js, bs = load(pid)
    img = np.asarray(Image.open(META[pid]['image']).convert('RGB'))
    lab = np.load(S / 'gt' / f'{pid}.npz')['lab']
    arrs = {}; info = []
    for j, b in enumerate(bs):
        x, y, w, h = b['frame']
        if w * h > 3_000_000: continue
        g = (lab[y:y + h, x:x + w] > 0)
        if not (g & (b['poly'] > 0)).any(): continue  # unannotated block: unknown labels
        k = factor(b['T'], TN, MODE)
        X, (ph, pw) = inputs(img[y:y + h, x:x + w], b['bg'], b['poly'], b['roi'], k)
        Y = align(pool(g[..., None].astype(np.float32), k))[..., 0]
        arrs[f'x{j}'] = np.round(X * 255).astype(np.uint8); arrs[f'y{j}'] = np.round(Y * 255).astype(np.uint8)
        info.append(dict(j=j, k=k, T=b['T'], ph=ph, pw=pw))
    np.savez(OUT / f'{pid}.npz', info=json.dumps(info), **arrs)
    return len(info)

if __name__ == '__main__':
    with Pool(8) as p: n = p.map(page, sorted(META))
    print(sum(n))
