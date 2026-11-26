"""Augmentation round for S4b interior (AUGMENT.md): warm the per-run/variant item caches (`--build`) and compare the
variants (default): train LOFO accuracy on the eval run, cross-run LOFO, fit stability, dev/test for base vs one
chosen variant (`--final SPEC`). Numbers only. Scratch under workspace.data('retrain', 'interior', 'aug').

python augeval.py --build            # all caches, one after another (~12 min per full run, ~8 per jitter copy)
python augeval.py [--final SPEC]     # the tables; --write SPEC writes that variant's resource into the aug folder
"""
import argparse, json, sys, time
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import train as T  # noqa: E402
import workspace  # noqa: E402
import gt as G, features as F  # noqa: E402

EVAL_RUN = 'retune/snap2/ref'
RUNS = ['retune/snap2/ref', 'speed2/all830', 'speed2/base830']
SHORT = {'retune/snap2/ref': 'snap2', 'speed2/all830': 'all830', 'speed2/base830': 'base830'}
RDIR = T.SCRATCH / 'cgraw'
OUT = workspace.data('retrain', 'interior', 'aug', 'x').parent
P = lambda n: str(workspace.RUNS / n)


def build_all():
    t0 = time.time()
    for n in RUNS[:2]:
        T.build(P(n), RDIR, False); print('built', n, '%.0fs' % (time.time() - t0), flush=True)
    for s in (0.5, 1.0):
        for n in RUNS[:2]:
            T.build(P(n), RDIR, False, (s, 0)); print('built', n, 'jitter', s, '%.0fs' % (time.time() - t0), flush=True)
    T.build(P(RUNS[2]), RDIR, False); print('built', RUNS[2], '%.0fs' % (time.time() - t0), flush=True)


if __name__ == '__main__' and '--build' in sys.argv:
    build_all(); sys.exit()


# --- data ----------------------------------------------------------------------------------------------------------

_cache = {}


def rows_of(n, jit=None):
    k = (n, jit)
    if k not in _cache:
        rs = T.build(P(n), RDIR, False, jit)
        if jit is not None:
            rs = [dict(r, boxes={}) for r in rs]
        _cache[k] = rs
    return _cache[k]


def train_rows(n):
    return [r for r in rows_of(n) if r['split'] == 'train']


MIX2 = ['retune/snap2/ref', 'speed2/all830']
MIX3 = MIX2 + ['speed2/base830']
# variant -> (mix runs, jitter scale or None)
VARIANTS = {
    'base': ([], None),
    'mix': (MIX2, None),
    'mix3': (MIX3, None),
    'j0.5': ([], 0.5),
    'j1.0': ([], 1.0),
    'mix+j0.5': (MIX2, 0.5),
    'mix+j1.0': (MIX2, 1.0),
}
NEEDS_JIT_ALL = {'snap2', 'all830'}


def extra_rows(variant, primary):
    """Fit-only rows added to the primary run's train rows (augment_rows semantics: mixed runs' train rows plus one
    jittered copy of the primary and of each mixed run)."""
    mix, s = VARIANTS[variant]
    mix = [m for m in mix if m != primary]
    ex = [r for m in mix for r in train_rows(m)]
    if s is not None:
        ex += [r for src in [primary] + mix for r in rows_of(src, (s, 0))]
    return ex


# --- LOFO with several held sets --------------------------------------------------------------------------------

_folds = {}


def folds(scheme):
    """One fixed page -> fold map per scheme over the union of the RUNS' train pages (same for every variant, fit run
    and held run; the runs differ by a few pages that have items)."""
    if scheme not in _folds:
        _folds[scheme] = T.group_of([r for n in RUNS for r in train_rows(n)], scheme)
    return _folds[scheme]


def oof(primary, extra, scheme, held_runs):
    """Fold fits on primary+extra train rows; -> {run: [(pb, joint box)]} aligned with train_rows(run)."""
    tr = train_rows(primary)
    gm = folds(scheme)
    out = {h: [None] * len(train_rows(h)) for h in held_runs}
    for f in sorted(set(gm.values())):
        jm, gate = T.fit([r for r in tr + extra if gm[r['page']] != f])
        for h in held_runs:
            idx = [i for i, r in enumerate(train_rows(h)) if gm[r['page']] == f]
            held = [train_rows(h)[i] for i in idx]
            if not held:
                continue
            pb = gate.predict_proba(np.array([F.gate_x(r) for r in held]))[:, 1]
            off = jm.predict(np.array([F.joint_x(r, q) for r in held for q in range(4)])).reshape(-1, 4)
            for i, r, v, o in zip(idx, held, pb, off):
                out[h][i] = (float(v), F.box_from(r, list(o)))
    return out


def apply_pred(rs, pred, th):
    for r, (pb, box) in zip(rs, pred):
        r['boxes']['R4'] = box if pb >= th else r['boxes']['app']


def pick_th(rs, pred):
    best = None
    for th in T.GRID:
        apply_pred(rs, pred, th); a = G.metrics(rs, 'R4')
        if a['free_s50'] <= T.CAP and (best is None or a['iou'] > best[1]):
            best = (float(th), a['iou'])
    return best[0]


