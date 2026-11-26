"""Augmentation study for the S2b joiner (port-eval/stageopt/AUGMENT.md). Numbers only.

  aug_eval.py [--final VARIANT]    (run with workspace.PYTHON)

The joiner's input (front.detected, S2 detector fragments) is checked across the real runs first: it is the same in
asm830, det830, loose830 (detectionBoxThreshold 0.05 changes nothing: every DB box already scores >= 0.40 > 0.25),
all830 and retune/snap2/ref; base830 has no `detected`. So `mix` adds no row and the cross-run fits are the same fit.
What can vary is the detector geometry itself, which the jitter variants simulate.

Per variant, train only (THRESHOLD 0.4 is fixed by the method):
  acc    err = split + over + missed ex50 on held-out train pages, page/size/chunk LOFO, detector input
  jit    the fold models on jittered copies of the held-out pages (seed 777, scale 1.0): S3 error model and the
         detector-fragment error model (labels follow the jittered fragments)
  stab   the variant fit on the run vs on a simulated upstream shift (fragments jittered once, seed 4242, S3 model):
         max |standardised weight| move, pair-decision agreement (all clean candidate pairs of the 830 pages) and
         pages with an identical assembly (830 pages)
"""
import argparse, collections, json, sys, time
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import train as T  # noqa: E402

RUN = 'speed2/asm830'
CROSS = ('retune/snap2/ref', 'speed2/all830', 'speed2/det830', 'speed2/loose830', 'speed2/base830')
VARIANTS = {
    'base': '',
    'mix': 'mix=retune/snap2/ref,speed2/all830,speed2/loose830',
    'jit0.5x2': 'jitter=0.5x2',
    'jit1.0x2': 'jitter=1.0x2',
    'jit1.0x4': 'jitter=1.0x4',
    'mix+jit1.0x2': 'mix=retune/snap2/ref,speed2/all830,speed2/loose830;jitter=1.0x2',
    'fragjit1.0x2': 'jitter=1.0x2;res=frag',
}
OUT = T.data('retrain', 'assembly', 'aug', 'x').parent
quiet = lambda *a, **k: None


def jittered(D, pids, res, seed):
    J = T.AUG.Jitter(res, 1.0, seed=seed)
    return {p: T.jitter_det(D[p], J) for p in pids}


def lofo(D, train, X, Y, P, evalsets):
    out = {}
    for scheme, g in T.group_schemes(D, train).items():
        rowg = np.array([g[p] for p in P]); tot = {k: collections.Counter() for k in ('det',) + tuple(evalsets)}
        for hold in sorted(set(g.values())):
            m = T.method(T.fit(X[rowg != hold], Y[rowg != hold]))
            H = [p for p in train if g[p] == hold]
            tot['det'] += T.evaluate([D[p] for p in H], m, 'det')
            for k, es in evalsets.items():
                tot[k] += T.evaluate([es[p] for p in H], m, 'det')
        out[scheme] = tot
    return out


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--final', default=None); ap.add_argument('--only', default=None)
    a = ap.parse_args(); t0 = time.time()
    D = T.load(T.run_prefix(RUN)); train = [p for p, d in D.items() if d['split'] == 'train']
    for r in CROSS:
        try:
            E = T.load(T.run_prefix(r))
        except KeyError:
            print(f'detector fragments {r:18} not saved (no front.detected)'); continue
        same = sum(1 for p in D if p in E and E[p]['det'] == D[p]['det']); has = sum(1 for p in E if E[p]['det'])
        print(f'detector fragments {r:18} identical pages {same}/{len(D)} (pages with fragments {has})')
    s3 = T.AUG.residuals(str(T.run_prefix(RUN))); fr = T.frag_residuals(D, train)
    print('S3 error model  ', T.AUG.summary(s3)); print('fragment model  ', T.AUG.summary(fr))
    evalsets = dict(jitS3=jittered(D, train, s3, 777), jitfrag=jittered(D, train, fr, 777))
    shift = {p: dict(d) for p, d in D.items()}; shift.update(jittered(D, train, s3, 4242))
    Xc, Yc, Pc = T.pairs_dataset(D)  # fixed eval set: clean candidate pairs of every page (no labels used)
    names = a.only.split(',') if a.only else list(VARIANTS)
    for vn in names:
        spec = VARIANTS[vn]; t1 = time.time(); fits = {}
        for prim, DD in (('run', D), ('shift', shift)):
            aug = T.parse_augment(spec) if spec else None
            if aug and aug['res'] is None: aug['res'] = RUN
            extra = T.augment_pages(DD, train, RUN if prim == 'run' else 'sim-shift', aug, log=quiet) if aug else ()
            X, Y, P = T.pairs_dataset({p: DD[p] for p in train}, extra)
            fits[prim] = T.fit(X, Y)
            if prim == 'run':
                L = lofo(D, train, X, Y, P, evalsets); nrows = len(Y)
        ma, mb = fits['run'], fits['shift']
        dw = max(abs(x - y) for x, y in zip(ma['weights'], mb['weights']))
        pa = np.array([T.probability(ma, f) >= 0.4 for f in Xc]); pb = np.array([T.probability(mb, f) >= 0.4 for f in Xc])
        A_, B_ = T.method(ma), T.method(mb)
        same = sum([o[0] for o in A_(d['det'], d['layout'])] == [o[0] for o in B_(d['det'], d['layout'])] for d in D.values())
        e = lambda k: '/'.join(str(T.err(L[s][k])) for s in ('page', 'size', 'chunk'))
        print(f"{vn:13} rows {nrows:5} | acc err {e('det')} | jitS3 err {e('jitS3')} | jitfrag err {e('jitfrag')} | "
              f"stab dW {dw:.3f} pairs agree {(pa == pb).mean():.5f} ({int((pa != pb).sum())}) pages same {same}/{len(D)} | "
              f"{time.time() - t1:.0f}s", flush=True)
        json.dump(dict(spec=spec, rows=nrows, lofo={s: {k: dict(c) for k, c in L[s].items()} for s in L},
                       stab=dict(dW=dw, pair_agree=float((pa == pb).mean()), pages_same=same)),
                  open(OUT / f'eval-{vn}.json', 'w'), indent=1, default=int)
        T.write(ma, OUT / f'PipelineLineJoin.{vn}.json')
    if a.final:
        for vn in ('base', a.final):
            m = T.method(json.load(open(OUT / f'PipelineLineJoin.{vn}.json')))
            for sp in ('dev', 'test'):
                ps = [d for d in D.values() if d['split'] == sp]
                pids = [p for p, d in D.items() if d['split'] == sp]
                jS = jittered(D, pids, s3, 777); jF = jittered(D, pids, fr, 777)
                print(f"FINAL {vn:13} {sp:4} | " + ' | '.join(f'{i} {T.fmt(T.evaluate(ps, m, i))}' for i in ('det', 'gtfrag', 'gtlines'))
                      + f" | jitS3 {T.fmt(T.evaluate(list(jS.values()), m, 'det'))} | jitfrag {T.fmt(T.evaluate(list(jF.values()), m, 'det'))}")
    print(f'{time.time() - t0:.0f} s')


if __name__ == '__main__':
    main()
