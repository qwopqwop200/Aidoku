#!/usr/bin/env python3
"""train.py RUN_PREFIX [--out PATH] [--check] [--eval]

S2b line assembly (PipelineLineAssembly.swift): a logistic pair model on 22 scale-free features of two candidate
fragments (relaxed geometric gate), joined greedily, most probable first, while p >= THRESHOLD (0.4, chosen in the
experiment as the threshold with the smallest worst case under page / size / chunk leave-one-group-out).

Training data, per TRAIN page of RUN_PREFIX_train: the S2 detector lines (`front.detected`, before assembly) and the
GT line boxes. A fragment belongs to the GT line covering >= 0.5 of it. Candidate pairs come from three states of the
page: the raw fragments, the oracle groups (true lines + singleton noise) and the hand-rule assembly; label 1 when
both sides belong to one and the same GT line, 0 otherwise, pairs of two noise sides skipped. StandardScaler +
LogisticRegression(C=1, lbfgs). Writes Resources/Translation/PipelineLineJoin.json.

--eval: err = split + over + (gt - ex50) of the assembled lines against the GT lines, on three inputs (det: the
detector lines; gtfrag: GT lines cut where the detector fragments fall; gtlines: the GT lines themselves), for
train leave-one-group-out (page folds 2/3/4, size groups, chunk groups) and the model fit on all train on dev/test.
Method: port-eval/stageopt/assembly (learn.py, r3lib.fit_logit, r4.py, r4_final.py: R4a).
"""
import argparse, collections, json, math, re, sys, tempfile, time
from pathlib import Path

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.preprocessing import StandardScaler

sys.path.insert(0, str(Path(__file__).resolve().parents[2])); sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from workspace import GT, MANIFEST, REPO, RUNS, data  # noqa: E402
import augment as AUG  # noqa: E402

RESOURCE = 'Aidoku/Resources/Translation/PipelineLineJoin.json'
SPEC = dict(
    name='assembly',
    resource=[RESOURCE],
    stage='S2b',
    inputs='front.detected: S2 detector lines before assembly; front.layout: S1 balloon/text regions; '
           'GT individual_premerge_bbox line boxes',
    needs_full=False,
    rerun_from='s4',
    augment=None,  # no variant gained (aug_eval.py 2026-11-26); applied only when --augment is given
)
THRESHOLD = 0.4
FEATURES = ['axis_vertical', 'thickness_ratio', 'gap_thin', 'cross_overlap_thin', 'cross_overlap_thick',
            'centre_offset_thin', 'thin_length', 'thick_length', 'thin_length_thick', 'aspect_min', 'aspect_max',
            'flag_agreement', 'score_min', 'score_max', 'balloon_relation', 'layout_ok', 'text_region_share',
            'hand_rule', 'fragment_count', 'merged_aspect', 'gap_thick', 'along_overlap']

# Hand rule and layout constants = PipelineLineAssembly / PipelineTuning defaults.
GAP, OVERLAP, RATIO, ASPECT, NEST, B_IN, B_OUT, B_FLOOR, TEXT_FLOOR = 1.5, 0.6, 1.8, 1.25, 0.5, 0.5, 0.15, 0.40, 0.3
RELAX = dict(ratio=5.0, gap=3.0, co=0.3, nest=1.0, aspect=4.0)  # candidate gate (gateRatio ... gateAspect)


# ---------------------------------------------------------------- geometry and the assembler (Swift port)

def coverage(b, r):
    w = b[2] - b[0]; h = b[3] - b[1]
    if w <= 0 or h <= 0: return 0.0
    iw = max(0, min(b[2], r[2]) - max(b[0], r[0])); ih = max(0, min(b[3], r[3]) - max(b[1], r[1]))
    return iw * ih / (w * h)


def owner(b, balloons):
    best, bc = None, 0.0
    for i, r in enumerate(balloons):
        v = coverage(b, r)
        if v > bc: bc, best = v, i
    return best if bc >= B_IN else None


