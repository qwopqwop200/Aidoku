#!/usr/bin/env python3
"""compare.py BASE CAND [splits...]  (names under $AIDOKU_EVAL_DIR/runs/speed2, e.g. base s7-tensor)

Prints, per split and overall: pages with identical JSON (timings dropped) and the size of the differences,
pixel-identical PNGs and diff statistics (numbers and page ids only), wall time, stage means and peak RSS.
Run with the eval venv python (workspace.PYTHON: numpy + PIL).
"""
import json, os, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import RUNS  # noqa: E402
import numpy as np
from PIL import Image

R = str(RUNS / 'speed2')
DROP = re.compile(r'timing|_ms$|^ms$|^stages$|milliseconds', re.I)


def strip(o):
    if isinstance(o, dict):
        return {k: strip(v) for k, v in o.items() if not DROP.search(k)}
    if isinstance(o, list):
        return [strip(x) for x in o]
    return o


def leaves(o, path=''):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from leaves(v, f'{path}/{k}')
    elif isinstance(o, list):
        for i, v in enumerate(o):
            yield from leaves(v, f'{path}[{i}]')
    else:
        yield path, o


def json_diff(a, b):
    la, lb = dict(leaves(a)), dict(leaves(b))
    keys = set(la) | set(lb)
    differ = strings = 0
    drift = 0.0
    for k in keys:
        x, y = la.get(k), lb.get(k)
        if x == y:
            continue
        differ += 1
        if isinstance(x, (int, float)) and isinstance(y, (int, float)) and not isinstance(x, bool):
            drift = max(drift, abs(float(x) - float(y)))
        elif isinstance(x, str) or isinstance(y, str):
            strings += 1
    return differ, strings, drift


def png_diff(p, q):
    a = np.asarray(Image.open(p).convert('RGBA'), dtype=np.int16)
    b = np.asarray(Image.open(q).convert('RGBA'), dtype=np.int16)
    if a.shape != b.shape:
        return None
    d = np.abs(a - b).max(axis=2)
    return int(d.max()), float(d.mean()), float((d > 8).mean())


def peak_rss(name, split):
    try:
        t = open(f'{R}/{name}_{split}.time').read()
    except OSError:
        return None
    m = re.findall(r'(\d+)\s+maximum resident set size', t)
    return max(int(x) for x in m) / 1048576 if m else None


def stages(name, split):
    try:
        return json.load(open(f'{R}/{name}_{split}/summary.json'))
    except OSError:
        return None


def main():
    base, cand = sys.argv[1], sys.argv[2]
    splits = sys.argv[3:] or ['dev', 'train', 'test']
    tot = dict(pages=0, same=0, png=0, png_same=0, maxd=0, worst=[], share=[], strings=0, drift=0.0, blocks=0, missing=0)
    for s in splits:
        A, B = f'{R}/{base}_{s}/pages', f'{R}/{cand}_{s}/pages'
        if not os.path.isdir(B):
            print(f'{s}: candidate missing'); continue
        pages = sorted(f[:-5] for f in os.listdir(A) if f.endswith('.json'))
        same = pngs = png_same = 0
        diffs = []
        for p in pages:
            ja, jb = f'{A}/{p}.json', f'{B}/{p}.json'
            if not os.path.exists(jb):
                tot['missing'] += 1; continue
            a, b = strip(json.load(open(ja))), strip(json.load(open(jb)))
            if a == b:
                same += 1
            else:
                n, strs, dr = json_diff(a, b)
                tot['strings'] += strs; tot['drift'] = max(tot['drift'], dr)
                if len(a.get('blocks', [])) != len(b.get('blocks', [])):
                    tot['blocks'] += 1
                diffs.append((p, n, strs, dr))
            pa, pb = f'{A}/{p}.png', f'{B}/{p}.png'
            if os.path.exists(pa) and os.path.exists(pb):
                pngs += 1
                r = png_diff(pa, pb)
                if r is None:
                    tot['worst'].append((1e9, p)); continue
                mx, mean, share = r
                if mx == 0:
                    png_same += 1
                tot['maxd'] = max(tot['maxd'], mx); tot['share'].append(share)
                tot['worst'].append((share, p))
        tot['pages'] += len(pages); tot['same'] += same; tot['png'] += pngs; tot['png_same'] += png_same
        print(f'{s}: json identical {same}/{len(pages)}; png identical {png_same}/{pngs}')
        for p, n, strs, dr in sorted(diffs, key=lambda x: -x[1])[:5]:
            print(f'   json differs {p}: {n} leaves, {strs} strings, max numeric drift {dr:.3g}')
        sa, sb = stages(base, s), stages(cand, s)
        if sa and sb:
            print(f'   wall {sa["pagesWallMilliseconds"]:.0f} -> {sb["pagesWallMilliseconds"]:.0f} ms, '
                  f'pages/s {sa["throughputPagesPerSecond"]:.2f} -> {sb["throughputPagesPerSecond"]:.2f}, '
                  f'model load {sa["modelLoadMilliseconds"]:.0f} -> {sb["modelLoadMilliseconds"]:.0f} ms')
            ma, mb = sa['stageMilliseconds'], sb['stageMilliseconds']
            row = []
            for k in sorted(ma, key=lambda k: -ma[k]['mean']):
                if k in mb and ma[k]['mean'] >= 1:
                    row.append(f'{k} {ma[k]["mean"]:.1f}->{mb[k]["mean"]:.1f}')
            print('   ' + '; '.join(row))
        ra, rb = peak_rss(base, s), peak_rss(cand, s)
        if ra and rb:
            print(f'   peak RSS {ra:.0f} -> {rb:.0f} MB')
    print(f'TOTAL json identical {tot["same"]}/{tot["pages"]} (missing {tot["missing"]}, block-count changes {tot["blocks"]}, '
          f'string leaves changed {tot["strings"]}, max numeric drift {tot["drift"]:.3g})')
    if tot['png']:
        sh = np.array(tot['share'])
        worst = ' '.join(p for _, p in sorted(tot['worst'], reverse=True)[:5])
        print(f'TOTAL png identical {tot["png_same"]}/{tot["png"]}, max |diff| {tot["maxd"]}, '
              f'mean share |diff|>8 {sh.mean() * 100:.4f}%, worst share {sh.max() * 100:.3f}% (pages {worst})')


if __name__ == '__main__':
    main()
