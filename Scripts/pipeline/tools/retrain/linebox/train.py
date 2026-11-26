"""Retrain the S3refine line-box model (PipelineLineBoxes.swift, Resources/Translation/PipelineLineBoxes.json).

  train.py RUN_PREFIX [--out PATH] [--check] [--eval] [--raster DIR] [--augment SPEC]

Input: a host run saved with --save-stages (RUN_PREFIX_{train,dev,test}/stages/ID.front.json):
  - lines: `unrefined` (S3 lines after the keep gate, before refine) when present, else `recognized` (a run made
    before the refine stage existed, e.g. runs/speed2/keep830, which the shipped model was trained on);
  - frags: `detected` (S2 detector lines before S2b assembly); `layout` (S1 RF-DETR regions);
  - pixels: the app's S4 gray raster (PipelineGrayRaster: CoreGraphics, <= 768 px long side) as DIR/ID.raw +
    DIR/ID.size from Scripts/pipeline/tools/retrain/interior/rasterdump.swift. Without a dump the raster is emulated
    (sRGB luminance + Hamming downscale, ~0.5 gray levels off), which is reported.
GT: individual_premerge_bbox canonical line polygons, matched to lines one-to-one (Hungarian on IoU, IoU >= 0.5).

Method (port-eval/linebox/algos/profile_snap.py, lbfeat.py): per line, 4 edge rows of 65 features; a HistGBR
(absolute loss) for the along edges (target clipped to [-0.4, 1.0] thicknesses) and one for the cross edges
([-0.3, 0.3]). Fixed hyperparameters (no selection step), random_state 0, fit on TRAIN pages only.
--eval: leave-one-group-out on train under the page (manifest folds), size (page W x H groups) and chunk (page-id
runs) schemes, then the full-train model on dev and test; the input lines are printed as the baseline.

--augment SPEC (training rows only; off by default, and without it the output is byte-identical), parts joined by ';':
  mix=RUN,RUN,...   add the train pages of these runs (names under $AIDOKU_EVAL_DIR/runs or prefixes); a page whose
                    inputs (lines, frags, layout) equal one already in the pool is skipped, so identical runs
                    (keep830 / lb830 / all830 / snap2-ref hold the same unrefined lines) add nothing;
  jitter=S[xN],...  N copies (default 1) of each pool page with every input S3 line box moved by
                    retrain/augment.Jitter at scale S (the run's measured unrefined-vs-GT edge error), polygons mapped
                    onto the new box, the page features recomputed and the targets taken from GT against the jittered
                    box (the GT match is the one of the unjittered line). Seeds are fixed per page, run, scale, copy.
  All copies keep the page's fold / size / chunk groups, so LOFO keeps them on the same side; evaluation is always on
  the RUN_PREFIX pages themselves. With --augment the default --out is the scratch file
  $AIDOKU_EVAL_DIR/retrain/linebox/aug/PipelineLineBoxes.json, never the app resource.
"""
import argparse, collections, hashlib, json, os, sys, tempfile, time, zlib
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parents[1])); sys.path.insert(0, str(HERE))
import workspace as ws  # noqa: E402
import lbfeat as F  # noqa: E402
import lbscore as S  # noqa: E402

RESOURCE = 'Aidoku/Resources/Translation/PipelineLineBoxes.json'
SPEC = {
    'name': 'linebox',
    'resource': [RESOURCE],
    'stage': 'S3refine',
    'inputs': 'front.unrefined (S3 lines after keep, before refine; else front.recognized of a pre-refine run) + '
              'front.detected (S2 frags) + front.layout + the S4 CoreGraphics gray raster (rasterdump.swift); '
              'GT individual_premerge_bbox',
    'needs_full': False,
    'rerun_from': 's4',
    'augment': None,     # 2026-11-26 round: mix (base830) and jitter 0.25-1.0 tried, none beat base on every scheme
    'rerun_note': 'a --from s4 rerun re-refines front.unrefined with the current model; checkpoints without '
                  '`unrefined` (pre-refine runs) keep their saved lines, so they need a fresh S1-S4 run',
}
SCRATCH = ws.data('retrain', 'linebox', 'x').parent
RASTER_DIRS = [SCRATCH / 'cgraw', ws.EVAL / 'retrain' / 'interior' / 'cgraw', ws.EVAL / 'stageopt' / 'interior' / 'cache' / 'cgraw']
SCHEMES = dict(page='fold', size='size_group', chunk='chunk_group')


