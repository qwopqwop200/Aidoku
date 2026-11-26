#!/usr/bin/env python3
"""retrain.py NAME [--only a,b] [--start COMPONENT] [--check] [--plan] [--no-final]

Retrains the learned pipeline parts in pipeline order after an upstream change (a new model, a new stage), so each
part is fitted on the outputs of the already retrained parts before it:
  S2b assembly -> S3 line keep -> S3 line boxes -> S4 grouping -> S4b interior -> S6 line ends -> S8 font size,
  outline, fill
Each part has a trainer in tools/retrain/<part>/train.py with a SPEC dict (stage, resource, inputs, needs_full,
rerun_from); see port-eval/stageopt/RETRAIN.md. Before each part the driver makes the host run it reads:
  - S2b / S3*: a fresh --ocr-only --save-stages run (S1-S4b on the current resources)
  - S4b: an S4-only rerun of that run (--from s4)
  - S6 / S8: a full --replay-translations --no-png --save-stages run (S8 parts refresh it with --from s8)
A run is remade only when a part before it changed. Trainers fit on train pages only and print their dev/test
metric (--eval). Old resources are copied to runs/retune/NAME/backup first; --check trains without writing.
The final step compares the retrained set against the backed-up one (full train/dev/test runs: render items,
merge GT, masks, font size, colour) in NAME/report.md. Re-fit the PipelineTuning knobs afterwards with retune.py.
"""
import argparse, importlib.util, json, os, shutil, subprocess, sys
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(TOOLS))
from workspace import EVAL as E, REPO, PYTHON, MASK_PYTHON, MANIFEST, REPLAY  # noqa: E402

RUNS = E / 'runs/retune'
ORDER = ['S2b', 'S3keep', 'S3refine', 'S4', 'S4b', 'S6', 'S8']
FRONT, S4ONLY, FULL = 'front', 's4', 'full'
SPLITS = ('train', 'dev', 'test')


def log(out, msg):
    print(msg, flush=True)
    with open(out / 'log.txt', 'a') as f:
        f.write(msg + '\n')


def parts():
    """The trainers in pipeline order (ORDER, then name)."""
    found = []
    for t in sorted((TOOLS / 'retrain').glob('*/train.py')):
        spec = importlib.util.spec_from_file_location(f'retrain_{t.parent.name}', t)
        m = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(m)
        s = dict(m.SPEC)
        s.setdefault('name', t.parent.name)
        s['trainer'] = t
        res = s['resource']
        # Entries may carry a note after the path ("PipelineWeights.bin (forest slots 0, 1)").
        s['resource'] = [r.split(' (')[0].strip() for r in ([res] if isinstance(res, str) else list(res))]
        assert s['stage'] in ORDER, f"{t}: unknown stage {s['stage']}"
        found.append(s)
    return sorted(found, key=lambda s: (ORDER.index(s['stage']), s['name']))


def kind_for(part):
    if part.get('needs_full') or part['stage'] in ('S6', 'S8'):
        return FULL
    if part['stage'] == 'S4b':
        return S4ONLY
    return FRONT


def host(out, prefix, argsfor, env=None, label='run'):
    """One host run per split into PREFIX_SPLIT, in one heavy slot each (tools/lock.zsh). argsfor(split) -> args."""
    for split in SPLITS:
        d = Path(f'{prefix}_{split}')
        shutil.rmtree(d, ignore_errors=True)
        d.parent.mkdir(parents=True, exist_ok=True)
        cmd = (f'source {TOOLS}/lock.zsh; take_slot retrain-{d.name[:40]}; cd {REPO}; '
               f'swift Scripts/image-translation.swift --split {split} --manifest {MANIFEST} {argsfor(split)} --output {d} '
               f'> {d}.log 2>&1; st=$?; rm -rf "${{slot:?}}"; exit $st')
        r = subprocess.run(['zsh', '-c', cmd], env=dict(os.environ, **(env or {})))
        if r.returncode != 0 or not (d / 'summary.json').exists():
            raise RuntimeError(f'{label} failed: {d} (see {d}.log)')
    log(out, f'   {label}: {prefix}')
    return str(prefix)


REPLAYARGS = f'--no-png --save-stages --replay-translations {REPLAY} --replay-fill-unmatched'


