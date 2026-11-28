#!/usr/bin/env python3
"""retune.py NAME [--models DIR] [--knobs a,b|all] [--start FILE] [--objective items|typeset] [--final-only] [--light] [--plan]

Re-fits the model-coupled PipelineTuning knobs after a model is replaced:
  1. ref    repository models, default knobs (shared across NAMEs, reused when present)
  2. new0   --models DIR (replacement model / dictionary / LM files; missing ones from the repo), default knobs
  3. sweep  coordinate line search, one knob at a time, on TRAIN folds only (see judge()); --objective typeset
            decides on typeset_score.py (one score over every GT-checked aspect) instead of the render items
  4. final  ref, new0 and the fitted set on dev, train and test
Every run is a --no-png replay of saved translations in one heavy slot (tools/lock.zsh), two at a time (--light: one,
on efficiency cores). Stopped? Run the same NAME again: finished runs are reused while their inputs (compiled code,
resources / models, manifest, translations: not the git commit) and knobs are unchanged.
Output: $AIDOKU_EVAL_DIR/runs/retune/NAME/{report.md, tuning.json, log.txt}; apply tuning.json by hand.
"""
import argparse, collections, functools, hashlib, json, os, re, shutil, subprocess, sys, threading
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
                recognitionLinePadDivisor=20, lineKeepScale=1.0, fragmentConfidence=0.6, roleSFXScore=0.8, roleBalloonScore=0.5,
                roleRescueBalloon=0.5, roleRescueSFX=0.1,
                interiorHorizontalReach=8, interiorVerticalReach=3, interiorFrameScore=0.7,
                maskThreshold=0.15, maskDilation=2, lineEndExtension=0.5, lineEndMargin=0.35, fontLevel=0.02845,
                layoutBalloonInset=0.02, layoutBalloonCap=1.05, layoutWholeWordRatio=0.8, layoutTallWidth=1.7, layoutPageScale=0.0,
                layoutFamilyShare=0.7, layoutSpanWhole=0.9)
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
    'lineKeepScale': (0.5, 0.0, 4.0, 'render'),               # S3 keep gate threshold x this (0 = gate off)
    'fragmentConfidence': (0.05, 0.3, 0.9, 'render'),
    'roleSFXScore': (0.05, 0.5, 0.95, 'render'),
    'roleBalloonScore': (0.05, 0.3, 0.8, 'render'),
    'roleRescueBalloon': (0.05, 0.3, 0.8, 'render'),
    'roleRescueSFX': (0.05, 0.05, 0.4, 'render'),
    'interiorHorizontalReach': (2, 2, 16, 'render'),
    'interiorVerticalReach': (0.5, 1, 6, 'render'),
    'interiorFrameScore': (0.05, 0.5, 0.9, 'render'),         # only acts at or above layoutFrameFloor
    'maskThreshold': (0.05, 0.05, 0.6, 'mask'),
    'maskDilation': (1, 0, 5, 'mask'),
    'lineEndExtension': (0.1, 0.2, 1.0, 'mask'),
    'lineEndMargin': (0.05, 0.1, 0.7, 'mask'),
    'fontLevel': (0.02, -0.1, 0.16, 'font'),
    'layoutBalloonInset': (0.01, 0.0, 0.08, 'render'),        # S9 knobs: decided on the render items or, better, on
    'layoutBalloonCap': (0.025, 1.0, 1.15, 'render'),         # --objective typeset (they were fitted on it)
    'layoutWholeWordRatio': (0.05, 0.6, 0.95, 'render'),
    'layoutTallWidth': (0.2, 1.0, 2.6, 'render'),
    'layoutFamilyShare': (0.1, 0.4, 1.0, 'render'),
    'layoutSpanWhole': (0.05, 0.8, 1.0, 'render'),
}
# Left out of --knobs all: no effect on dev (balloonFloor already drops those balloons). Name it to sweep it.
NOT_IN_ALL = {'roleBalloonScore', 'layoutPageScale'}
MAX_STEPS = 3  # line search: up to 3 steps out from the current value in the winning direction