def rect(b):
    (x, y), (w, h) = b
    return [x, y, x + w, y + h]


def gt_lines():
    st = os.stat(ws.GT); key = f'{ws.GT}:{st.st_size}:{st.st_mtime_ns}'
    cache = SCRATCH / 'gt_lines.json'
    if cache.exists():
        c = json.load(open(cache))
        if c.get('key') == key: return c['lines']
    out = collections.defaultdict(list)
    for r in json.load(open(ws.GT))['records']:
        if r['scope'] == 'individual_premerge_bbox' and r.get('status') == 'canonical':
            poly = [[p['x'], p['y']] for p in r['label']['polygon']]
            xs = [p[0] for p in poly]; ys = [p[1] for p in poly]
            out[r['page_id']].append(dict(box=[min(xs), min(ys), max(xs), max(ys)], poly=poly))
    json.dump({'key': key, 'lines': out}, open(cache, 'w'))
    return out


def front_page(f, m, pid, split):
    """A page dict (lbfeat input) from one stages/ID.front.json."""
    src = 'unrefined' if f.get('unrefined') is not None else 'recognized'
    return dict(page=pid, split=split, width=m['width'], height=m['height'], image=m['image_path'], source=src,
                layout=[dict(kind=r['kind'], box=rect(r['bounds'])) for r in f['layout']],
                frags=[dict(box=rect(l['bounds'])) for l in (f.get('detected') or [])],
                lines=[dict(box=rect(l['bounds']), poly=l['polygon'], vertical=l['vertical'], text=l.get('text') or '',
                            conf=l.get('confidence', 0), score=l.get('detectionScore', 0)) for l in (f.get(src) or [])])


