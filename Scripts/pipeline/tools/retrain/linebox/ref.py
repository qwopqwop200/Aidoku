"""Expected S3refine boxes for a host run (Swift vs Python parity of PipelineLineBoxes).

  ref.py RUN_PREFIX OUT.json [--model PATH] [--raster DIR]

For every page of RUN_PREFIX_{train,dev,test}/stages/ID.front.json the input lines are `unrefined` (else
`recognized`, a pre-refine run), refined by lbfeat with the model JSON (default: the app resource) on the S4
CoreGraphics gray raster dump (exact parity needs it; an emulated raster is flagged). OUT.json:
  {ID: {source, gray, lines: [{bounds: [[x, y], [w, h]], polygon, moved}]}}
When the run holds `unrefined`, its `recognized` is the Swift output and is compared line by line here
(max |coordinate| difference of the box corners and polygon points; <= 1e-6 px counts as identical).
"""
import argparse, json, sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1])); sys.path.insert(0, str(HERE))
import workspace as ws  # noqa: E402
import lbfeat as F  # noqa: E402
import train as T  # noqa: E402


def corners(b):
    return [b[0], b[1], b[2], b[3]]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run_prefix'); ap.add_argument('out')
    ap.add_argument('--model', default=str(ws.REPO / T.RESOURCE)); ap.add_argument('--raster', action='append')
    a = ap.parse_args()
    model = json.load(open(a.model))
    if model['constants'] != F.C: sys.exit('model constants differ from lbfeat.C')
    dirs = [Path(d) for d in a.raster] if a.raster else T.RASTER_DIRS
    man = {p['page_id']: p for p in json.load(open(ws.MANIFEST))['pages']}
    out = {}; n = same = 0; worst = 0.0; worst_page = None; emulated = 0; bad_pages = set()
    for split in ('train', 'dev', 'test'):
        d = Path(f'{a.run_prefix}_{split}') / 'stages'
        if not d.is_dir(): continue
        for fn in sorted(d.glob('*.front.json')):
            pid = fn.name.split('.')[0]; f = json.load(open(fn)); m = man[pid]
            p = T.front_page(f, m, pid, split)
            if not p['lines']:
                out[pid] = dict(source=p['source'], gray=None, lines=[]); continue
            g, src = F.load_gray(pid, p['image'], p['width'], p['height'], dirs); emulated += src != 'cg'
            res = F.refine(p, g, model)
            out[pid] = dict(source=p['source'], gray=src, lines=[
                dict(bounds=[[r['box'][0], r['box'][1]], [r['box'][2] - r['box'][0], r['box'][3] - r['box'][1]]],
                     polygon=r['poly'], moved=r['moved']) for r in res])
            if p['source'] == 'unrefined':
                swift = f.get('recognized') or []
                if len(swift) != len(res):
                    bad_pages.add(pid); continue
                for r, s in zip(res, swift):
                    sb = T.rect(s['bounds'])
                    dd = [abs(x - y) for x, y in zip(corners(r['box']), sb)]
                    if r['poly'] and s.get('polygon'):
                        dd += [abs(q[k] - w[k]) for q, w in zip(r['poly'], s['polygon']) for k in (0, 1)]
                    d_ = max(dd); n += 1; same += d_ <= 1e-6
                    if d_ > worst: worst, worst_page = d_, pid
                    if d_ > 1e-6: bad_pages.add(pid)
    json.dump(out, open(a.out, 'w'))
    print(f'{len(out)} pages, {sum(len(v["lines"]) for v in out.values())} lines -> {a.out}; emulated rasters {emulated}')
    if n or bad_pages:
        print(f'Swift parity: {same}/{n} lines identical (<= 1e-6 px), max diff {worst:.3g} px (page {worst_page}), '
              f'{len(bad_pages)} pages differ: {sorted(bad_pages)[:20]}')


if __name__ == '__main__':
    main()