def geom(a, b, vertical):
    """(thinner thickness, thickA, thickB, lenA, lenB, cross overlap, gap) along one axis."""
    if vertical:
        tA, tB, lA, lB = a[2] - a[0], b[2] - b[0], a[3] - a[1], b[3] - b[1]
        co = min(a[2], b[2]) - max(a[0], b[0]); gap = max(a[1], b[1]) - min(a[3], b[3])
    else:
        tA, tB, lA, lB = a[3] - a[1], b[3] - b[1], a[2] - a[0], b[2] - b[0]
        co = min(a[3], b[3]) - max(a[1], b[1]); gap = max(a[0], b[0]) - min(a[2], b[2])
    return min(tA, tB), tA, tB, lA, lB, co, gap


def join_gap(a, b):
    best = None
    for v in (True, False):
        t, tA, tB, lA, lB, co, gap = geom(a, b, v)
        if t <= 0: continue
        if not (lA * ASPECT >= tA and lB * ASPECT >= tB and max(tA, tB) <= RATIO * t
                and co >= OVERLAP * t and gap <= GAP * t and gap >= -NEST * min(lA, lB)):
            continue
        n = max(gap, 0) / t
        if best is None or n < best: best = n
    return best


def layout_allows(oa, ob, a, b, balloons):
    if oa is not None and ob is not None: return oa == ob
    if oa is not None: return coverage(b, balloons[oa]) >= B_OUT
    if ob is not None: return coverage(a, balloons[ob]) >= B_OUT
    return True


def balloons_of(layout):
    return [b for b, k, s in layout if k == 'balloon' and s >= B_FLOOR and b[2] > b[0] and b[3] > b[1]]


def assemble(frags, layout, pair=None):
    """frags: (box, vertical, score). pair(item_i, item_j, ctx) -> priority (lower first) or None; None = hand rule.
    Returns (box, members) per line, the order of PipelineLineAssembly.assemble."""
    n = len(frags)
    if n <= 1: return [(f[0], [i]) for i, f in enumerate(frags)]
    balloons = balloons_of(layout)
    ctx = dict(balloons=balloons, layout=layout)
    items = [dict(box=f[0], mem=[i], own=owner(f[0], balloons), fr=[f]) for i, f in enumerate(frags)]
    alive = [True] * n

    def adm(i, j):
        if pair is not None:
            g = pair(items[i], items[j], ctx)
        else:
            g = join_gap(items[i]['box'], items[j]['box'])
            if g is not None and not layout_allows(items[i]['own'], items[j]['own'], items[i]['box'], items[j]['box'], balloons):
                g = None
        return None if g is None else (g, i, j)
    pairs = [p for i in range(n) for j in range(i + 1, n) for p in [adm(i, j)] if p]
    while pairs:
        g, i, j = min(pairs)
        a, b = items[i], items[j]
        bx = (min(a['box'][0], b['box'][0]), min(a['box'][1], b['box'][1]), max(a['box'][2], b['box'][2]), max(a['box'][3], b['box'][3]))
        items[i] = dict(box=bx, mem=a['mem'] + b['mem'], own=owner(bx, balloons), fr=a['fr'] + b['fr'])
        alive[j] = False
        pairs = [p for p in pairs if p[1] not in (i, j) and p[2] not in (i, j)]
        for o in range(n):
            if alive[o] and o != i:
                p = adm(o, i) if o < i else adm(i, o)
                if p: pairs.append(p)
    return [(it['box'], it['mem']) for k, it in enumerate(items) if alive[k]]


