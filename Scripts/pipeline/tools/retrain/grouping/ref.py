#!/usr/bin/env python3
"""ref.py RUN_PREFIX OUT [--model PATH] [--cmp FIELD] [--swift PREFIX]

Python reference of the app's S4 (PipelineParagraphGrouping.group with PipelineGrouping.json, default the repo
resource) on every saved page of RUN_PREFIX_{train,dev,test}/stages/*.front.json: groups of front.recognized indices
(block members plus their ruby readings; lines S4 cannot use stand alone) -> OUT {"split/page": [[index...], ...]}.

--cmp FIELD  also compares with the Swift blocks of the same run: FIELD = classified | blocks (front checkpoint) or
             pages (pages/ID.json); block lines map back to recognized indices by rounded bounds.
--swift      the run whose pages/ID.json --cmp pages reads (default RUN_PREFIX), e.g. an S4-only rerun from these stages.
"""
import argparse, json, sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import s4  # noqa: E402


def swift_groups(blocks, rec):
    key = {}
    for k, l in enumerate(rec): key.setdefault(tuple(round(v) for v in l['bounds'][0] + l['bounds'][1]), []).append(k)
    groups, used = [], set()
    for b in blocks:
        g = []
        for l in b['lines']:
            ks = [k for k in key.get(tuple(round(v) for v in l['bounds'][0] + l['bounds'][1]), []) if k not in used]
            if ks: g.append(ks[0]); used.add(ks[0])
        if g: groups.append(sorted(g))
    return sorted(groups + [[k] for k in range(len(rec)) if k not in used])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('run_prefix'); ap.add_argument('out'); ap.add_argument('--model')
    ap.add_argument('--cmp', choices=('classified', 'blocks', 'pages')); ap.add_argument('--swift')
    a = ap.parse_args()
    model = s4.load_model(a.model); out = {}; same = 0; diff = []
    for split in ('train', 'dev', 'test'):
        for pid, front in s4.fronts(a.run_prefix, split):
            g = out[f'{split}/{pid}'] = s4.app_groups(front, model)
            if a.cmp:
                blocks = (json.load(open(f'{a.swift or a.run_prefix}_{split}/pages/{pid}.json'))['blocks'] if a.cmp == 'pages'
                          else front.get(a.cmp) or [])
                if swift_groups(blocks, front.get('recognized') or []) == g: same += 1
                else: diff.append(pid)
    Path(a.out).write_text(json.dumps(out))
    print(len(out), 'pages ->', a.out)
    if a.cmp: print(f'Swift {a.cmp}: same {same}, differ {len(diff)}', diff[:30])


if __name__ == '__main__':
    main()
