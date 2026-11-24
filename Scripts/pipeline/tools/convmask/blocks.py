"""Per-page block geometry dumped by harness (BLOCKS=1): frame, T, background, line-polygon and ROI masks."""
import json, sys, zlib
from pathlib import Path
import numpy as np
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import EVAL  # noqa: E402
S = EVAL / 'convmask'  # GT masks, caches, runs (outside the repository)
META = json.load(open(S / 'gt' / 'meta.json'))


def load(pid):
    js = json.load(open(S / 'blocks' / f'{pid}.json'))
    blob = zlib.decompress(open(S / 'blocks' / f'{pid}.b', 'rb').read(), -15)
    out = []
    for b in js['blocks']:
        x, y, w, h = b['frame']; o = b['offset']; n = w * h
        poly = np.frombuffer(blob, np.uint8, n, o).reshape(h, w)
        roi = np.frombuffer(blob, np.uint8, n, o + n).reshape(h, w)
        out.append(dict(b, poly=poly, roi=roi))
    return js, out
