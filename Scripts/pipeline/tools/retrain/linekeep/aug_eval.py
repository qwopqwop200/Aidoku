"""Augmentation study for the line-keep gate (port-eval/stageopt/AUGMENT.md). Numbers only.

  aug_eval.py [--final SPEC]    (run with workspace.PYTHON)

Pre-gate inputs that really vary (S3 lines after the 0.30 cut, before the gate): speed2/asm830 (current S2b, the run
the resource is trained on) and speed2/det830 (old S2b; == base830's lines and == loose830's lines with conf >= 0.30).
speed2/loose830 adds the sub-0.30 lines (recognitionMinimumConfidence 0): an eval-only stress set. all830 and
retune/snap2/ref hold GATED lines (front.unrefined = gate output), so they cannot serve as gate training input.

Per variant (fit and threshold on train only, threshold = min over page/size/chunk of the strict zero-loss value):
  acc    held-out train pages of asm830: extra lost (== 0 by construction), junk kept, nested extra lost
  cross  the fold models of run A scored on the held-out pages of run B at A's threshold (A, B = asm830, det830; B also
         loose830 with every line)
  jit    the fold models scored on jittered copies of the held-out asm830 pages (S3 error model, scale 1.0, seed 777;
         labels and GT coverage follow the jittered boxes): does the gate drop real lines when S3 draws other boxes
  stab   full fits on asm830 vs det830 (and vs a simulated shift: asm830 jittered once, seed 4242) with the same
         variant: threshold move and decision agreement on all asm830 lines (830 pages)
"""
import argparse, collections, json, sys, time
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import train as T  # noqa: E402

A_RUN, B_RUN, LOOSE = 'speed2/asm830', 'speed2/det830', 'speed2/loose830'
VARIANTS = {
    'base': '',
    'mix': f'mix={A_RUN},{B_RUN}',
    'mix+loose': f'mix={A_RUN},{B_RUN},{LOOSE}',
    'jit0.5x2': 'jitter=0.5x2',
    'jit1.0x2': 'jitter=1.0x2',
    'mix+jit0.5x2': f'mix={A_RUN},{B_RUN};jitter=0.5x2',
    'mix+jit1.0x2': f'mix={A_RUN},{B_RUN};jitter=1.0x2',
}
OUT = T.ws.data('retrain', 'linekeep', 'aug', 'x').parent


def quiet(*a, **k):
    pass


def lofo(pages, extra, evalsets):
    """Fold models per scheme; held-out probabilities on the primary train pages and on each eval set (pages keyed
    by page id, held out with the same fold map)."""
    train = [p for p in pages if p['split'] == 'train']
    S = T.schemes(train); held = {}; ev = {k: {} for k in evalsets}
    for name, fmap in S.items():
        probs = {}; e = {k: {} for k in evalsets}
        for g in (2, 3, 4):
            m = T.fit([p for p in train if fmap[p['page']] != g] + [p for p in extra if fmap[p['page']] != g])
            pr = lambda p: m.predict_proba(p['X'])[:, 1] if p['n'] else np.zeros(0)
            for p in train:
                if fmap[p['page']] == g:
                    probs[p['page']] = pr(p)
            for k, es in evalsets.items():
                for p in es:
                    if fmap.get(p['page']) == g:
                        e[k][p['page']] = pr(p)
        held[name] = [probs[p['page']] for p in train]
        for k in evalsets:
            ev[k][name] = e[k]
    per = {n: T.strict(train, held[n]) for n in S}
    return train, S, held, per, min(per.values()), ev


def nested(train, S, held):
    out = {}
    for name in S:
        e = 0
        for g in (2, 3, 4):
            o = [i for i, p in enumerate(train) if S[name][p['page']] != g]
            i_ = [i for i, p in enumerate(train) if S[name][p['page']] == g]
            tg = min(T.strict([train[i] for i in o], [held[q][i] for i in o]) for q in S)
            e += T.score([train[i] for i in i_], [held[name][i] for i in i_], tg)['extra_lost']
        out[name] = e
    return out


def es_score(es, probs, t):
    ps = [p for p in es if p['page'] in probs]
    return T.score(ps, [probs[p['page']] for p in ps], t)