def make_run(out, kind, step, runs, extra):
    """The run a part reads (kind FRONT / S4ONLY / FULL). extra: a part's own input-run args/env (SPEC input_run).
    FULL reruns from runs['full_from'] (s5 after S6, s8 after S8) when a full run exists."""
    prefix = out / f'{kind}{step:02d}{"x" if extra else ""}'
    args, env = extra.get('args', ''), extra.get('env')
    if kind == FRONT:
        return host(out, prefix, lambda s: f'--jobs 4 --ocr-only --no-png --save-stages {args}', env, 'front run')
    if kind == S4ONLY:
        base = runs['s13']
        return host(out, prefix, lambda s: f'--jobs 8 --ocr-only --no-png --save-stages --from-stages {base}_{s} --from s4 {args}',
                    env, 's4 rerun')
    base, frm = runs.get('full_base'), runs.get('full_from')
    if base and frm:
        return host(out, prefix, lambda s: f'--jobs 4 {REPLAYARGS} --from-stages {base}_{s} --from {frm} {args}', env,
                    f'full rerun from {frm}')
    return host(out, prefix, lambda s: f'--jobs 4 {REPLAYARGS} {args}', env, 'full run')


RASTERS = E / 'retrain/interior/cgraw'  # the app's S4 gray raster per page (page pixels only, run-independent)


def ensure_rasters(out):
    """S4b and the line-box trainer read PipelineGrayRaster pixels; dump the pages that lack one (Swift, once)."""
    pages = json.load(open(MANIFEST))['pages']
    miss = [p for p in pages if not (RASTERS / f"{p['page_id']}.raw").exists() or not (RASTERS / f"{p['page_id']}.size").exists()]
    if not miss:
        return
    RASTERS.mkdir(parents=True, exist_ok=True)
    lst = out / 'raster-list.tsv'
    lst.write_text(''.join(f"{p['page_id']}\t{p['image_path']}\n" for p in miss))
    subprocess.run(['swift', str(TOOLS / 'retrain/interior/rasterdump.swift'), str(lst), str(RASTERS)], check=True,
                   capture_output=True)
    log(out, f'   rasters: {len(miss)} pages dumped to {RASTERS}')


use_augment = True


def augment_spec(part):
    """The part's adopted SPEC['augment'] (tools/retrain/augment.py), with mix runs that do not exist dropped."""
    spec = part.get('augment')
    if not spec:
        return None
    sys.path.insert(0, str(TOOLS / 'retrain'))
    import augment
    parts = []
    for item in spec.split(';'):
        key, _, value = item.partition('=')
        if key.strip() == 'mix':
            runs = [r for r in value.split(',') if augment.available([r])]
            if runs:
                parts.append('mix=' + ','.join(runs))
        else:
            parts.append(item)
    return ';'.join(parts) or None


