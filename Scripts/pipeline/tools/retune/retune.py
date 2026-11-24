#!/usr/bin/env python3
"""retune.py NAME [--models DIR] [--knobs a,b|all] [--start FILE] [--final-only] [--plan]

Re-fits the model-coupled PipelineTuning knobs after a model is replaced:
  1. ref    repository models, default knobs (shared across NAMEs, reused when present)
  2. new0   --models DIR (replacement model / dictionary / LM files; missing ones from the repo), default knobs
  3. sweep  coordinate line search, one knob at a time, on TRAIN folds only (see judge())
  4. final  ref, new0 and the fitted set on dev, train and test
Every run is a --no-png replay of saved translations in one heavy slot (tools/lock.zsh), two at a time.
Output: $AIDOKU_EVAL_DIR/runs/retune/NAME/{report.md, tuning.json, log.txt}; apply tuning.json by hand.
"""
import argparse, collections, functools, json, os, re, shutil, subprocess, sys, threading
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from workspace import EVAL as E, REPO, PYTHON, MASK_PYTHON, MANIFEST, REPLAY  # noqa: E402
PY = str(PYTHON)
RUNS = E / 'runs/retune'

# Defaults = PipelineTuning() in Aidoku/Core/Translation/Pipeline/PipelineTuning.swift (checked at start).
DEFAULTS = dict(layoutTextFloor=0.25, layoutSFXFloor=0.20, layoutFrameFloor=0.50, balloonFloor=0.40,
                detectionThreshold=0.85, detectionBoxThreshold=0.25, detectionUnclipRatio=1.4, detectionMaximumSide=1120,
                assemblyMinimumOverlap=0.6, assemblyMaximumGap=1.5, recognitionMinimumConfidence=0.30,
                recognitionLinePadDivisor=20, fragmentConfidence=0.6, roleSFXScore=0.8, roleBalloonScore=0.5,
                roleRescueBalloon=0.5, roleRescueSFX=0.1, parallelOverlap=0.6, parallelGap=1.0,
                balloonOwnerCoverage=0.9, textScopeCoverage=0.8, balloonEdgeCoverage=0.7,
                interiorHorizontalReach=8, interiorVerticalReach=3, interiorFrameScore=0.7,
                maskThreshold=0.15, maskDilation=2, lineEndExtension=0.5, lineEndMargin=0.35, fontLevel=0.02845)
# knob: (step, lower, upper, kind). Order = pipeline order, so later knobs are fitted on top of earlier ones.
# kind 'render' = decided on compare.py + merge GT; 'mask' = mscore (S6 vs GT glyphs) with render as guard;
# 'font' = S8 source font px vs GT font-size classes with render as guard.
KNOBS = {
    'detectionMaximumSide': (64, 768, 1184, 'render'),       # multiple of 32; the current det model accepts 32..1184 (a candidate with failed pages is rejected)
    'detectionThreshold': (0.05, 0.5, 0.95, 'render'),
    'detectionBoxThreshold': (0.05, 0.05, 0.8, 'render'),
    'detectionUnclipRatio': (0.1, 1.0, 2.2, 'render'),
    'layoutTextFloor': (0.05, 0.05, 0.8, 'render'),
    'layoutSFXFloor': (0.05, 0.05, 0.8, 'render'),
    'balloonFloor': (0.05, 0.1, 0.8, 'render'),
    'layoutFrameFloor': (0.1, 0.1, 0.9, 'render'),
    'assemblyMinimumOverlap': (0.1, 0.2, 1.2, 'render'),
    'assemblyMaximumGap': (0.25, 0.5, 3.0, 'render'),
    'recognitionLinePadDivisor': (5, 8, 80, 'render'),       # pad = short / divisor (20 = 5%)
    'recognitionMinimumConfidence': (0.05, 0.1, 0.55, 'render'),
    'fragmentConfidence': (0.05, 0.3, 0.9, 'render'),
    'roleSFXScore': (0.05, 0.5, 0.95, 'render'),
    'roleBalloonScore': (0.05, 0.3, 0.8, 'render'),
    'roleRescueBalloon': (0.05, 0.3, 0.8, 'render'),
    'roleRescueSFX': (0.05, 0.05, 0.4, 'render'),
    'parallelOverlap': (0.2, 0.2, 1.6, 'render'),
    'parallelGap': (0.1, 0.6, 1.6, 'render'),
    'balloonOwnerCoverage': (0.05, 0.7, 1.0, 'render'),
    'textScopeCoverage': (0.05, 0.6, 0.95, 'render'),
    'balloonEdgeCoverage': (0.05, 0.5, 0.95, 'render'),
    'interiorHorizontalReach': (2, 2, 16, 'render'),
    'interiorVerticalReach': (0.5, 1, 6, 'render'),
    'interiorFrameScore': (0.05, 0.5, 0.9, 'render'),         # only acts at or above layoutFrameFloor
    'maskThreshold': (0.05, 0.05, 0.6, 'mask'),
    'maskDilation': (1, 0, 5, 'mask'),
    'lineEndExtension': (0.1, 0.2, 1.0, 'mask'),
    'lineEndMargin': (0.05, 0.1, 0.7, 'mask'),
    'fontLevel': (0.02, -0.1, 0.16, 'font'),
}
# Left out of --knobs all: no effect on dev (balloonFloor already drops those balloons). Name it to sweep it.
NOT_IN_ALL = {'roleBalloonScore'}
MAX_STEPS = 3  # line search: up to 3 steps out from the current value in the winning direction

