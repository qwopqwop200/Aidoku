#!/usr/bin/env python3
"""train.py RUN_PREFIX [--out PATH] [--check] [--eval]

S4 paragraph grouping (PipelineParagraphGrouping.swift): fits the learned constants of Resources/Translation/
PipelineGrouping.json on TRAIN pages of a run (front.recognized lines) against the merge GT (unified GT paragraphs
over GT line boxes):
  1. resolver: logistic regression (C 0.3) over 7 standardized pair features, on the resolver-eligible non-core pairs
     of both inputs: the run's lines (weight 1) and the GT line boxes (weight 0.5)
  2. selection (page folds f2/f3/f4 inside the fitted pages, inner out-of-fold resolver scores, exact pages on both
     inputs): joinAbove / cutBelow on the cascade grid, then two coordinate passes over the R2 pitch veto (on/off and
     its ratio, median of ties; on only if it strictly gains), then the thresholds again. R1cf and R4cf are always on.
--check  trains into a temp file and compares it with the current resource (no write)
--eval   exact pages, split / wrong paragraphs and line-pair P/R: train leave-one-fold-out under page, size and chunk
         folds (the whole fit, selection included, on the other two folds), dev and test with the model just fitted; both inputs, and the reviewed
         merge GT (merge_gt_eval) on the app blocks of the run's lines
Python reference for parity: ref.py. Method: port-eval/grouping/featsel (model7), port-eval/stageopt/grouping2 (hyb).
"""
import argparse, collections, json, sys, tempfile, time
from pathlib import Path
import numpy as np
from sklearn.linear_model import LogisticRegression

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s4  # noqa: E402
from s4 import workspace  # noqa: E402