def train(out, part, prefix, check):
    py = str(MASK_PYTHON if part.get('python') == 'mask' else PYTHON)
    cmd = [py, str(part['trainer']), prefix, '--eval'] + (['--check'] if check else []) + list(part.get('train_args', []))
    if part['name'] in ('interior', 'linebox'):
        cmd += ['--raster', str(RASTERS)]
    aug = augment_spec(part) if use_augment else None
    if aug:
        cmd += ['--augment', aug]
    r = subprocess.run(cmd, capture_output=True, text=True, cwd=str(REPO))
    (out / f"{part['name']}.train.log").write_text(r.stdout + '\n--- stderr ---\n' + r.stderr)
    if r.returncode != 0:
        raise RuntimeError(f"trainer {part['name']} failed (see {out / (part['name'] + '.train.log')})")
    tail = [l for l in r.stdout.splitlines() if l.strip()][-12:]
    for l in tail:
        log(out, f'     {l}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('name')
    ap.add_argument('--only', help='comma-separated part names (default: all, in pipeline order)')
    ap.add_argument('--start', help='first part to retrain (earlier ones are kept as they are)')
    ap.add_argument('--check', action='store_true', help='train and compare with the current resources; write nothing')
    ap.add_argument('--plan', action='store_true')
    ap.add_argument('--no-final', action='store_true', help='skip the final old-vs-retrained comparison')
    ap.add_argument('--no-augment', action='store_true', help="ignore the parts' SPEC['augment'] (train on the run alone)")
    a = ap.parse_args()
    global use_augment
    use_augment = not a.no_augment
    ps = parts()
    if a.only:
        keep = set(a.only.split(','))
        assert keep <= {p['name'] for p in ps}, f'unknown parts {keep - {p["name"] for p in ps}}'
        ps = [p for p in ps if p['name'] in keep]
    if a.start:
        names = [p['name'] for p in ps]
        assert a.start in names, a.start
        ps = ps[names.index(a.start):]
    out = RUNS / a.name
    if a.plan:
        for p in ps:
            aug = augment_spec(p) if use_augment else None
            print(f"{p['stage']:8} {p['name']:10} {kind_for(p):5} -> {', '.join(p['resource'])} | augment {aug or '-'}")
        return
    out.mkdir(parents=True, exist_ok=True)
    backup = out / 'backup'
    if not backup.exists():
        for p in parts():
            for r in p['resource']:
                src = REPO / r
                if src.exists():
                    (backup / r).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(src, backup / r)
    log(out, f"== retrain {a.name}: {', '.join(p['name'] for p in ps)}{' (check only)' if a.check else ''}")

    # The ref run for the final comparison is made on the old resources, before anything is written.
    if not a.no_final and not a.check and not Path(f'{out}/ref_train/summary.json').exists():
        host(out, out / 'ref', lambda s: f'--jobs 4 {REPLAYARGS}', None, 'ref run')

    ensure_rasters(out)
    runs = {}  # valid runs on the current resources: FRONT / S4ONLY / FULL -> prefix
    for step, p in enumerate(ps):
        kind = kind_for(p)
        extra = p.get('input_run') or {}
        if extra:
            prefix = make_run(out, kind, step, runs, extra)  # a part's own input run is never shared
        else:
            if kind == S4ONLY and 's13' not in runs:  # S1-S3 saved on the current resources
                runs[FRONT] = runs['s13'] = make_run(out, FRONT, step, runs, {})
            if kind not in runs:
                runs[kind] = make_run(out, kind, step, runs, {})
                if kind == FRONT:
                    runs['s13'] = runs[kind]
                runs.pop('full_from', None)
            prefix = runs[kind]
        log(out, f"-- {p['stage']} {p['name']}: train on {prefix}")
        train(out, p, prefix, a.check)
        if a.check:
            continue
        # Runs that read this part's output are no longer valid.
        stage = p['stage']
        if ORDER.index(stage) <= ORDER.index('S4'):
            for k in (FRONT, S4ONLY, FULL) + (('s13',) if ORDER.index(stage) <= ORDER.index('S3refine') else ()):
                runs.pop(k, None)
            runs.pop('full_base', None)
        elif stage == 'S4b':
            for k in (S4ONLY, FULL):
                runs.pop(k, None)
            runs.pop('full_base', None)
        else:  # S6 / S8: a full rerun from s5 / s8 of the last full run
            frm = 's5' if stage == 'S6' else 's8'
            if FULL in runs:
                runs['full_base'], runs['full_from'] = runs.pop(FULL), frm

    if a.check or a.no_final:
        return
    # Final: retrained vs old resources on full runs (same scorers as retune.py's final step).
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import retune as R
    new = host(out, out / 'new', lambda s: f'--jobs 4 {REPLAYARGS}', None, 'new run')
    rows, cmp = {}, {}
    for n, pre in (('old', str(out / 'ref')), ('retrained', new)):
        dirs = {s: Path(f'{pre}_{s}') for s in SPLITS}
        row = {s: dict(detection=R.detection(dirs[s], s), font=R.font(dirs[s])) for s in SPLITS}
        row['merge'] = {s: R.merge_gt(dirs[s], s) for s in ('dev', 'train')}
        row['colour'] = R.colour(pre)
        rows[n] = row
    cmp = {s: R.render_cmp(f'{out}/ref_{s}', f'{new}_{s}', s) for s in SPLITS}
    (out / 'final.json').write_text(json.dumps(dict(rows=rows, compare=cmp), indent=1, default=str))
    L = [f'# retrain {a.name}', '', '| split | render net | noise | changed blocks | losses |', '|---|---|---|---|---|']
    for s, r in cmp.items():
        L.append(f"| {s} | {r['net']:+d} | {r['noise']:.0f} | {r['changed']} | {r['losses']} |")
    L += ['', '| set | split | recall@0.5 | group F1 | font median | font >10% | merge exact | line R |', '|---|---|---|---|---|---|---|---|']
    for n, row in rows.items():
        for s in SPLITS:
            d, f = row[s]['detection'], row[s]['font']
            m = row['merge'].get(s, {})
            L.append(f"| {n} | {s} | {d['recall50']} | {d['groupF1']} | {f['median']} | {f['over10']} | {m.get('exact', '')} | {m.get('lineR', '')} |")
    L += ['', f"colour old {rows['old']['colour']} retrained {rows['retrained']['colour']}",
          '', f'Old resources: {backup} (copy back to undo).']
    (out / 'report.md').write_text('\n'.join(L) + '\n')
    log(out, f'report: {out / "report.md"}')


if __name__ == '__main__':
    main()