lock = threading.Lock()
LOG = None
OBJECTIVE = 'items'  # --objective
LIGHT = False  # --light: one run at a time, one page job, background QoS (efficiency cores)


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
    meta = dict(tuning=tuning, models=str(models) if models else 'repository', inputs=inputs(models))
    stamp = out / 'retune.json'
    if stamp.exists() and (out / 'summary.json').exists():
        old = json.loads(stamp.read_text())
        # A stamp from before content keys holds the git head instead: still valid at that same head.
        legacy = dict(tuning=meta['tuning'], models=meta['models'], head=git_head())
        if old == meta or old == legacy:
            stamp.write_text(json.dumps(meta))
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
    if LIGHT:
        env['AIDOKU_HOST_COMPILER_JOBS'] = '1'
    host = 'taskpolicy -b swift' if LIGHT else 'swift'
    cmd = (f'source {TOOLS}/lock.zsh; take_slot retune-{out.name[:40]}; cd {REPO}; '
           f'{host} Scripts/image-translation.swift --split {split} --manifest {MANIFEST} --jobs {1 if LIGHT else 4} --no-png '
           f'--replay-translations {REPLAY} --replay-fill-unmatched --output {out} > {out}.log 2>&1; '
           f'st=$?; rm -rf "${{slot:?}}"; exit $st')
    r = subprocess.run(['zsh', '-c', cmd], env=env)
    if not (out / 'summary.json').exists() or (r.returncode != 0 and not allow_fail):
        raise RuntimeError(f'run failed: {out} (see {out}.log)')
    stamp.write_text(json.dumps(meta))
    return out


@functools.cache
def inputs(models=None):
    """What a run's output depends on besides its knobs: the code the host compiles (its own fingerprint), the
    resources and models it loads (content), the manifest and the saved translations. Not the git commit, so a
    commit, a comment-free edit elsewhere or a tool change keeps saved runs; an edit to compiled code reruns them."""
    env = dict(os.environ, AIDOKU_HOST_FINGERPRINT='1')
    code = subprocess.check_output(['swift', 'Scripts/image-translation.swift', '--split', 'train'], cwd=REPO, env=env,
                                   text=True).split()[-1]
    h = hashlib.sha256()
    for base in [REPO / 'Aidoku/Resources/Translation'] + ([models] if models else []):
        for f in sorted(p for p in Path(base).rglob('*') if p.is_file()):
            h.update(str(f.relative_to(base)).encode())
            h.update(f.read_bytes())
    for f in [Path(MANIFEST)]:
        h.update(f.read_bytes())
    return dict(code=code[:16], resources=h.hexdigest()[:16], replay=str(REPLAY))


def ref_prefix():
    """The shared ref run, named by its inputs; an older one named by git head is reused while that head is current."""
    legacy = RUNS / f'ref-{git_head()[:12]}'
    if Path(f'{legacy}_train/retune.json').exists():
        return str(legacy)
    i = inputs(None)
    return str(RUNS / f"ref-{i['code'][:8]}{i['resources'][:4]}")


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


def typeset(r, split='train'):
    """typeset_score.py pages of a run record (kept on it)."""
    import typeset_score
    key = f'typeset_{split}'
    if key not in r:
        r[key] = typeset_score.run(r['dirs'][split] if 'dirs' in r else r['dir'])
    return r[key]


def typeset_cmp(base, var, split='train'):
    """Paired typeset score difference VAR - BASE with its page-bootstrap 95% interval."""
    import typeset_score
    return typeset_score.compare(typeset(base, split), typeset(var, split))


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
    code = ('import sys, json; sys.path.insert(0, sys.argv[1]); import mscore; '
            'print(json.dumps(mscore.run(sys.argv[3], sys.argv[2])))')
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
    """(passes, score, why) for candidate run VAR against the current set BASE on train folds.
    'render' knobs pass on the render items (net > noise) or, with --objective typeset, on a typeset score gain whose
    95% interval is above 0; the other kinds use the same measure as their guard (not clearly worse)."""
    if var.get('failed'):
        return False, float('-inf'), f"{var['failed']} page(s) failed (see the run log)"
    rc = render_cmp(base['dir'], var['dir'])
    var['merge'] = var.get('merge') or merge_gt(var['dir'], 'train')
    mb, mv = base['merge'], var['merge']
    dex, dR, dP = mv['exact'] - mb['exact'], mv['lineR'] - mb['lineR'], mv['lineP'] - mb['lineP']
    merge_ok = dex >= -1 and dR >= -0.002 and dP >= -0.002
    why = (f"render net {rc['net']:+d} (noise {rc['noise']:.0f}, changed {rc['changed']} blocks / {rc['pages']} pages, "
           f"losses {rc['losses']}); merge exact {dex:+d}, line R {dR:+.4f} P {dP:+.4f}")
    tc = typeset_cmp(base, var)
    why += f"; typeset {tc['diff']:+.3f} ({tc['low']:+.3f} .. {tc['high']:+.3f})"
    if kind == 'render':
        if OBJECTIVE == 'typeset':  # a real gain: the whole 95% interval above 0
            return tc['low'] > 0 and merge_ok, tc['diff'], why
        score = rc['net'] + 3 * dex
        return rc['net'] > rc['noise'] and merge_ok, score, why
    render_ok = tc['high'] >= 0 if OBJECTIVE == 'typeset' else rc['net'] >= -rc['noise']
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
    ap.add_argument('--objective', choices=('items', 'typeset'), default='items', help='what decides a render knob (see judge)')
    ap.add_argument('--final-only', action='store_true', help='skip the sweep; evaluate --start (or defaults)')
    ap.add_argument('--light', action='store_true', help='low load (no fan): one run at a time, --jobs 1, background QoS')
    ap.add_argument('--plan', action='store_true', help='print the plan and exit')
    a = ap.parse_args()
    global OBJECTIVE, LIGHT
    OBJECTIVE = a.objective
    LIGHT = a.light
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
    inputs(None), inputs(models)  # once, before the runs start in two threads
    log(f'== retune {a.name}: models {models or "repository"}, head {git_head()}, inputs {inputs(models)}, knobs {",".join(knobs)}, objective {OBJECTIVE}')
    pool = ThreadPoolExecutor(1 if LIGHT else 2)

    def evaluate(tuning, label=None, splits=('train',)):
        prefix = str(out / (label or tag_of(tuning))) if label != 'ref' else ref_prefix()
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
    cmp, tcmp = {}, {}
    for a_, b_ in (('ref', 'new0'), ('new0', 'fitted'), ('ref', 'fitted')):
        cmp[f'{b_} vs {a_}'] = {s: render_cmp(fin[a_]['dirs'][s], fin[b_]['dirs'][s], s) for s in splits}
        tcmp[f'{b_} vs {a_}'] = {s: typeset_cmp(fin[a_], fin[b_], s) for s in splits}
    (out / 'final.json').write_text(json.dumps(dict(rows=rows, compare=cmp, typeset=tcmp, fitted=fitted, objective=OBJECTIVE), indent=1, default=str))
    report(out, a.name, models, fitted, rows, cmp, history, tcmp)
    log(f'report: {out / "report.md"}')


