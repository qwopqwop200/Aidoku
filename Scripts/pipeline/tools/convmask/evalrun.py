"""evalrun.py RUN FOLDS THRS [DEVICE]: page masks of RUN's model for pages in FOLDS (comma list) at each threshold
into runs/RUN/t<thr>/ (same pre/post-processing as PipelineRemovalMask's conv path)."""
import sys, json, zlib
from pathlib import Path
import numpy as np, torch, cv2
from PIL import Image
sys.path.insert(0, str(Path(__file__).parent))
from blocks import load, META, S
from common import factor, inputs, upsample
from net import UNet

def main(run, folds, thrs, device='cpu', dilate=2):
    ck = torch.load(S / 'runs' / run / 'model.pt', map_location='cpu'); a = ck['args']
    model = UNet(chans=tuple(int(c) for c in a['chans'].split(',')), sep=bool(a['sep'])); model.load_state_dict(ck['state'])
    model.eval().to(device)
    out = S / 'runs' / run
    for t in thrs: (out / f't{t}').mkdir(exist_ok=True)
    kd = np.ones((2 * dilate + 1, 2 * dilate + 1), np.uint8)
    for pid in [p for p in sorted(META) if META[p]['fold'] in folds]:
        js, bs = load(pid); W, H = js['w'], js['h']
        img = np.asarray(Image.open(META[pid]['image']).convert('RGB'))
        masks = {t: np.zeros((H, W), np.uint8) for t in thrs}
        for b in bs:
            x0, y0, w, h = b['frame']
            if w * h > 3_000_000:
                pm = cv2.dilate(b['poly'], kd)
                for t in thrs: masks[t][y0:y0 + h, x0:x0 + w] |= pm
                continue
            k = factor(b['T'], a['tn'], a.get('kmode', 'round'))
            inp, (ph, pw) = inputs(img[y0:y0 + h, x0:x0 + w], b['bg'], b['poly'], b['roi'], k)
            with torch.no_grad():
                p = torch.sigmoid(model(torch.from_numpy(inp)[None].to(device)))[0, 0].cpu().numpy()[:ph, :pw]
            pf = upsample(p, k, h, w)
            gate = b['roi'] > 0
            g = int(round(a.get('gate', 0.0) * b['T']))
            if g: gate = cv2.dilate(b['roi'], np.ones((2 * g + 1, 2 * g + 1), np.uint8)) > 0
            for t in thrs:
                masks[t][y0:y0 + h, x0:x0 + w] |= cv2.dilate(((pf >= t) & gate).astype(np.uint8), kd)
        ids = json.load(open(S / 'masks' / 'base' / f'{pid}.json'))['ids']
        for t in thrs:
            d = zlib.compressobj(1, zlib.DEFLATED, -15)
            open(out / f't{t}' / f'{pid}.z', 'wb').write(d.compress(masks[t].tobytes()) + d.flush())
            json.dump(dict(w=W, h=H, ids=ids), open(out / f't{t}' / f'{pid}.json', 'w'))

if __name__ == '__main__':
    main(sys.argv[1], {int(f) for f in sys.argv[2].split(',')}, [float(t) for t in sys.argv[3].split(',')],
         *(sys.argv[4:5] or ['cpu']))
