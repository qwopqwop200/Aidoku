"""convert.py RUN OUT.mlpackage: fold BN, wrap with sigmoid, convert to an FP16 ML Program with flexible H/W (multiples of 8)."""
import sys, torch, numpy as np, coremltools as ct
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from net import UNet
ck = torch.load(Path(sys.argv[1]) / 'model.pt', map_location='cpu')
a = ck['args']
m = UNet(chans=tuple(int(c) for c in a['chans'].split(',')), sep=bool(a['sep']))
m.load_state_dict(ck['state']); m.eval()
class Wrap(torch.nn.Module):
    def __init__(s, m): super().__init__(); s.m = m
    def forward(s, x): return torch.sigmoid(s.m(x))
w = Wrap(m).eval()
ex = torch.rand(1, 6, 64, 96)
tr = torch.jit.trace(w, ex)
H = ct.RangeDim(lower_bound=8, upper_bound=4096, default=256)
W = ct.RangeDim(lower_bound=8, upper_bound=4096, default=256)
ml = ct.convert(tr, inputs=[ct.TensorType(name='input', shape=(1, 6, H, W), dtype=np.float32)],
                outputs=[ct.TensorType(name='prob', dtype=np.float32)],
                convert_to='mlprogram', compute_precision=ct.precision.FLOAT16, minimum_deployment_target=ct.target.iOS16)
ml.short_description = f"S6 removal-mask U-Net {a['chans']} (T <= {a['tn']} px after integer box downscale, output gate {a.get('gate', 0)} T): input 1x6xHxW (RGB, max|RGB-bg|, line polygon, ROI; 0-1; H, W multiples of 8) -> glyph probability. Trained on train-split GT glyph masks."
ml.save(sys.argv[2])
x = torch.rand(1, 6, 120, 200)
ref = w(x).detach().numpy()
out = ml.predict({'input': x.numpy()})['prob']
print('max abs diff vs torch', float(np.abs(out - ref).max()))