def main():
    ap = argparse.ArgumentParser(); ap.add_argument('--final', default=None, help='variant name: dev/test for base and it')
    ap.add_argument('--only', default=None, help='comma-separated variant names')
    a = ap.parse_args(); t0 = time.time()
    P = {r: T.load(r, raw=True) for r in (A_RUN, B_RUN, LOOSE)}
    res = T.AUG.residuals(str(T.prefix_path(A_RUN)))
    print('S3 error model', T.AUG.summary(res))
    # eval sets (train pages only, never fitted on): the other runs and a jittered copy of the primary
    Jv = T.AUG.Jitter(res, 1.0, seed=777)
    jit_eval = [T.jitter_page(p, Jv, keep_labels=False) for p in P[A_RUN] if p['split'] == 'train']
    # simulated upstream shift for the stability check: asm830 jittered once (seed 4242), labels follow the boxes
    shift = simulated(P[A_RUN], res)
    fixed = np.vstack([p['X'] for p in P[A_RUN] if p['n']])
    trainsets = lambda r: [p for p in P[r] if p['split'] == 'train']
    names = a.only.split(',') if a.only else list(VARIANTS)
    rows = {}
    for vn in names:
        spec = VARIANTS[vn]; aug = T.parse_augment(spec); t1 = time.time()
        if spec and not aug['res']:
            aug['res'] = A_RUN  # one S3 error model for every primary (the asm830 measurement)
        r = {}
        fits = {}
        for prim, pages in ((A_RUN, P[A_RUN]), (B_RUN, P[B_RUN]), ('shift', shift)):
            extra = T.augment_pages(pages, 'sim-shift' if prim == 'shift' else prim, aug, log=quiet) if spec else ()
            evalsets = {}
            if prim == A_RUN:
                evalsets = dict(B=trainsets(B_RUN), loose=trainsets(LOOSE), jit=jit_eval)
            elif prim == B_RUN:
                evalsets = dict(A=trainsets(A_RUN))
            train, S, held, per, tj, ev = lofo(pages, extra, evalsets)
            J = T.export(T.fit(train + list(extra)), tj)
            fits[prim] = J
            if prim == A_RUN:
                r['per'] = per; r['t'] = tj; r['nested'] = nested(train, S, held)
                r['acc'] = {n: T.score(train, held[n], tj) for n in S}
                r['cross_AB'] = {n: es_score(evalsets['B'], ev['B'][n], tj) for n in S}
                r['cross_Aloose'] = {n: es_score(evalsets['loose'], ev['loose'][n], tj) for n in S}
                r['jit'] = {n: es_score(jit_eval, ev['jit'][n], tj) for n in S}
                r['J'] = J
            elif prim == B_RUN:
                r['tB'] = tj
                r['cross_BA'] = {n: es_score(evalsets['A'], ev['A'][n], tj) for n in S}
        for other in (B_RUN, 'shift'):
            pa = T.prob(fits[A_RUN], fixed) >= fits[A_RUN]['threshold']
            pb = T.prob(fits[other], fixed) >= fits[other]['threshold']
            r[f'stab_{other}'] = dict(dt=abs(np.log10(fits[A_RUN]['threshold']) - np.log10(fits[other]['threshold'])),
                                      tA=fits[A_RUN]['threshold'], tO=fits[other]['threshold'],
                                      agree=float((pa == pb).mean()), differ=int((pa != pb).sum()))
        r['time'] = time.time() - t1
        rows[vn] = r
        report(vn, r)
        json.dump(dict(spec=spec, threshold=r['t'], per=r['per'], nested=r['nested'],
                       acc={k: v for k, v in r['acc'].items()}, cross_AB=r['cross_AB'], cross_BA=r['cross_BA'],
                       cross_Aloose=r['cross_Aloose'], jit=r['jit'],
                       stab={k: r[k] for k in r if k.startswith('stab_')}),
                  open(OUT / f'eval-{vn}.json', 'w'), indent=1, default=float)
        T.write(r['J'], OUT / f'PipelineLineKeep.{vn}.json')
    if a.final:
        for vn in ('base', a.final):
            J = json.load(open(OUT / f'PipelineLineKeep.{vn}.json'))
            for run in (A_RUN, B_RUN, LOOSE):
                for sp in ('dev', 'test'):
                    ps = [p for p in P[run] if p['split'] == sp]
                    print(f'FINAL {vn:12} {run:16} {sp:4} t {J["threshold"]:.6f}: {T.fmt(T.score(ps, [T.prob(J, p["X"]) for p in ps], J["threshold"]))}')
            Jd = T.AUG.Jitter(res, 1.0, seed=777)
            for sp in ('dev', 'test'):
                ps = [T.jitter_page(p, Jd, keep_labels=False) for p in P[A_RUN] if p['split'] == sp]
                print(f'FINAL {vn:12} {"asm830 jittered":16} {sp:4} t {J["threshold"]:.6f}: {T.fmt(T.score(ps, [T.prob(J, p["X"]) for p in ps], J["threshold"]))}')
    print(f'{time.time() - t0:.0f} s')


def simulated(pages, res):
    """asm830 with every S3 box jittered once (scale 1.0, seed 4242), labels following the boxes; raw fields kept so
    a variant's own jitter applies on top."""
    J = T.AUG.Jitter(res, 1.0, seed=4242); out = []
    for p in pages:
        lines = [dict(l, box=J.box(l['box'], bool(l['vertical']))) for l in p['lines']]
        q = T.make_page(p['meta'], lines, p['layout'], p['W'], p['H'], p['gts'])
        q.update(meta=p['meta'], lines=lines, layout=p['layout'], gts=p['gts'])
        out.append(q)
    return out


def report(vn, r):
    s = lambda d, k: '/'.join(str(d[n][k]) for n in ('page', 'size', 'chunk'))
    print(f"{vn:13} t {r['t']:.6f} (B {r['tB']:.6f}) | acc junk {s(r['acc'], 'junk')} lost {s(r['acc'], 'extra_lost')} "
          f"nested {'/'.join(str(r['nested'][n]) for n in ('page', 'size', 'chunk'))} | A->B lost {s(r['cross_AB'], 'extra_lost')} "
          f"junk {s(r['cross_AB'], 'junk')} | B->A lost {s(r['cross_BA'], 'extra_lost')} junk {s(r['cross_BA'], 'junk')} | "
          f"A->loose lost {s(r['cross_Aloose'], 'extra_lost')} junk {s(r['cross_Aloose'], 'junk')} | jit lost {s(r['jit'], 'extra_lost')} "
          f"junk {s(r['jit'], 'junk')} | stab det dt {r['stab_' + B_RUN]['dt']:.3f} agree {r['stab_' + B_RUN]['agree']:.5f} "
          f"shift dt {r['stab_shift']['dt']:.3f} agree {r['stab_shift']['agree']:.5f} | {r['time']:.0f}s", flush=True)


if __name__ == '__main__':
    main()