def fmt(a):
    return 'iou %.4f over5 %.4f free_s50 %.4f font_s50 %.4f' % (a['iou'], a['over5'], a['free_s50'], a['font_s50'])


def lofo_tables(variants, res):
    for v in variants:
        prims = ['retune/snap2/ref', 'speed2/all830'] + (['speed2/base830'] if VARIANTS[v][1] is None else [])
        for p in prims:
            ex = extra_rows(v, p)
            for scheme in ('page', 'size', 'chunk'):
                t0 = time.time()
                pred = oof(p, ex, scheme, RUNS)
                th = pick_th(train_rows(p), pred[p])
                for h in RUNS:
                    apply_pred(train_rows(h), pred[h], th); a = G.metrics(train_rows(h), 'R4')
                    res.append(dict(variant=v, fit=SHORT[p], scheme=scheme, held=SHORT[h], th=th, **a))
                    print('%-9s fit %-7s %-5s th %.2f -> %-7s %s' % (v, SHORT[p], scheme, th, SHORT[h], fmt(a)), flush=True)
                print('  (%.0fs, extra %d)' % (time.time() - t0, len(ex)), flush=True)


# --- stability -----------------------------------------------------------------------------------------------------

def full_fit(variant, primary):
    model, _ = T.train(rows_of(primary), extra_rows(variant, primary))
    return model


def iou(a, b):
    i = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - i
    return i / u if u > 0 else 1.0


def raw_offsets(model, rs):
    return T.forest(model['joint']['trees'], [F.joint_x(r, q) for r in rs for q in range(4)]).reshape(-1, 4)


def stability(variants, res):
    for v in variants:
        ma, mb = full_fit(v, 'speed2/all830'), full_fit(v, 'retune/snap2/ref')
        json.dump(dict(all830=ma, snap2=mb), open(OUT / f'stab-{v}.json', 'w'), separators=(',', ':'))
        for h in ('retune/snap2/ref', 'speed2/all830'):
            rs = [r for r in rows_of(h)]   # all splits: a fixed eval set, no fitting on it
            pa, pb = T.predict(ma, rs), T.predict(mb, rs)
            gate = np.mean([(x[0] >= ma['threshold']) == (y[0] >= mb['threshold']) for x, y in zip(pa, pb)])
            same = np.mean([x[1] == y[1] for x, y in zip(pa, pb)])
            mi = np.mean([iou(x[1], y[1]) for x, y in zip(pa, pb)])
            pd = np.mean([abs(x[0] - y[0]) for x, y in zip(pa, pb)])
            od = np.abs(raw_offsets(ma, rs) - raw_offsets(mb, rs)).mean()
            d = dict(variant=v, on=SHORT[h], th_all830=ma['threshold'], th_snap2=mb['threshold'], gate_agree=float(gate),
                     box_same=float(same), box_iou=float(mi), prob_diff=float(pd), offset_diff_em=float(od))
            res.append(d)
            print('%-9s on %-6s th %.2f/%.2f gate agree %.4f box same %.4f box iou %.4f |dp| %.4f |doff| %.4f em' % (
                v, SHORT[h], ma['threshold'], mb['threshold'], gate, same, mi, pd, od), flush=True)


def final(variant):
    for v in dict.fromkeys(['base', variant]):
        model = full_fit(v, EVAL_RUN)
        for split in ('dev', 'test'):
            rs = [r for r in rows_of(EVAL_RUN) if r['split'] == split]
            for r, (_, box) in zip(rs, T.predict(model, rs)):
                r['boxes']['R4'] = box
            print('%-9s %-4s th %.2f app  %s' % (v, split, model['threshold'], fmt(G.metrics(rs, 'app'))))
            print('%-9s %-4s th %.2f R4   %s' % (v, split, model['threshold'], fmt(G.metrics(rs, 'R4'))), flush=True)


def spec_of(v):
    mix, s = VARIANTS[v]
    parts = (['mix=' + '+'.join(m for m in mix if m != EVAL_RUN)] if mix else []) + ([f'jitter={s:g}x1'] if s else [])
    return ';'.join(parts)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--variants', default=','.join(VARIANTS))
    ap.add_argument('--skip-lofo', action='store_true'); ap.add_argument('--skip-stab', action='store_true')
    ap.add_argument('--final', default=None); ap.add_argument('--write', default=None)
    a = ap.parse_args()
    t0 = time.time(); vs = a.variants.split(',')
    res = []
    if not a.skip_lofo:
        lofo_tables(vs, res); json.dump(res, open(OUT / 'lofo.json', 'w'), indent=0)
    res = []
    if not a.skip_stab:
        stability(vs, res); json.dump(res, open(OUT / 'stability.json', 'w'), indent=0)
    if a.final:
        final(a.final)
    if a.write:
        model = full_fit(a.write, EVAL_RUN)
        out = OUT / 'PipelineInterior.json'
        json.dump(model, open(out, 'w'), separators=(',', ':'))
        print('wrote', out, 'spec', spec_of(a.write), 'threshold %.2f' % model['threshold'])
    print('done %.0fs' % (time.time() - t0))


if __name__ == '__main__':
    main()
