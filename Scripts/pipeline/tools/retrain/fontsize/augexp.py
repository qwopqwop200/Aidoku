"""Augmentation experiment for the S8 font-size fit (port-eval/stageopt/AUGMENT.md). Numbers only.

  accuracy : train LOFO page/size/chunk on the eval run (fit on the variant's pages outside the held-out group)
  cross-run: fit on run A's (augmented) train pages outside a page fold, score run B's train pages of that fold
  stability: fit on all830 and on snap2/ref with the same variant (all train); parameter moves and the decision
             agreement of the two fits on every block of the eval run (all splits)
  dev/test : base and the chosen variant only (--final)

usage: augexp.py [--final SPEC]
"""
import argparse, json, math, sys, time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import train as T  # noqa: E402
import augment  # noqa: E402  (train put retrain/ on the path)

EVAL_RUN = 'retune/snap2/ref'
RUNS = ['speed2/all830', 'retune/snap2/ref', 'speed2/base830']
VARIANTS = {
    'base': dict(mix=[], jitter=(0.0, 0)),
    'mix': dict(mix=RUNS, jitter=(0.0, 0)),
    'jit0.5x2': dict(mix=[], jitter=(0.5, 2)),
    'jit1.0x2': dict(mix=[], jitter=(1.0, 2)),
    'mix+jit0.5x2': dict(mix=RUNS, jitter=(0.5, 2)),
    'mix+jit1.0x2': dict(mix=RUNS, jitter=(1.0, 2)),
}
STAB_PAIRS = [('speed2/all830', EVAL_RUN), ('speed2/base830', EVAL_RUN), ('speed2/base830', 'speed2/all830')]
_cache = {}


def pages(run, scale=0.0, copy=None):
    """Train pages of a run (copy None) or one jittered copy; prepared; memoized."""
    key = (run, scale, copy)
    if key not in _cache:
        prefix = str(augment.run_path(run))
        if copy is None:
            P = T.load_run(prefix, ('train',))
        else:
            import zlib
            res = augment.residuals(prefix)
            seed = lambda pid: augment.Jitter(res, scale, zlib.crc32(f'{pid}/{copy}'.encode()))
            P = T.load_run(prefix, ('train',), (seed, copy))
        P = [p for p in P if p['split'] == 'train']; T.prepare(P); _cache[key] = P
    return _cache[key]


def fit_set(run, v, exclude=()):
    """Fit pages for variant v anchored on `run`: run + its mix runs (minus `exclude`), each with its jitter copies.
    Same as train.augmented_train."""
    runs = [run] + [r for r in v['mix'] if r != run and r not in exclude]
    scale, n = v['jitter']; out = []
    for r in runs:
        out += pages(r)
        for c in range(n if scale > 0 else 0): out += pages(r, scale, c)
    return out


def lofo(fitp, evalp, scheme, ref):
    of = T.folds(ref, scheme); pr = []
    for h in sorted(set(of.values())):
        m = T.fit([p for p in fitp if of.get(p['page'], h) != h])
        pr += T.predict([p for p in evalp if of.get(p['page']) == h], m)
    return pr


def num(pr):
    p = np.array([r[2] for r in pr]); g = np.array([r[3]['px'] for r in pr]); lo = np.array([r[3]['lo'] for r in pr])
    hi = np.array([r[3]['hi'] for r in pr]); e = np.abs(np.log(p / g))
    return dict(n=len(pr), med=float(np.median(e)), mean=float(e.mean()), inInt=float(((p >= lo - 1e-9) & (p <= hi + 1e-9)).mean()),
                w10=float((np.abs(p / g - 1) <= .1).mean()))


def fmt(d): return f"mean={d['mean']:.4f} med={d['med']:.4f} inInt={d['inInt']:.3f} w10={d['w10']:.3f}"