SPEC = dict(
    name='grouping',
    resource=[s4.RESOURCE],
    stage='S4',
    inputs='front.recognized: S3 lines after keep + refine; front.layout: S1 RF regions',
    needs_full=False,
    rerun_from='s4',
    augment='mix=retune/snap2/ref,speed2/all830,speed2/base830',  # proposed default --augment (the lead adopts it)
)
C = 0.3
OTHER_W = 0.5                       # GT-line-box pairs
GRID = [0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
GRID_LO = [0.05, 0.1, 0.2, 0.3, 0.4, 0.5]
PITCH = [1.15, 1.2, 1.25, 1.3, 1.35, 1.4, 1.5]
DEF_PITCH = 1.3
FOLDS = ('f2', 'f3', 'f4')


def units(pages):
    """(probs key, page data, resolver weight) of every training input of `pages`: the run's lines and the GT line
    boxes, then the --augment copies of the run's lines (p['aug'], same page and fold)"""
    for inp, wt in (('det', 1.0), ('gt', OTHER_W)):
        for p in pages: yield (inp, p['page']), p[inp], wt
    for p in pages:
        for tag, d, wt in p.get('aug', ()): yield (tag, p['page']), d, wt


def resolver(pages):
    X, y, w = [], [], []
    for _, d, wt in units(pages):
        D = d['D']; k = D['elig'] & (d['y'] >= 0) & ~D['core']
        X.append(D['X'][k]); y.append(d['y'][k]); w.append(np.full(k.sum(), wt))
    X = np.vstack(X); y = np.concatenate(y); w = np.concatenate(w)
    mu = X.mean(0); sd = X.std(0) + 1e-6
    lr = LogisticRegression(C=C, max_iter=3000).fit((X - mu) / sd, y, sample_weight=w)
    return dict(mean=mu.tolist(), scale=sd.tolist(), weights=lr.coef_[0].tolist(), bias=float(lr.intercept_[0]))


def exact_sum(pages, probs, hi, lo, pitch):
    t = 0
    for key, d, _ in units(pages):
        t += s4.page_exact(d['D']['n'], s4.decide(d['D'], probs[key], hi, lo, pitch), d['ids'], d['para'])
    return t


def choose(pages):
    """joinAbove, cutBelow, pitchRatio (None = R2 off) on inner out-of-fold resolver scores of `pages`"""
    probs = {}
    for f in sorted({p['fold'] for p in pages}):
        m = resolver([p for p in pages if p['fold'] != f])
        for p in pages:
            if p['fold'] == f:
                for key, d, _ in units([p]): probs[key] = s4.proba(m, d['D'])

    def thresholds(pitch):
        cells = [(exact_sum(pages, probs, h, l, pitch), -(abs(h - .7) + abs(l - .3)), h, l)
                 for h in GRID for l in GRID_LO if l <= h]
        return max(cells)[2:]
    pitch = None; hi, lo = thresholds(pitch)
    for _ in range(2):
        base = exact_sum(pages, probs, hi, lo, None)
        sc = [exact_sum(pages, probs, hi, lo, v) for v in PITCH]
        best = max(sc)
        if best > base:
            tied = [v for v, s in zip(PITCH, sc) if s == best]; pitch = tied[len(tied) // 2]
        else:
            pitch = None
        hi, lo = thresholds(pitch)
    return hi, lo, pitch


def fit(pages):
    m = dict(features=s4.FEATURES, **resolver(pages))
    m['joinAbove'], m['cutBelow'], m['pitchRatio'] = choose(pages)
    return m


# ---------------------------------------------------------------- augmentation (--augment SPEC, training only)

def parse_augment(spec):
    """'mix=RUN,RUN;jitter=SCALExK[;w=W]' (';' or spaces between parts) -> dict(mix=[run], scale, k, w).
    mix: train pages of these runs (RUN_PREFIX or a name under workspace RUNS) join the fit as extra copies of the
    run's lines, deduplicated by identical front.recognized; jitter: K copies of every source's lines at SCALE
    (augment.Jitter on that source's own front.recognized residuals); w: resolver weight of a copy (default 1)."""
    out = dict(mix=[], scale=0.0, k=0, w=1.0)
    for part in spec.replace(';', ' ').split():
        key, _, val = part.partition('=')
        if key == 'mix': out['mix'] = [v for v in val.split(',') if v]
        elif key == 'jitter': sc, _, k = val.partition('x'); out['scale'], out['k'] = float(sc), int(k or 1)
        elif key == 'w': out['w'] = float(val)
        else: raise SystemExit(f'--augment: unknown part {part!r}')
    return out


def _det_copy(front, layout, recognized, d2g, gpara):
    """page data of `recognized` lines labelled with a fixed detected -> GT line map (the GT's targets)"""
    det = s4.front_lines(dict(front, recognized=recognized))
    D = s4.page_data(layout, det); ids = [l['id'] for l in det]
    para = {k: gpara[g] for k, g in d2g.items() if g in gpara}
    return dict(D=D, ids=ids, para=para, y=s4.labels(D, ids, para))


def augment(prefix, train, spec):
    """attach p['aug'] = [(tag, page data, weight)] to the train pages (in place); returns a short summary"""
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    import augment as aug
    a = parse_augment(spec)
    bench, _ = s4.gt_pages()
    prim = str(Path(prefix).resolve()); sources = [prim]
    for m in a['mix']:
        src = str(Path(m if Path(m).is_absolute() else aug.run_path(m)).resolve())
        if not Path(f'{src}_train').is_dir(): raise SystemExit(f'--augment: no run {m}')
        if src not in sources: sources.append(src)
    res = {s: aug.residuals(s, 'recognized') for s in sources} if a['k'] else {}
    n_mix = n_jit = 0
    for si, src in enumerate(sources):
        jit = [aug.Jitter(res[src], a['scale'], seed=1000 * si + c) for c in range(a['k'])]
        for p in sorted(train, key=lambda q: q['page']):
            if si == 0:
                front = p['front']
            else:
                f = Path(f'{src}_train/stages/{p["page"]}.front.json')
                if not f.exists(): continue
                front = json.load(open(f))
            rec = front.get('recognized') or []
            polys, groups = bench[p['page']]
            known = set(polys)
            gpara = {i: k for k, g in enumerate(k for k in ([i for i in g if i in known] for g in groups) if k) for i in g}
            layout = s4.front_layout(front)
            _, d2g = s4.gt_input(s4.front_lines(front), polys)
            p.setdefault('aug', []); p.setdefault('_seen', [p['front'].get('recognized') or []])
            if si > 0:
                if any(rec == r for r in p['_seen']): continue
                p['_seen'].append(rec)
                p['aug'].append((f'm{si}', _det_copy(front, layout, rec, d2g, gpara), a['w'])); n_mix += 1
            for c, j in enumerate(jit):
                p['aug'].append((f'j{si}.{c}', _det_copy(front, layout, [j.line(l) for l in rec], d2g, gpara), a['w']))
                n_jit += 1
    for p in train: p.pop('_seen', None)
    return f'augment {spec!r}: {len(sources) - 1} mix runs, {n_mix} mix copies, {n_jit} jitter copies'


# ---------------------------------------------------------------- eval

def bench_score(rows):
    """rows: (groups over line ids, GT paragraph map); lines without GT paragraph are ignored"""
    tot = collections.Counter()
    for groups, para in rows:
        grp = {i: k for k, g in enumerate(groups) for i in g}
        ids = [i for i in para if i in grp]
        for a in range(len(ids)):
            for b in range(a + 1, len(ids)):
                sp, sg = grp[ids[a]] == grp[ids[b]], para[ids[a]] == para[ids[b]]
                tot['tp'] += sp and sg; tot['fp'] += sp and not sg; tot['fn'] += sg and not sp
        blocks = collections.defaultdict(set); paras = collections.defaultdict(set)
        for i in ids: blocks[grp[i]].add(para[i]); paras[para[i]].add(grp[i])
        wrong = sum(len(v) > 1 for v in blocks.values()); split = sum(len(v) > 1 for v in paras.values())
        tot['exact'] += wrong == 0 and split == 0; tot['split'] += split; tot['wrong'] += wrong; tot['pages'] += 1
    P = tot['tp'] / max(1, tot['tp'] + tot['fp']); R = tot['tp'] / max(1, tot['tp'] + tot['fn'])
    return dict(pages=tot['pages'], exact=tot['exact'], split=tot['split'], wrong=tot['wrong'], P=P, R=R)


def merge_score(items):
    """reviewed merge GT (merge_gt_eval.score_page) on the app blocks of the run's lines; items: (page, model)"""
    import merge_gt_eval
    _, gt = s4.gt_pages()
    man = {p['page_id']: p for p in json.load(open(workspace.MANIFEST))['pages']}
    rows = []
    for p, model in items:
        if p['page'] not in gt: continue
        rec = p['front'].get('recognized') or []
        blocks = [dict(id=b, lines=[dict(bounds=rec[k]['bounds'], text=rec[k]['text']) for k in g])
                  for b, g in enumerate(s4.app_groups(p['front'], model))]
        mp = man[p['page']]
        rows.append(merge_gt_eval.score_page(dict(width=mp['width'], height=mp['height'], pageID=p['page'], blocks=blocks),
                                             gt[p['page']]))
    return merge_gt_eval.summarize(rows) if rows else None


def show(name, items):
    for inp in ('det', 'gt'):
        s = bench_score([predict(p, inp, m) for p, m in items])
        print(f"  {name:<11} {inp:<5} pages {s['pages']:4} exact {s['exact']:4} split {s['split']:3} wrong {s['wrong']:3} "
              f"line P {s['P']:.4f} R {s['R']:.4f}")
    s = merge_score(items)
    if s:
        print(f"  {name:<11} merge pages {s['pages']:4} exact {s['exact']:4} line P {s['lineP']:.4f} R {s['lineR']:.4f} "
              f"frag {s['frag']} wrong {s['wrong']} missed {s['missed']}")


def predict(p, inp, model):
    d = p[inp]; D = d['D']
    groups = s4.components(D['n'], s4.decide(D, s4.proba(model, D), model['joinAbove'], model['cutBelow'], model['pitchRatio']))
    return [[d['ids'][i] for i in g] for g in groups], d['para']


def schemes(train):
    """train fold per page: page (manifest folds), size (page W x H groups, largest first onto the lightest fold) and
    chunk (contiguous page-id thirds), as port-eval/stageopt (round5)"""
    out = {'page': [p['fold'] for p in train]}
    load = dict.fromkeys(FOLDS, 0); of = {}
    for sz, c in sorted(collections.Counter(p['size'] for p in train).items(), key=lambda kv: -kv[1]):
        f = min(load, key=load.get); of[sz] = f; load[f] += c
    out['size'] = [of[p['size']] for p in train]
    ids = sorted(p['page'] for p in train); k = len(ids)
    rank = {q: FOLDS[min(2, 3 * i // k)] for i, q in enumerate(ids)}
    out['chunk'] = [rank[p['page']] for p in train]
    return out


def evaluate(pages, train, model):
    print('eval (bench = unified-GT paragraphs on det = run lines / gt = GT line boxes; merge = reviewed merge GT, app blocks)')
    for scheme, folds in schemes(train).items():
        tr = [dict(p, fold=f) for p, f in zip(train, folds)]; items = []
        for f in FOLDS:
            m = fit([p for p in tr if p['fold'] != f])
            print(f"  {scheme} LOFO {f}: joinAbove {m['joinAbove']} cutBelow {m['cutBelow']} pitchRatio {m['pitchRatio']}", flush=True)
            items += [(p, m) for p in tr if p['fold'] == f]
        show(f'LOFO {scheme}', items)
    for split in ('dev', 'test'):
        show(split, [(p, model) for p in pages if p['split'] == split])


# ---------------------------------------------------------------- check

def check(prefix, model, current):
    diff = max(abs(a - b) for k in ('mean', 'scale', 'weights') for a, b in zip(model[k], current[k]))
    diff = max(diff, abs(model['bias'] - current['bias']))
    same_keys = all(model[k] == current[k] for k in ('features', 'joinAbove', 'cutBelow', 'pitchRatio'))
    print('check: features/thresholds', 'identical' if same_keys else
          {k: (current[k], model[k]) for k in ('joinAbove', 'cutBelow', 'pitchRatio') if model[k] != current[k]},
          '| max abs diff of resolver constants %.3g' % diff)
    pages = same = pairs = agree = 0
    for split in ('train', 'dev', 'test'):
        for pid, front in s4.fronts(prefix, split):
            pages += 1; same += s4.app_groups(front, model) == s4.app_groups(front, current)
            D = s4.page_data(s4.front_layout(front), s4.front_lines(front))
            if len(D['keys']):
                e = [set(s4.decide(D, s4.proba(m, D), m['joinAbove'], m['cutBelow'], m['pitchRatio'])) for m in (model, current)]
                pairs += len(D['keys']); agree += sum((k in e[0]) == (k in e[1]) for k in D['keys'])
    print(f'check: same groups on {same}/{pages} pages, same join decision on {agree}/{pairs} candidate pairs')


def dump(model, path):
    Path(path).write_text(json.dumps(model, indent=1) + '\n')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run_prefix'); ap.add_argument('--out', default=str(workspace.REPO / s4.RESOURCE))
    ap.add_argument('--check', action='store_true'); ap.add_argument('--eval', action='store_true')
    ap.add_argument('--augment', metavar='SPEC', help="training-data augmentation, off by default: "
                    "'mix=RUN,RUN', 'jitter=SCALExK', both joined by ';' (see parse_augment)")
    a = ap.parse_args()
    t0 = time.time()
    pages = s4.load_run(a.run_prefix)
    train = [p for p in pages if p['split'] == 'train']
    print(f'{len(train)} train pages ({", ".join(f"{f} {sum(p["fold"] == f for p in train)}" for f in FOLDS)}), '
          f'{len(pages) - len(train)} dev/test, loaded in {time.time() - t0:.0f} s', flush=True)
    if a.augment: print(augment(a.run_prefix, train, a.augment), f'({time.time() - t0:.0f} s)', flush=True)
    model = fit(train)
    print(f"fit: joinAbove {model['joinAbove']} cutBelow {model['cutBelow']} pitchRatio {model['pitchRatio']} "
          f"({time.time() - t0:.0f} s)", flush=True)
    if a.check:
        with tempfile.NamedTemporaryFile('w', suffix='.json', delete=False) as f: dump(model, f.name)
        check(a.run_prefix, s4.load_model(f.name), s4.load_model())
    else:
        dump(model, a.out); print('wrote', a.out)
    if a.eval: evaluate(pages, train, model)
    print(f'done in {time.time() - t0:.0f} s')


if __name__ == '__main__':
    main()