lock = threading.Lock()
LOG = None


def log(msg):
    with lock:
        print(msg, flush=True)
        if LOG:
            with open(LOG, 'a') as f:
                f.write(msg + '\n')


def check_defaults():
    src = (REPO / 'Aidoku/Core/Translation/Pipeline/PipelineTuning.swift').read_text()
    for k, v in DEFAULTS.items():
        m = re.search(rf'var {k}(?:: \w+)? = (-?[0-9._]+)', src)
        assert m and float(m.group(1).replace('_', '')) == float(v), f'DEFAULTS[{k}] = {v} disagrees with PipelineTuning.swift ({m and m.group(1)})'


def fmt(v):
    return f'{v:g}'


def tag_of(tuning):
    diff = {k: v for k, v in tuning.items() if DEFAULTS[k] != v}
    return 'default' if not diff else '-'.join(f'{k}{fmt(v)}' for k, v in sorted(diff.items()))


# ---------- runs ----------
def run(dir_prefix, split, tuning, models, allow_fail=False):
    """Replays one split into DIR_PREFIX_SPLIT (skipped when it finished before with the same settings)."""
    out = Path(f'{dir_prefix}_{split}')
    meta = dict(tuning=tuning, models=str(models) if models else 'repository', head=git_head())
    stamp = out / 'retune.json'
    if stamp.exists() and json.loads(stamp.read_text()) == meta and (out / 'summary.json').exists():
        return out
    shutil.rmtree(out, ignore_errors=True)
    for c in (E / 'runs/reclass/cache').glob(str(out).replace('/', '_') + '*'):
        c.unlink()
    out.parent.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, AIDOKU_PIPELINE_TUNING=json.dumps(tuning), AIDOKU_PIPELINE_DUMP_MASKS=str(out / 'masks'))
    if models:
        env['AIDOKU_PIPELINE_MODELS'] = str(models)
    else:
        env.pop('AIDOKU_PIPELINE_MODELS', None)
    cmd = (f'source {TOOLS}/lock.zsh; take_slot retune-{out.name[:40]}; cd {REPO}; '
           f'swift Scripts/image-translation.swift --split {split} --manifest {MANIFEST} --jobs 4 --no-png '
           f'--replay-translations {REPLAY} --replay-fill-unmatched --output {out} > {out}.log 2>&1; '
           f'st=$?; rm -rf "${{slot:?}}"; exit $st')
    r = subprocess.run(['zsh', '-c', cmd], env=env)
    if not (out / 'summary.json').exists() or (r.returncode != 0 and not allow_fail):
        raise RuntimeError(f'run failed: {out} (see {out}.log)')
    stamp.write_text(json.dumps(meta))
    return out