def model_moves(a, b):
    w = max(abs(x - y) for x, y in zip(a['cellWeights'] + [a['cellOffset']], b['cellWeights'] + [b['cellOffset']]))
    return dict(n0=(a['n0'], b['n0']), maxSpread=(a['maxSpread'], b['maxSpread']), latin=(a['latin'], b['latin']),
                dbias=abs(a['bias'] - b['bias']), dcell=w)


def agreement(ma, mb, blocks):
    pa, pb = T.predict(blocks, ma, True), T.predict(blocks, mb, True)
    e = np.array([abs(math.log(x[2] / y[2])) for x, y in zip(pa, pb)])
    return dict(n=len(e), agree1=float((e < .01).mean()), agree3=float((e < .03).mean()), mean=float(e.mean()), max=float(e.max()))


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--final', default=None); ap.add_argument('--only', default=None)
    a = ap.parse_args(); t0 = time.time()
    evalp = pages(EVAL_RUN)
    full = T.load_run(str(augment.run_path(EVAL_RUN))); T.prepare(full)
    names = a.only.split(',') if a.only else list(VARIANTS)
    out = {}
    for name in names:
        v = VARIANTS[name]; r = out[name] = {}
        fp = fit_set(EVAL_RUN, v)
        m = T.fit(fp); (bl, bp), gap, per = T.grid_margin()
        r['grid'] = dict(best=bp, margin=gap, per_n0=per)
        for s in ('page', 'size', 'chunk'): r[s] = num(lofo(fp, evalp, s, evalp))
        for A, B in [('speed2/all830', EVAL_RUN), (EVAL_RUN, 'speed2/all830'), ('speed2/base830', EVAL_RUN),
                     (EVAL_RUN, 'speed2/base830')]:
            r[f'{A}->{B}'] = num(lofo(fit_set(A, v, exclude=(B,)), pages(B), 'page', pages(B)))
        # stability: two fits on different upstream runs with the same variant; for mix, the pair's runs are left out
        # of each other's fit, so only the third run is shared
        r['stab'] = {}
        for A, B in STAB_PAIRS:
            ma = T.fit(fit_set(A, v, exclude=(B,))); ga = T.grid_margin()
            mb = T.fit(fit_set(B, v, exclude=(A,))); gb = T.grid_margin()
            r['stab'][f'{A}|{B}'] = dict(moves=model_moves(ma, mb), agree=agreement(ma, mb, full), margins=(ga[1], gb[1]))
        r['model'] = {k: m[k] for k in ('n0', 'maxSpread', 'latin', 'bias')}
        print(f'== {name}  ({time.time() - t0:.0f} s)  fit rows {sum(len(p["targets"]) for p in fp)}')
        print(f"  grid best {bp} margin {gap:.2e} per-n0 " + ' '.join(f'{k:g}:{x:+.1e}' for k, x in per.items()))
        for s in ('page', 'size', 'chunk'): print(f'  LOFO {s:5s} {fmt(r[s])}')
        for k in r:
            if '->' in k: print(f'  {k:38s} {fmt(r[k])}')
        for k, st in r['stab'].items():
            ag = st['agree']
            print(f"  stab {k}: {st['moves']} margins {st['margins'][0]:.1e}/{st['margins'][1]:.1e}  "
                  f"agree<1% {ag['agree1']:.4f} <3% {ag['agree3']:.4f} mean|dlog| {ag['mean']:.2e} max {ag['max']:.3f}")
        sys.stdout.flush()
    json.dump(out, open(T.workspace.data(*T.SCRATCH, 'aug', 'augexp.json'), 'w'), indent=1, default=str)
    if a.final:
        for name in ('base', a.final):
            m = T.fit(fit_set(EVAL_RUN, VARIANTS[name]))
            for s in ('dev', 'test'):
                print(f'{name:14s} {s:4s} {T.metrics(T.predict([p for p in full if p["split"] == s], m))}')
    print(f'{time.time() - t0:.0f} s')


if __name__ == '__main__':
    main()