def feats(x, y, ctx):
    """PipelineLineAssembly.features: the 22 features on the gate axis with the smallest normalized gap."""
    a, b = x['box'], y['box']; best = None
    for v in (True, False):
        t, tA, tB, lA, lB, co, gap = geom(a, b, v)
        if t <= 0: continue
        if max(tA, tB) > RELAX['ratio'] * t or co < RELAX['co'] * t or gap > RELAX['gap'] * t or gap < -RELAX['nest'] * min(lA, lB): continue
        if lA * RELAX['aspect'] < tA or lB * RELAX['aspect'] < tB: continue
        n = max(gap, 0) / t
        if best is None or n < best[0]: best = (n, v, t, tA, tB, lA, lB, co, gap)
    if best is None: return None
    n, v, t, tA, tB, lA, lB, co, gap = best
    T = max(tA, tB)
    thin_len, thick_len = (lA, lB) if tA <= tB else (lB, lA)
    ca = ((a[0] + a[2]) if v else (a[1] + a[3])) / 2; cb = ((b[0] + b[2]) if v else (b[1] + b[3])) / 2
    flags = [f[1] == v for f in x['fr'] + y['fr']]
    sc = [f[2] for f in x['fr'] + y['fr']]
    oa, ob = x['own'], y['own']; bl = ctx['balloons']
    rel = 0 if (oa is None and ob is None) else (1 if oa == ob else (3 if (oa is not None and ob is not None) else 2))
    lay_ok = layout_allows(oa, ob, a, b, bl)
    texts = ctx.setdefault('text', [r for r, k, s in ctx['layout'] if k == 'text' and s >= TEXT_FLOOR])
    tshare = max([min(coverage(a, r), coverage(b, r)) for r in texts], default=0)
    base_ok = join_gap(a, b) is not None and lay_ok
    u = (min(a[0], b[0]), min(a[1], b[1]), max(a[2], b[2]), max(a[3], b[3]))
    ul = (u[3] - u[1]) if v else (u[2] - u[0]); ut = (u[2] - u[0]) if v else (u[3] - u[1])
    return [v, T / t, gap / t, co / t, co / T, abs(ca - cb) / t, thin_len / t, thick_len / T, thin_len / T,
            min(lA / tA, lB / tB), max(lA / tA, lB / tB), float(np.mean(flags)), min(sc), max(sc), rel, lay_ok, tshare,
            base_ok, len(x['fr']) + len(y['fr']), ul / ut, gap / T, -gap / max(1e-9, min(lA, lB))]


def probability(model, f):
    """Same summation order as the Swift `probability`."""
    z = 0.0
    for x, m, s, w in zip(f, model['mean'], model['scale'], model['weights']): z += (float(x) - m) / s * w
    z += model['bias']
    return 1 / (1 + math.exp(-z))


def method(model):
    thr = model['threshold']

    def pair(x, y, ctx):
        f = feats(x, y, ctx)
        if f is None: return None
        p = probability(model, f)
        return None if p < thr else 1 - p
    return lambda frags, layout: assemble(frags, layout, pair=pair)


# ---------------------------------------------------------------- data

def box(b):
    (x, y), (w, h) = b; return (x, y, x + w, y + h)


def load(prefix):
    """page_id -> dict(fold, split, size, gt, det, layout), manifest order. fold: f2/f3/f4, dev or test."""
    prefix = Path(prefix)
    man = json.load(open(MANIFEST))['pages']
    lines = collections.defaultdict(dict)
    for r in json.load(open(GT))['records']:
        if r.get('status') == 'canonical' and r['scope'] == 'individual_premerge_bbox':
            p = r['label']['polygon']; xs = [q['x'] for q in p]; ys = [q['y'] for q in p]
            lines[r['page_id']][r['entity_id']] = (min(xs), min(ys), max(xs), max(ys))
    D = {}
    for p in man:
        pid, sp = p['page_id'], p['split']
        fn = prefix.parent / f'{prefix.name}_{sp}' / 'stages' / f'{pid}.front.json'
        if not fn.exists(): continue
        d = json.load(open(fn))
        D[pid] = dict(fold=sp if sp in ('dev', 'test') else f"f{p['fold']}", split=sp, size=(p['width'], p['height']),
                      gt=[b for _, b in sorted(lines.get(pid, {}).items())],
                      det=[(box(l['bounds']), l['vertical'], l['detectionScore']) for l in d['detected']],
                      layout=[(box(l['bounds']), l['kind'], l['score']) for l in d['layout']])
    return D


def assign(frags, gt):
    """Fragment -> index of the GT line covering >= 0.5 of it (the most), else None."""
    out = []
    for f in frags:
        best, bv = None, 0.5
        for k, g in enumerate(gt):
            v = coverage(f[0], g)
            if v >= bv: best, bv = k, v
        out.append(best)
    return out


