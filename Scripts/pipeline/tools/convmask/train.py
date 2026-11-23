"""train.py --name N --train 3,4 [--eval 2] ...: train the block U-Net on train-fold pages; optionally write
held-out page masks for thresholds and score them against the MLP baseline."""
import argparse, json, sys, time, zlib, collections
from pathlib import Path
import numpy as np, torch, torch.nn.functional as F, cv2
from PIL import Image
sys.path.insert(0, str(Path(__file__).parent))
from blocks import load, META, S
from common import factor, inputs, upsample
from net import UNet, params

ap = argparse.ArgumentParser()
ap.add_argument('--name', required=True); ap.add_argument('--train', default='2,3,4'); ap.add_argument('--eval', default='')
ap.add_argument('--tn', type=int, default=32); ap.add_argument('--chans', default='8,16,32'); ap.add_argument('--sep', type=int, default=0)
ap.add_argument('--iters', type=int, default=6000); ap.add_argument('--batch', type=int, default=32); ap.add_argument('--patch', type=int, default=128)
ap.add_argument('--lr', type=float, default=3e-3); ap.add_argument('--posw', type=float, default=2.0)
ap.add_argument('--thr', default='0.05,0.1,0.2,0.3,0.4,0.5'); ap.add_argument('--seed', type=int, default=0)
ap.add_argument('--dilate', type=int, default=2)
ap.add_argument('--kmode', default='round')
ap.add_argument('--gate', type=float, default=0.0)  # loss/inference region: ROI dilated by gate * T
a = ap.parse_args()
torch.manual_seed(a.seed); rng = np.random.default_rng(a.seed)
dev = torch.device('mps')
OUT = S / 'runs' / a.name; OUT.mkdir(parents=True, exist_ok=True)
folds = {int(f) for f in a.train.split(',')}
chans = tuple(int(c) for c in a.chans.split(','))

# ---- data
X, Y = [], []
for pid in sorted(META):
    if META[pid]['fold'] not in folds: continue
    z = np.load(S / 'cache' / (f'tn{a.tn}' + ('c' if a.kmode == 'ceil' else '')) / f'{pid}.npz')
    for b in json.loads(str(z['info'])):
        X.append(z[f'x{b["j"]}']); Y.append(z[f'y{b["j"]}'])
area = np.array([float((x[5] > 0).sum()) for x in X]); prob = area / area.sum()
print(f'{len(X)} blocks, {area.sum() / 1e6:.1f}M roi px (pooled)', flush=True)
P = a.patch

def sample():
    xs = np.zeros((a.batch, 6, P, P), np.uint8); ys = np.zeros((a.batch, P, P), np.uint8)
    for i, j in enumerate(rng.choice(len(X), a.batch, p=prob)):
        x, y = X[j], Y[j]; _, h, w = x.shape
        r = np.argwhere(x[5] > 0); cy, cx = r[rng.integers(len(r))]  # centre on a random roi pixel
        y0 = int(np.clip(cy - P // 2, 0, max(0, h - P))); x0 = int(np.clip(cx - P // 2, 0, max(0, w - P)))
        px, py = x[:, y0:y0 + P, x0:x0 + P], y[y0:y0 + P, x0:x0 + P]
        if rng.random() < 0.5: px, py = px[:, :, ::-1], py[:, ::-1]
        if rng.random() < 0.5: px, py = px[:, ::-1], py[::-1]
        if rng.random() < 0.5: px, py = px.transpose(0, 2, 1), py.T
        px = px.copy()
        if rng.random() < 0.5: px[:3] = px[rng.permutation(3)]
        xs[i, :, :px.shape[1], :px.shape[2]] = px; ys[i, :py.shape[0], :py.shape[1]] = py
    return xs, ys

gp = int(round(a.gate * a.tn))
model = UNet(chans=chans, sep=bool(a.sep)).to(dev)
print('params', params(model), flush=True)
opt = torch.optim.AdamW(model.parameters(), lr=a.lr, weight_decay=1e-4)
sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=a.lr, total_steps=a.iters, pct_start=0.05)
t0 = time.time(); run = 0
import threading, queue
q = queue.Queue(8)
def producer():
    while True: q.put(sample())
for _ in range(3): threading.Thread(target=producer, daemon=True).start()
model.train()
for it in range(a.iters):
    xs, ys = q.get()
    x = torch.from_numpy(xs).to(dev).float() / 255; y = torch.from_numpy(ys).to(dev).float() / 255
    m = (x[:, 5] > 0).float()
    if gp: m = F.max_pool2d(m[:, None], 2 * gp + 1, 1, gp)[:, 0]
    logit = model(x)[:, 0]
    l = F.binary_cross_entropy_with_logits(logit, y, reduction='none') * (1 + (a.posw - 1) * y)
    loss = (l * m).sum() / m.sum().clamp(min=1)
    opt.zero_grad(); loss.backward(); opt.step(); sched.step()
    run = 0.98 * run + 0.02 * loss.item()
    if it % 500 == 0 or it == a.iters - 1: print(f'it {it} loss {run:.4f} {time.time() - t0:.0f}s', flush=True)
torch.save(dict(state=model.state_dict(), args=vars(a)), OUT / 'model.pt')

# ---- held-out page masks (separate process: tools/evalrun.py; in-process MPS eval after training did not match)
if a.eval:
    import subprocess
    subprocess.run([sys.executable, '-W', 'ignore', str(Path(__file__).parent / 'evalrun.py'), a.name, a.eval, a.thr], check=True)