def load_run(prefix, gt, only_gt=True):
    man = {p['page_id']: p for p in json.load(open(ws.MANIFEST))['pages']}
    pages = []
    for split in ('train', 'dev', 'test'):
        d = Path(f'{prefix}_{split}') / 'stages'
        if not d.is_dir(): continue
        for fn in sorted(d.glob('*.front.json')):
            pid = fn.name.split('.')[0]
            if only_gt and pid not in gt: continue
            m = man[pid]
            p = front_page(json.load(open(fn)), m, pid, m['split'])
            p['fold'] = f"f{m['fold']}" if p['split'] == 'train' else p['split']
            pages.append(p)
    # group folds on train (as port-eval/linebox/export.py): size = W x H groups greedily balanced, chunk = page-id thirds
    tr = [p for p in pages if p['split'] == 'train']
    sizes = collections.Counter((p['width'], p['height']) for p in tr); load = {g: 0 for g in ('s1', 's2', 's3')}; of = {}
    for wh, n in sorted(sizes.items(), key=lambda kv: -kv[1]):
        g = min(load, key=load.get); of[wh] = g; load[g] += n
    ids = sorted(p['page'] for p in tr)
    chunk = {pid: 'c%d' % (1 + min(2, 3 * i // len(ids))) for i, pid in enumerate(ids)}
    for p in tr: p['size_group'] = of[(p['width'], p['height'])]; p['chunk_group'] = chunk[p['page']]
    return pages


class Features:
    """Per-page features, computed once (the gray raster is read only here)."""
    def __init__(self, raster_dirs):
        self.dirs = raster_dirs; self.cache = {}; self.sources = collections.Counter()

    def gray(self, p):
        g, src = F.load_gray(p['page'], p['image'], p['width'], p['height'], self.dirs)
        self.sources[src] += 1
        return g

    def __call__(self, p):
        k = p.get('key', p['page'])
        if k not in self.cache: self.cache[k] = F.page_features(p, self.gray(p)) if p['lines'] else []
        return self.cache[k]


def rows(pages, gt, feats):
    XA, YA, XC, YC = [], [], [], []
    from scipy.optimize import linear_sum_assignment
    for p in pages:
        g = [x['box'] for x in gt.get(p['page'], [])]
        if not g or not p['lines']: continue
        if 'match' in p: pairs = p['match']
        else:
            iou = S.iou_matrix(g, [l['box'] for l in p['lines']])[0]
            pairs = [(a, b) for a, b in zip(*linear_sum_assignment(-iou)) if iou[a, b] >= 0.5]
        pf = feats(p)
        for a, b in pairs:
            R, meta = pf[b]; t = F.targets(meta, g[a])
            XA += [R[0], R[1]]; YA += t[:2]; XC += [R[2], R[3]]; YC += t[2:]
    return XA, YA, XC, YC


def parse_augment(spec):
    out = dict(mix=[], jitter=[])
    for part in filter(None, (x.strip() for x in (spec or '').split(';'))):
        k, _, v = part.partition('=')
        if k == 'mix': out['mix'] += [x for x in v.split(',') if x]
        elif k == 'jitter':
            for z in filter(None, v.split(',')):
                sc, _, n = z.partition('x'); out['jitter'].append((float(sc), int(n or 1)))
        else: raise SystemExit(f'--augment: unknown part {part!r}')
    return out


def _input_hash(p):
    return hashlib.md5(json.dumps([p['lines'], p['frags'], p['layout']]).encode()).hexdigest()


def _match(p, gt):
    from scipy.optimize import linear_sum_assignment
    g = [x['box'] for x in gt.get(p['page'], [])]
    if not g or not p['lines']: return []
    iou = S.iou_matrix(g, [l['box'] for l in p['lines']])[0]
    return [(int(a), int(b)) for a, b in zip(*linear_sum_assignment(-iou)) if iou[a, b] >= 0.5]


def _map_box(b, ob, nb):
    sx = (nb[2] - nb[0]) / max(ob[2] - ob[0], 1e-6); sy = (nb[3] - nb[1]) / max(ob[3] - ob[1], 1e-6)
    return [nb[0] + (b[0] - ob[0]) * sx, nb[1] + (b[1] - ob[1]) * sy, nb[0] + (b[2] - ob[0]) * sx, nb[1] + (b[3] - ob[1]) * sy]


def jitter_page(p, gt, J):
    """A copy of page p with every input line box jittered (augment.Jitter), the GT match of the original lines.
    The S3 lines are built from the S2 frags, so each frag lying mostly inside one line (>= half its area) moves with
    that line (same per-axis map as the polygon); otherwise the frags would leak the jitter (frag_extension)."""
    q = dict(p); q['match'] = p['match'] if 'match' in p else _match(p, gt); lines = []
    for l in p['lines']:
        nb = list(J.box(tuple(l['box']), bool(l['vertical'])))
        lines.append(dict(l, box=nb, poly=F.map_poly(l['poly'], l['box'], nb)))
    q['lines'] = lines
    if p['frags'] and p['lines']:
        cov = S.iou_matrix([f['box'] for f in p['frags']], [l['box'] for l in p['lines']])[1]   # inter / frag area
        q['frags'] = [dict(f, box=_map_box(f['box'], p['lines'][j]['box'], lines[j]['box'])) if c[j] >= 0.5 else f
                      for f, c in zip(p['frags'], cov) for j in [int(np.argmax(c))]]
    return q


def augment_pool(tr, gt, spec, prefix):
    """The training pages for --augment SPEC: tr (RUN_PREFIX train pages), + mix runs' new pages, + jittered copies."""
    sys.path.insert(0, str(HERE.parent)); import augment as A
    a = parse_augment(spec)
    groups = {p['page']: {k: p[k] for k in ('fold', 'size_group', 'chunk_group')} for p in tr}
    pool = [dict(p, run=str(prefix)) for p in tr]; seen = {_input_hash(p) for p in pool}
    for r in a['mix']:
        rp = r if os.path.isabs(r) else str(A.run_path(r))
        if Path(rp).resolve() == Path(prefix).resolve(): continue
        for p in load_run(rp, gt):
            if p['split'] != 'train' or p['page'] not in groups: continue
            h = _input_hash(p)
            if h in seen: continue
            seen.add(h); p.update(groups[p['page']]); p['run'] = rp; p['key'] = f"{p['page']}@{rp}"
            pool.append(p)
    base = list(pool); out = list(pool)
    for sc, n in a['jitter']:
        for p in base:
            res = A.residuals(p['run'])
            for k in range(n):
                seed = [zlib.crc32(p['page'].encode()), zlib.crc32(Path(p['run']).name.encode() + Path(p['run']).parent.name.encode()),
                        int(round(sc * 1000)), k]
                q = jitter_page(p, gt, A.Jitter(res, sc, seed))
                q['key'] = f"{p.get('key', p['page'])}#j{sc}x{k}"
                out.append(q)
    return out


def fit(pages, gt, feats):
    XA, YA, XC, YC = rows(pages, gt, feats)
    along, _ = F.fit_trees(XA, YA, F.C['clip'], F.ALONG)
    cross, _ = F.fit_trees(XC, YC, F.C['cclip'], F.CROSS)
    return dict(along=along, cross=cross, n_rows=[len(YA), len(YC)])


def feature_names():
    g = ['thickness', 'length_th', 'chars', 'length_per_char', 'inner_median', 'vertical', 'region_kind', 'confidence',
         'detection_score', 'skew', 'abs_skew']
    g += [f'side{k}' for k in range(4)] + [f'end_class{k}' for k in range(-1, 10)]
    g += ['region_gap', 'neighbour_gap', 'border_gap', 'frag_extension', 'frag_count']
    for t in F.C['thresholds']:
        g += [f't{t}_{n}' for n in ['inward_gap', 'run_g0', 'run_g1', 'run_g2', 'out_b0', 'out_b1', 'out_b2', 'out_b3',
                                    'out_b4', 'in_b0', 'in_b1', 'step_offset', 'step_strength', 'first_plateau']]
    g += ['cont_band_in', 'cont_side_in', 'cont_band_w0', 'cont_side_w0', 'cont_band_w1', 'cont_side_w1']
    assert len(g) == F.NFEAT
    return g


def resource(model, run):
    return dict(method='S3refine projection-profile edge snapping (port-eval/linebox/algos/profile_snap.py) on the S4 '
                       'gray raster; offsets in thickness units: top, bottom, left, right in the line frame',
                trainedOn=Path(run).name, constants=F.C, charClasses=F.CHARSETS, features=feature_names(),
                along=model['along'], cross=model['cross'])


def predict_pages(model, pages, feats):
    out = {}
    for p in pages:
        if not p['lines']: out[p['page']] = []; continue
        pf = feats(p); off = F.offsets(model, pf); res = []
        for l, (_, meta), o in zip(p['lines'], pf, off):
            nb = F.assemble(meta, o)
            res.append(dict(box=l['box'], poly=l['poly']) if nb is None else
                       dict(box=nb, poly=F.map_poly(l['poly'], l['box'], nb)))
        out[p['page']] = res
    return out


def evaluate(pages, gt, feats, pool=None):
    """pool: the (augmented) training pages; default the run's own train pages. Held-out = the run's own pages."""
    tr = [p for p in pages if p['split'] == 'train']
    pool = tr if pool is None else pool
    labels = {p['page']: gt[p['page']] for p in pages}
    base = {p['page']: [dict(box=l['box'], poly=l['poly']) for l in p['lines']] for p in pages}
    for scheme, key in SCHEMES.items():
        preds = {}
        for g in sorted({p[key] for p in tr}):
            m = fit([p for p in pool if p[key] != g], gt, feats)
            preds.update(predict_pages(m, [p for p in tr if p[key] == g], feats))
        print(f'train {scheme:5s}', S.score(preds, labels, [p['page'] for p in tr]), flush=True)
    m = fit(pool, gt, feats)
    for split in ('dev', 'test'):
        ps = [p for p in pages if p['split'] == split]
        if not ps: continue
        print(f'{split:11s}', S.score(predict_pages(m, ps, feats), labels, [p['page'] for p in ps]), flush=True)
    for split in ('train', 'dev', 'test'):
        ps = [p['page'] for p in pages if p['split'] == split]
        if ps: print(f'input {split:5s}', S.score(base, labels, ps), flush=True)
    return m


def compare(new, old_path, pages, feats):
    old = json.load(open(old_path))
    diffs = []
    for part in ('along', 'cross'):
        a, b = new[part], old[part]
        if any(len(a[k]) != len(b[k]) for k in ('roots', 'feature', 'split', 'left', 'right', 'value')):
            print(f'{part}: structure differs ({len(a["roots"])} vs {len(b["roots"])} trees, '
                  f'{len(a["split"])} vs {len(b["split"])} nodes)'); diffs.append(float('inf')); continue
        same_int = all(a[k] == b[k] for k in ('roots', 'feature', 'left', 'right'))
        d = max([abs(a['base'] - b['base'])] + [abs(x - y) for k in ('split', 'value') for x, y in zip(a[k], b[k])])
        print(f'{part}: integer arrays {"identical" if same_int else "differ"}, max abs diff {d:.3g}')
        diffs.append(d if same_int else float('inf'))
    if new['constants'] != old['constants'] or new['charClasses'] != old['charClasses']: print('constants differ')
    pn, po = predict_pages(new, pages, feats), predict_pages(old, pages, feats)
    n = agree = 0; worst = 0.0
    for pid in pn:
        for a, b in zip(pn[pid], po[pid]):
            d = max(abs(x - y) for x, y in zip(a['box'], b['box'])); worst = max(worst, d)
            n += 1; agree += d < 1e-6
    print(f'prediction agreement {agree}/{n} lines ({agree / max(n, 1):.4%}), max box diff {worst:.3g} px')
    print('IDENTICAL' if all(d == 0 for d in diffs) and new['constants'] == old['constants'] else 'DIFFERENT')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run_prefix'); ap.add_argument('--out', default=str(ws.REPO / RESOURCE))
    ap.add_argument('--check', action='store_true'); ap.add_argument('--eval', action='store_true')
    ap.add_argument('--raster', action='append', help='DIR of ID.raw / ID.size S4 rasters (repeatable)')
    ap.add_argument('--augment', help="training augmentation SPEC, e.g. 'mix=speed2/base830;jitter=0.5x2' (module doc)")
    a = ap.parse_args()
    if a.augment and a.out == str(ws.REPO / RESOURCE): a.out = str(ws.data('retrain', 'linebox', 'aug', 'PipelineLineBoxes.json'))
    t0 = time.time()
    dirs = [Path(d) for d in a.raster] if a.raster else RASTER_DIRS
    gt = gt_lines(); pages = load_run(a.run_prefix, gt); feats = Features(dirs)
    srcs = collections.Counter(p['source'] for p in pages)
    print(f'{len(pages)} pages with GT, lines from {dict(srcs)}', flush=True)
    tr = [p for p in pages if p['split'] == 'train']
    pool = augment_pool(tr, gt, a.augment, a.run_prefix) if a.augment else tr
    if a.augment: print(f'augment {a.augment!r}: {len(pool)} training pages ({len(tr)} of the run)', flush=True)
    model = evaluate(pages, gt, feats, pool) if a.eval else fit(pool, gt, feats)
    print(f'fit rows along/cross {model["n_rows"]}, trees {len(model["along"]["roots"])}/{len(model["cross"]["roots"])}, '
          f'nodes {len(model["along"]["split"])}/{len(model["cross"]["split"])}; gray rasters {dict(feats.sources)}')
    res = resource(model, a.run_prefix)
    if a.augment: res['augment'] = a.augment
    if a.check:
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f:
            json.dump(res, f, separators=(',', ':'))
        compare(json.load(open(f.name)), a.out, pages, feats); os.unlink(f.name)
    else:
        json.dump(res, open(a.out, 'w'), separators=(',', ':'))
        print('wrote', a.out, os.path.getsize(a.out), 'bytes')
    print(f'{time.time() - t0:.0f} s')


if __name__ == '__main__':
    main()