def gt_fragments(d):
    """Synthetic input: each GT line cut along its long axis where the detector fragments inside it fall."""
    gt, fr = d['gt'], d['det']; a = assign(fr, gt); out = []
    for k, g in enumerate(gt):
        v = (g[3] - g[1]) >= (g[2] - g[0])
        mine = [fr[i] for i in range(len(fr)) if a[i] == k]
        if len(mine) <= 1:
            out.append((g, v, mine[0][2] if mine else 1.0)); continue
        for b, _, s in mine:
            p = (g[0], max(g[1], b[1]), g[2], min(g[3], b[3])) if v else (max(g[0], b[0]), g[1], min(g[2], b[2]), g[3])
            if p[2] > p[0] and p[3] > p[1]: out.append((p, v, s))
    return out


def frags_for(d, inp):
    if inp == 'det': return d['det']
    if inp == 'gtlines': return [(g, (g[3] - g[1]) >= (g[2] - g[0]), 1.0) for g in d['gt']]
    return gt_fragments(d)


def page_pairs(pid, d, a, X, Y, P):
    """Candidate pairs of one page over its three states; a = the fragment -> GT line assignment (labels)."""
    fr = d['det']; bl = balloons_of(d['layout'])
    ctx = dict(balloons=bl, layout=d['layout'])
    og = collections.defaultdict(list)
    for i, k in enumerate(a): og[('g', k) if k is not None else ('n', i)].append(i)
    states = [[[i] for i in range(len(fr))], list(og.values()), [o[1] for o in assemble(fr, d['layout'])]]
    seen = set()
    for groups in states:
        it = []
        for mem in groups:
            bs = [fr[i][0] for i in mem]
            bx = (min(q[0] for q in bs), min(q[1] for q in bs), max(q[2] for q in bs), max(q[3] for q in bs))
            it.append(dict(box=bx, mem=list(mem), fr=[fr[i] for i in mem], own=owner(bx, bl)))
        for i in range(len(it)):
            for j in range(i + 1, len(it)):
                key = (tuple(sorted(it[i]['mem'])), tuple(sorted(it[j]['mem'])))
                if key in seen: continue
                seen.add(key)
                f = feats(it[i], it[j], ctx)
                if f is None: continue
                la = set(a[m] for m in it[i]['mem']); lb = set(a[m] for m in it[j]['mem'])
                if la == {None} and lb == {None}: continue
                X.append(f); Y.append(1 if (len(la) == 1 and la == lb) else 0); P.append(pid)


def pairs_dataset(D, extra=()):
    """Rows (features, label, page_id) over the three page states. extra: augmentation pages (pid, d, assignment),
    appended after the real pages; they keep their page id, so the group folds keep all copies of a page together."""
    X, Y, P = [], [], []
    for pid, d in D.items():
        page_pairs(pid, d, assign(d['det'], d['gt']), X, Y, P)
    for pid, d, a in extra:
        page_pairs(pid, d, a, X, Y, P)
    return np.array(X, float), np.array(Y), np.array(P)


# ---------------------------------------------------------------- augmentation (--augment)

def parse_augment(spec):
    """'mix=RUN,RUN;jitter=SCALExN[;res=frag|RUN][;seed=N]' (parts separated by ';' or spaces)."""
    out = dict(mix=[], scale=0.0, copies=0, res=None, seed=1000)
    for part in re.split(r'[; ]+', (spec or '').strip()):
        if not part: continue
        k, v = part.split('=', 1)
        if k == 'mix': out['mix'] = [x for x in v.split(',') if x]
        elif k == 'jitter': sc, n = v.split('x'); out['scale'], out['copies'] = float(sc), int(n)
        elif k == 'res': out['res'] = v
        elif k == 'seed': out['seed'] = int(v)
        else: raise SystemExit(f'--augment: unknown part {part!r}')
    return out


def run_prefix(p):
    """An absolute or existing relative prefix as given, else a name under RUNS (e.g. speed2/asm830)."""
    p = Path(p)
    return p if p.is_absolute() or Path(f'{p}_train').is_dir() else RUNS / p