def report(out, name, models, fitted, rows, cmp, history, tcmp):
    L = [f'# retune {name}', '', f'models: `{models or "repository"}`  head: `{git_head()}`', '']
    diff = {k: (DEFAULTS[k], v) for k, v in fitted.items() if v != DEFAULTS[k]}
    L += ['## Fitted knobs (train folds only)', '']
    L += [f'- `{k}`: {fmt(a)} -> {fmt(b)}' for k, (a, b) in diff.items()] or ['- none changed']
    L += ['', '## Render items (reclass compare.py: net = gains - losses; > noise is a real change)', '',
          '| comparison | split | net | noise | changed blocks | losses |', '|---|---|---|---|---|---|']
    for c, per in cmp.items():
        for s, r in per.items():
            L.append(f"| {c} | {s} | {r['net']:+d} | {r['noise']:.0f} | {r['changed']} | {r['losses']} |")
    L += ['', '## Typeset score (typeset_score.py: share of GT regions typeset correctly; a 95% interval off 0 is a real change)', '',
          '| comparison | split | base | new | difference | 95% interval | aspects that moved |', '|---|---|---|---|---|---|---|']
    for c, per in tcmp.items():
        for s, t in per.items():
            moved = ', '.join(f'{k} {v:+.2f}' for k, v in t['aspects'].items() if abs(v) >= 0.1) or '-'
            L.append(f"| {c} | {s} | {t['base']} | {t['var']} | {t['diff']:+.3f} | {t['low']:+.3f} .. {t['high']:+.3f} | {moved} |")
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
    L += ['', 'If new0/fitted is clearly worse than ref here, retrain the learned parts on the new models\' outputs, in',
          'pipeline order, with `retune/retrain.py NAME` (trainers in tools/retrain/<part>/train.py; `--plan` lists them):',
          '- S2b line joiner (PipelineLineJoin.json), S3 keep gate (PipelineLineKeep.json), S3 line boxes (PipelineLineBoxes.json)',
          '- S4 grouping (PipelineGrouping.json), S4b interior (PipelineInterior.json)',
          '- S6 line ends (PipelineLineEnds.json + PipelineWeights.bin slot 4; re-fit lineEndMargin here afterwards)',
          '- S8 font size (PipelineFontSize.json; fontLevel shifts its level), outline (PipelineOutlineWidth.json),',
          '  fill (PipelineFillPeaks.json + PipelineWeights.bin fill forests)',
          'Not covered by retrain.py: S6 MaskNet (tools/convmask: prep.py -> train.py -> convert.py; maskThreshold here),',
          'the outline presence forest (outline/train.py --full only), the n-gram arbiter gates and the S8 bold rule.',
          '', f'## Sweep log ({len(history)} candidates)', '']
    for h in history:
        L.append(f"- {h['knob']} {fmt(h['base'])} -> {fmt(h['value'])}: {'PASS' if h['passes'] else 'no'} — {h['why']}")
    L += ['', 'Apply: set the fitted values as the defaults in `PipelineTuning.swift` (and DEFAULTS in retune.py), '
          'run the fast iOS tests, commit.']
    (out / 'report.md').write_text('\n'.join(L) + '\n')


if __name__ == '__main__':
    main()