@functools.cache
def git_head():
    h = subprocess.check_output(['git', '-C', str(REPO), 'rev-parse', 'HEAD'], text=True).strip()
    dirty = subprocess.check_output(['git', '-C', str(REPO), 'status', '--porcelain', '--', 'Aidoku/Core', 'Scripts'], text=True)
    return h + ('+dirty' if dirty.strip() else '')


# ---------- scores (numbers only) ----------
sys.path.insert(0, str(TOOLS / 'reclass'))


def render_cmp(base_dir, var_dir, split='train'):
    """compare.py restricted to one split: net = gains - losses over render items, noise."""
    sys.argv = ['compare.py']  # compare.py reads --lines from argv
    import compare
    if split == 'test':
        for p in json.load(open(compare.MAN))['pages']:
            if p['split'] == 'test':
                compare.FOLD[p['page_id']] = 5
    with lock:
        B, V, pages, g, l, nchg, chpages = compare.compare(f'{base_dir},{base_dir}', f'{var_dir},{var_dir}')
    G = sum(g.values(), collections.Counter()); L = sum(l.values(), collections.Counter())
    nb = sum(nchg.values())
    return dict(net=int(sum(G.values()) - sum(L.values())), gains=dict(G), losses=dict(L), changed=nb,
                pages=len(chpages), noise=max(3.0, 0.01 * nb))


def merge_gt(run_dir, label):
    out = subprocess.check_output([PY, str(TOOLS / 'merge_gt_eval.py'), str(run_dir)], text=True)
    for line in out.splitlines():
        m = re.match(rf'\s*{label} pages\s+(\d+) exact\s+(\d+).*line P ([0-9.]+) R ([0-9.]+) \| frag\s+(\d+) wrong\s+(\d+) missed\s+(\d+)', line)
        if m:
            n, ex, p, r, fr, wr, mi = m.groups()
            return dict(pages=int(n), exact=int(ex), lineP=float(p), lineR=float(r), frag=int(fr), wrong=int(wr), missed=int(mi))
    raise RuntimeError(f'merge_gt_eval: no {label} row for {run_dir}')


def detection(run_dir, split):
    out = Path(run_dir) / 'eval.json'
    cmd = ['python3', str(REPO / 'Scripts/pipeline/eval.py'), str(run_dir), '--split', split, '--out', str(out)]
    if split == 'test':
        cmd.append('--allow-test')
    subprocess.run(cmd, check=True, capture_output=True)
    d = json.load(open(out))
    det, grp = d['detection'], d['grouping']
    return dict(recall50=det['recall@0.5'], precision50=det['precision@0.5'], recall70=det['recall@0.7'],
                groupF1=grp['F1'], purity=grp['purity'], nonLLMms=d.get('timingsMs', {}).get('total_non_llm', {}).get('median'))


def masks(run_dir, run_prefix):
    """S6 masks vs GT glyph masks (convmask mscore, in the convmask venv), totals over the pages of this run."""
    code = ('import sys, json; sys.path.insert(0, sys.argv[1]); import mscore; mscore.PREFIX = sys.argv[2]; '
            'print(json.dumps(mscore.run(sys.argv[3])))')
    out = subprocess.check_output([str(MASK_PYTHON), '-c', code, str(TOOLS / 'convmask'),
                                   str(run_prefix), str(Path(run_dir) / 'masks')], text=True)
    res = json.loads(out.strip().splitlines()[-1])
    t = collections.Counter()
    for r in res.values():
        t.update({k: v for k, v in r.items() if not k.startswith('reg')})
    return dict(regions=t['tgt'], recall=round(1 - t['miss'] / max(1, t['tgtPx']), 5), resid=t['resid'],
                resid10=t['resid10'], far=t['far'], art=t['art'], farA=t['farA'], artA=t['artA'], mask=t['mask'])