def frag_residuals(D, train):
    """Detector-fragment edge error: AUG.edge_offsets of every fragment that alone covers a GT line with IoU >= 0.5
    (one fragment = one line, so all four edges are comparable with the S3 model's)."""
    out = {'v': [], 'h': []}
    for p in train:
        d = D[p]; a = assign(d['det'], d['gt']); n = collections.Counter(a)
        for (b, v, _), k in zip(d['det'], a):
            if k is not None and n[k] == 1 and iou(b, d['gt'][k]) >= 0.5:
                out['v' if v else 'h'].append(AUG.edge_offsets(b, v, d['gt'][k]))
    return {k: np.clip(np.array(v, float).reshape(-1, 4), -1.5, 1.5) for k, v in out.items()}


def jitter_det(d, J):
    return dict(d, det=[(J.box(b, bool(v)), v, s) for b, v, s in d['det']])


def augment_pages(D, train, prefix, aug, log=print):
    """Extra train pages (pid, d, assignment): mix-run pages whose detector fragments differ from the primary's, then
    `copies` jittered copies of every distinct train page (fixed seeds). Labels = the original fragments' GT lines."""
    extra = []; seen = {(p, repr(D[p]['det'])) for p in train}
    for run in aug['mix']:
        if run_prefix(run) == run_prefix(prefix): continue
        E = load(run_prefix(run)); add = 0
        for p, d in E.items():
            if d['split'] == 'train' and (p, repr(d['det'])) not in seen:
                seen.add((p, repr(d['det']))); extra.append((p, d, assign(d['det'], d['gt']))); add += 1
        log(f'augment mix {run}: {add} train pages with different detector fragments added')
    if aug['copies']:
        res = frag_residuals(D, train) if aug['res'] == 'frag' else AUG.residuals(str(run_prefix(aug['res'] or prefix)))
        src = [(p, D[p], assign(D[p]['det'], D[p]['gt'])) for p in train] + list(extra)
        for k in range(aug['copies']):
            J = AUG.Jitter(res, aug['scale'], seed=aug['seed'] + k)
            extra += [(p, jitter_det(d, J), a) for p, d, a in src]
        log(f"augment jitter {aug['scale']} x {aug['copies']} (res {aug['res'] or prefix}): {len(extra)} extra pages")
    return extra


def fit(X, Y):
    # Column-major like the experiment's X[:, cols]: the lbfgs sums then match bit for bit.
    X = np.asfortranarray(X)
    s = StandardScaler().fit(X)
    lr = LogisticRegression(C=1.0, max_iter=5000).fit(s.transform(X), Y)
    return dict(features=FEATURES, threshold=THRESHOLD, mean=s.mean_.tolist(), scale=s.scale_.tolist(),
                weights=lr.coef_[0].tolist(), bias=float(lr.intercept_[0]))


# ---------------------------------------------------------------- metric

def iou(a, b):
    iw = max(0, min(a[2], b[2]) - max(a[0], b[0])); ih = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    i = iw * ih; u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i
    return i / u if u > 0 else 0.0


def page_metrics(lines, gt):
    c = collections.Counter(); c['gt'] = len(gt)
    for g in gt:
        c['ex50'] += max([iou(l, g) for l in lines], default=0) >= 0.5
        c['split'] += sum(coverage(l, g) >= 0.5 for l in lines) > 1
    for l in lines:
        c['over'] += sum(coverage(g, l) >= 0.5 for g in gt) > 1
    c['pages'] = 1
    c['page_ok'] = int(c['ex50'] == len(gt) and c['over'] == 0)
    return c


def evaluate(pages, run, inp):
    c = collections.Counter()
    for d in pages: c += page_metrics([o[0] for o in run(frags_for(d, inp), d['layout'])], d['gt'])
    return c


def err(c): return c['split'] + c['over'] + (c['gt'] - c['ex50'])


def fmt(c):
    return f"err {err(c)} ex50 {c['ex50'] / max(1, c['gt']):.4f} split {c['split'] / max(1, c['gt']):.4f} over {c['over']} page {c['page_ok']}/{c['pages']}"


def group_schemes(D, train):
    """page folds, size groups (W x H, 3 page-count balanced groups), chunk groups (3 runs of sorted page_id)."""
    ids = sorted(train)
    n = collections.Counter(D[p]['size'] for p in ids); load_ = {g: 0 for g in ('g1', 'g2', 'g3')}; of = {}
    for s, k in sorted(n.items(), key=lambda kv: -kv[1]):
        g = min(load_, key=load_.get); of[s] = g; load_[g] += k
    return dict(page={p: D[p]['fold'] for p in ids}, size={p: of[D[p]['size']] for p in ids},
                chunk={p: ('g1', 'g2', 'g3')[min(2, 3 * i // len(ids))] for i, p in enumerate(ids)})


def run_eval(D, train, X, Y, P, model):
    """Rows of augmentation pages share their page's group, so `rowg != hold` drops them with the page."""
    INP = ('det', 'gtfrag', 'gtlines')
    for scheme, g in group_schemes(D, train).items():
        rowg = np.array([g[p] for p in P]); tot = {i: collections.Counter() for i in INP}
        for hold in sorted(set(g.values())):
            m = method(fit(X[rowg != hold], Y[rowg != hold]))
            H = [D[p] for p in train if g[p] == hold]
            for i in INP: tot[i] += evaluate(H, m, i)
        print(f'train LOFO {scheme:5s}', ' | '.join(f'{i} {fmt(c)}' for i, c in tot.items()))
    m = method(model)
    for sp in ('dev', 'test'):
        S = [d for d in D.values() if d['split'] == sp]
        print(f'{sp:16s}', ' | '.join(f'{i} {fmt(evaluate(S, m, i))}' for i in INP))


# ---------------------------------------------------------------- main

def write(model, path):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(model, indent=1) + '\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run_prefix'); ap.add_argument('--out', default=str(REPO / RESOURCE))
    ap.add_argument('--check', action='store_true'); ap.add_argument('--eval', action='store_true')
    ap.add_argument('--augment', default=None, help="off by default; e.g. 'jitter=1.0x2', 'mix=speed2/asm830,speed2/all830'")
    a = ap.parse_args(); t0 = time.time()
    D = load(run_prefix(a.run_prefix))
    train = [p for p, d in D.items() if d['split'] == 'train']
    extra = augment_pages(D, train, a.run_prefix, parse_augment(a.augment)) if a.augment else ()
    X, Y, P = pairs_dataset({p: D[p] for p in train}, extra)
    print('pages', collections.Counter(d['split'] for d in D.values()), 'pairs', len(Y), 'positive', int(Y.sum()))
    model = fit(X, Y)
    if a.check:
        with tempfile.NamedTemporaryFile('w', suffix='.json', dir=data('retrain', 'assembly', 'x').parent, delete=False) as f:
            tmp = f.name
        write(model, tmp); new = json.load(open(tmp)); cur = json.load(open(REPO / RESOURCE))
        keys = ('mean', 'scale', 'weights')
        diff = max([abs(x - y) for k in keys for x, y in zip(new[k], cur[k])] + [abs(new['bias'] - cur['bias'])])
        same = all(new[k] == cur[k] for k in keys + ('bias', 'threshold', 'features'))
        print('resource', 'identical' if same else f'max abs diff {diff:.3g}')
        pn = np.array([probability(new, f) >= new['threshold'] for f in X]); pc = np.array([probability(cur, f) >= cur['threshold'] for f in X])
        print(f'pair decisions agree {int((pn == pc).sum())}/{len(pn)}')
        mn, mc = method(new), method(cur); agree = 0
        for d in D.values(): agree += [o[0] for o in mn(d['det'], d['layout'])] == [o[0] for o in mc(d['det'], d['layout'])]
        print(f'pages with identical assembly {agree}/{len(D)}')
        Path(tmp).unlink()
    else:
        write(model, a.out); print('wrote', a.out)
    if a.eval: run_eval(D, train, X, Y, P, model)
    print(f'{time.time() - t0:.0f}s')


if __name__ == '__main__':
    main()