def font(run_dir):
    """S8 source font px (block style.fontPixels) vs GT font-size classes: each block is matched to the GT
    merged_bbox region holding >= 50% of its box; error = |estimate / GT px - 1|."""
    import consistency_metrics as cm
    regions, _, size = cm.gt()
    errs = []
    for f in sorted(Path(run_dir, 'pages').glob('*.json')):
        r = json.load(open(f))
        pid = r['pageID']
        for b in r['blocks']:
            px = (b.get('style') or {}).get('fontPixels')
            if not px:
                continue
            (x, y), (w, h) = b['bounds']
            best, val = None, 0
            for rid, (a, bb, c, d) in regions.get(pid, {}).items():
                i = max(0, min(x + w, c) - max(x, a)) * max(0, min(y + h, d) - max(y, bb))
                v = i / max(1e-9, w * h)
                if v > val:
                    best, val = rid, v
            if best is not None and val >= 0.5 and (pid, best) in size:
                errs.append(abs(px / size[(pid, best)] - 1))
    errs.sort()
    n = len(errs)
    return dict(blocks=n, median=round(errs[n // 2], 4) if n else None, over10=sum(e > 0.1 for e in errs),
                over20=sum(e > 0.2 for e in errs))


def colour(run_prefix):
    out = subprocess.run([PY, str(TOOLS / 'colorfix/errors.py'), run_prefix], capture_output=True, text=True).stdout
    fill = re.search(r'fill dE>12: (\d+)', out); outl = re.search(r'outline missed (\d+) invented (\d+)', out)
    return dict(fillErrors=int(fill.group(1)) if fill else None,
                outlineMissed=int(outl.group(1)) if outl else None, outlineInvented=int(outl.group(2)) if outl else None)


# ---------- decision ----------
def judge(kind, base, var):
    """(passes, score, why) for candidate run VAR against the current set BASE on train folds."""
    if var.get('failed'):
        return False, float('-inf'), f"{var['failed']} page(s) failed (see the run log)"
    rc = render_cmp(base['dir'], var['dir'])
    var['merge'] = var.get('merge') or merge_gt(var['dir'], 'train')
    mb, mv = base['merge'], var['merge']
    dex, dR, dP = mv['exact'] - mb['exact'], mv['lineR'] - mb['lineR'], mv['lineP'] - mb['lineP']
    merge_ok = dex >= -1 and dR >= -0.002 and dP >= -0.002
    why = (f"render net {rc['net']:+d} (noise {rc['noise']:.0f}, changed {rc['changed']} blocks / {rc['pages']} pages, "
           f"losses {rc['losses']}); merge exact {dex:+d}, line R {dR:+.4f} P {dP:+.4f}")
    if kind == 'render':
        score = rc['net'] + 3 * dex
        return rc['net'] > rc['noise'] and merge_ok, score, why
    render_ok = rc['net'] >= -rc['noise']
    if kind == 'font':
        var['font'] = var.get('font') or font(var['dir'])
        fb, fv = base['font'], var['font']
        d10, dmed = fv['over10'] - fb['over10'], fv['median'] - fb['median']
        why += f"; font >10% {d10:+d} of {fv['blocks']}, median {dmed:+.4f}"
        return d10 <= -max(3, 0.01 * fv['blocks']) and dmed <= 0.002 and render_ok and merge_ok, -d10, why
    var['mask'] = var.get('mask') or masks(var['dir'], var['prefix'])
    kb, kv = base['mask'], var['mask']
    dres, dart = kv['resid'] - kb['resid'], kv['artA'] - kb['artA']
    rel = dart / max(1, kb['artA'])
    why += f"; mask resid {dres:+d}, artA {dart:+d} ({rel:+.1%}), recall {kv['recall'] - kb['recall']:+.5f}"
    better = (dres <= -3 and rel <= 0.02) or (rel <= -0.05 and dres <= 0)
    return better and render_ok and merge_ok, -dres - 20 * rel, why


def main():
    global LOG
    ap = argparse.ArgumentParser()
    ap.add_argument('name')
    ap.add_argument('--models', help='directory of replacement model files (default: the repository models)')
    ap.add_argument('--knobs', default='all')
    ap.add_argument('--start', help='JSON tuning to start the sweep from (default: PipelineTuning defaults)')
    ap.add_argument('--final-only', action='store_true', help='skip the sweep; evaluate --start (or defaults)')
    ap.add_argument('--plan', action='store_true', help='print the plan and exit')
    a = ap.parse_args()
    check_defaults()
    models = Path(a.models).resolve() if a.models else None
    if models:
        assert models.is_dir(), models
        files = sorted(p.name for p in models.iterdir())
        assert files, f'{models} is empty'
    knobs = [k for k in KNOBS if k not in NOT_IN_ALL] if a.knobs == 'all' else a.knobs.split(',')
    for k in knobs:
        assert k in KNOBS, f'unknown knob {k}'
    out = RUNS / a.name
    out.mkdir(parents=True, exist_ok=True)
    LOG = out / 'log.txt'
    start = dict(DEFAULTS, **(json.load(open(a.start)) if a.start else {}))
    if a.plan:
        print(f'models: {models or "repository"}; files: {files if models else "-"}')
        print(f'start: {tag_of(start)}; knobs: {knobs}; head {git_head()}')
        print('runs: ref + new0 on train, ~2-6 train runs per knob, final on dev/test (+ref/new0 dev/test)')
        return
    log(f'== retune {a.name}: models {models or "repository"}, head {git_head()}, knobs {",".join(knobs)}')
    pool = ThreadPoolExecutor(2)

    def evaluate(tuning, label=None, splits=('train',)):
        prefix = str(out / (label or tag_of(tuning))) if label != 'ref' else str(RUNS / f'ref-{git_head()[:12]}')
        # Only sweep candidates may fail pages (e.g. a canvas the model rejects); they are then rejected.
        dirs = {s: run(prefix, s, tuning, None if label == 'ref' else models, allow_fail=label is None) for s in splits}
        failed = sum(len(json.load(open(d / 'summary.json')).get('failedPages') or []) for d in dirs.values())
        return dict(tuning=dict(tuning), prefix=prefix, dir=dirs.get('train'), dirs=dirs, failed=failed)

    # 1-2: reference and the new models with the old knobs (train), in parallel.
    f_ref = pool.submit(evaluate, DEFAULTS, 'ref')
    same = models is None and start == DEFAULTS  # new0 would replay ref exactly
    f_new0 = None if same else pool.submit(evaluate, start, 'new0')
    ref = f_ref.result()
    new0 = dict(ref) if same else f_new0.result()
    for r in (ref, new0):
        r['merge'] = merge_gt(r['dir'], 'train')
    log(f"ref  train merge {ref['merge']}")
    log(f"new0 train merge {new0['merge']}")
    if models:
        rc = render_cmp(ref['dir'], new0['dir'])
        log(f"new models, old knobs vs ref (train): render net {rc['net']:+d} noise {rc['noise']:.0f} gains {rc['gains']} losses {rc['losses']}")

    # 3: coordinate line search on train.
    best = new0
    history = []
    if not a.final_only:
        for k in knobs:
            step, lo, hi, kind = KNOBS[k]
            if kind == 'mask' and 'mask' not in best:
                best['mask'] = masks(best['dir'], best['prefix'])
            if kind == 'font' and 'font' not in best:
                best['font'] = font(best['dir'])
            cur = best['tuning'][k]
            log(f'-- {k} = {fmt(cur)} ({kind}); step {fmt(step)}')

            def cand(v):
                t = dict(best['tuning'], **{k: round(v, 6)})
                return pool.submit(evaluate, t)
            vals = [v for v in (cur - step, cur + step) if lo <= v <= hi]
            futs = {v: cand(v) for v in vals}
            results = {}
            for v, f in futs.items():
                r = f.result()
                ok, score, why = judge(kind, best, r)
                results[v] = (ok, score, r)
                log(f'   {k}={fmt(v)}: {"PASS" if ok else "no"} score {score:+.1f} | {why}')
                history.append(dict(knob=k, value=v, base=best['tuning'][k], passes=ok, score=score, why=why))
            winners = [(s, v) for v, (ok, s, _) in results.items() if ok]
            if not winners:
                log(f'   keep {k} = {fmt(cur)}')
                continue
            s, v = max(winners)
            direction = 1 if v > cur else -1
            best = results[v][2]
            log(f'   take {k} = {fmt(v)}')
            for _ in range(MAX_STEPS - 1):  # keep walking while the next step still beats the new set
                nv = round(best['tuning'][k] + direction * step, 6)
                if not lo <= nv <= hi:
                    break
                r = cand(nv).result()
                ok, score, why = judge(kind, best, r)
                log(f'   {k}={fmt(nv)}: {"PASS" if ok else "no"} score {score:+.1f} | {why}')
                history.append(dict(knob=k, value=nv, base=best['tuning'][k], passes=ok, score=score, why=why))
                if not ok:
                    break
                best = r
                log(f'   take {k} = {fmt(nv)}')
    fitted = best['tuning']
    (out / 'tuning.json').write_text(json.dumps({k: v for k, v in fitted.items() if v != DEFAULTS[k]}, indent=1))
    (out / 'history.json').write_text(json.dumps(history, indent=1))
    log(f'fitted: {tag_of(fitted)}')

    # 4: final check on dev and test (+ train for the S8 colour count), ref / new0 / fitted.
    splits = ('dev', 'train', 'test')
    sets = {'ref': (DEFAULTS, 'ref'), 'new0': (start, 'ref' if same else 'new0'), 'fitted': (fitted, None)}
    futs = {n: pool.submit(evaluate, t, lbl, splits) for n, (t, lbl) in sets.items()}
    fin = {n: f.result() for n, f in futs.items()}
    rows = {}
    for n, r in fin.items():
        row = {}
        for s in splits:
            row[s] = dict(detection=detection(r['dirs'][s], s), masks=masks(r['dirs'][s], r['prefix']), font=font(r['dirs'][s]))
        row['merge'] = {s: merge_gt(r['dirs'][s], s) for s in ('dev', 'train')}
        row['colour'] = colour(r['prefix'])
        rows[n] = row
    cmp = {}
    for a_, b_ in (('ref', 'new0'), ('new0', 'fitted'), ('ref', 'fitted')):
        cmp[f'{b_} vs {a_}'] = {s: render_cmp(fin[a_]['dirs'][s], fin[b_]['dirs'][s], s) for s in splits}
    (out / 'final.json').write_text(json.dumps(dict(rows=rows, compare=cmp, fitted=fitted), indent=1, default=str))
    report(out, a.name, models, fitted, rows, cmp, history)
    log(f'report: {out / "report.md"}')


def report(out, name, models, fitted, rows, cmp, history):
    L = [f'# retune {name}', '', f'models: `{models or "repository"}`  head: `{git_head()}`', '']
    diff = {k: (DEFAULTS[k], v) for k, v in fitted.items() if v != DEFAULTS[k]}
    L += ['## Fitted knobs (train folds only)', '']
    L += [f'- `{k}`: {fmt(a)} -> {fmt(b)}' for k, (a, b) in diff.items()] or ['- none changed']
    L += ['', '## Render items (reclass compare.py: net = gains - losses; > noise is a real change)', '',
          '| comparison | split | net | noise | changed blocks | losses |', '|---|---|---|---|---|---|']
    for c, per in cmp.items():
        for s, r in per.items():
            L.append(f"| {c} | {s} | {r['net']:+d} | {r['noise']:.0f} | {r['changed']} | {r['losses']} |")
    L += ['', '## Detection / grouping (Scripts/pipeline/eval.py)', '',
          '| set | split | recall@0.5 | precision@0.5 | recall@0.7 | group F1 | purity | non-LLM median ms |',
          '|---|---|---|---|---|---|---|---|']
    for n, row in rows.items():
        for s in ('dev', 'train', 'test'):
            d = row[s]['detection']
            L.append(f"| {n} | {s} | {d['recall50']} | {d['precision50']} | {d['recall70']} | {d['groupF1']} | {d['purity']} | {d['nonLLMms']} |")
    L += ['', '## Merge GT (merge_gt_eval.py)', '', '| set | split | exact | line P | line R | frag | wrong | missed |',
          '|---|---|---|---|---|---|---|---|']
    for n, row in rows.items():
        for s, m in row['merge'].items():
            L.append(f"| {n} | {s} | {m['exact']}/{m['pages']} | {m['lineP']} | {m['lineR']} | {m['frag']} | {m['wrong']} | {m['missed']} |")
    L += ['', '## Learned components: drift check', '',
          'S6 masks vs GT glyphs (convmask mscore; resid = GT regions with > 2% unerased, artA = stray mask px on art):', '',
          '| set | split | recall | resid | resid10 | farA | artA |', '|---|---|---|---|---|---|---|']
    for n, row in rows.items():
        for s in ('dev', 'train', 'test'):
            m = row[s]['masks']
            L.append(f"| {n} | {s} | {m['recall']} | {m['resid']} | {m['resid10']} | {m['farA']} | {m['artA']} |")
    L += ['', 'S8 source font size vs GT font-size classes (|estimate / GT - 1|):', '',
          '| set | split | blocks | median | > 10% | > 20% |', '|---|---|---|---|---|---|']
    for n, row in rows.items():
        for s in ('dev', 'train', 'test'):
            f = row[s]['font']
            L.append(f"| {n} | {s} | {f['blocks']} | {f['median']} | {f['over10']} | {f['over20']} |")
    L += ['', 'S8 colour vs appearance GT (colorfix/errors.py, all splits):', '', '| set | fill dE>12 | outline missed | outline invented |', '|---|---|---|---|']
    for n, row in rows.items():
        c = row['colour']
        L.append(f"| {n} | {c['fillErrors']} | {c['outlineMissed']} | {c['outlineInvented']} |")
    L += ['', 'If new0/fitted is clearly worse than ref here, retrain the learned part on the new models\' outputs:',
          '- S6 MaskNet: tools/convmask (prep.py -> train.py -> convert.py), threshold re-fit = maskThreshold above',
          '- S8 fill/outline forests in PipelineWeights.bin: tools/colorfix (train_fill_lgb.py, train_peaks.py, export_fill.py)',
          '- font-size correction forest (fontLevel only shifts its global level): tools/colorfix/train_font.py',
          '- line-end regressor (lineEnds forest; lineEndMargin is fitted with it): tools/bboxagent/export.py',
          '- n-gram arbiter gates on the recognizer\'s top-k probabilities (NativeMangaNGram): no scorer, re-check by hand',
          '- S8 bold rule (boldLineCover / boldRidgeRatio): no scorer here (bold GT: source_font_weight records)',
          '  (these read Swift-side feature dumps; re-add the dump hook for the stage when retraining)',
          '', f'## Sweep log ({len(history)} candidates)', '']
    for h in history:
        L.append(f"- {h['knob']} {fmt(h['base'])} -> {fmt(h['value'])}: {'PASS' if h['passes'] else 'no'} — {h['why']}")
    L += ['', 'Apply: set the fitted values as the defaults in `PipelineTuning.swift` (and DEFAULTS in retune.py), '
          'run the fast iOS tests, commit.']
    (out / 'report.md').write_text('\n'.join(L) + '\n')


if __name__ == '__main__':
    main()
