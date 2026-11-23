#!/usr/bin/env python3
"""Score V2 paragraph grouping (pages/*.json blocks, e.g. --ocr-only runs) against the user-reviewed merge GT.

GT: user-reviewed merge GT (split11 v8) in the unified GT file, via unified_merge_gt. Each GT region is a legacy OCR region (rect normalized to the
page); its target group is a user merge group or itself (evaluation_region_ids / regions minus excluded_regions;
split regions are already replaced). Each V2 line is mapped to the GT region covering most of it (>= 50% of the
line box; ties -> smaller region). Lines covering no GT region (filtered/SFX/excluded) are ignored.

Per page:
- region partition = each matched GT region assigned to the V2 block holding most of its mapped line characters
- fragmented region = lines of one GT region spread over >1 V2 block
- exact page = no fragmented region and region partition == GT partition (restricted to matched regions)
- region pairs: pairs of matched GT regions, positive = same GT group; joined = same dominant V2 block
- line pairs: pairs of mapped V2 lines, positive = same GT group; joined = same V2 block (sees fragmentation)

Usage: merge_gt_eval.py RUN [RUN...] [--pages] [--json OUT]
Several RUN dirs (e.g. dev + train) are pooled; rows are split by manifest split, train fold, and reviewed.
Test pages are skipped. `score(runs)` returns the per-page records for reuse.
"""
import json
import sys
from collections import defaultdict
from pathlib import Path

import unified_merge_gt

from workspace import MANIFEST  # noqa: E402


def load_gt():
    data = unified_merge_gt.load()
    reviewed = set(data['review_pages'])
    pages = {}
    for p in data['pages']:
        if p['status'] == 'excluded':
            continue
        excluded = set(p.get('excluded_regions') or [])
        ids = p.get('evaluation_region_ids') or [r['id'] for r in p['regions'] if r['id'] not in excluded]
        rects = {r['id']: r['rect'] for r in p['regions']}
        group = {i: i for i in ids}
        for members in p.get('merge_groups') or []:
            for m in members:
                group[m] = members[0]
        pages[p['page']] = dict(rects={i: rects[i] for i in ids}, group=group, reviewed=p['page'] in reviewed)
    return pages


def load_split():
    return {p['page_id']: (p['split'], p.get('fold')) for p in json.loads(MANIFEST.read_text())['pages']}


def cover(line, region):
    (x, y), (w, h) = line
    ix = max(0, min(x + w, region[2]) - max(x, region[0]))
    iy = max(0, min(y + h, region[3]) - max(y, region[1]))
    return ix * iy / (w * h) if w * h > 0 else 0


def pairs(labels, truth):
    """labels: list of (predicted, truth) keys -> (tp, predicted-joined, gt-joined)."""
    tp = pj = gj = 0
    for i in range(len(labels)):
        for j in range(i + 1, len(labels)):
            p = labels[i][0] == labels[j][0]
            t = truth[i] == truth[j]
            tp += p and t
            pj += p
            gj += t
    return tp, pj, gj


def score_page(record, gt):
    W, H = record['width'], record['height']
    regions = {i: (r['x'] * W, r['y'] * H, (r['x'] + r['width']) * W, (r['y'] + r['height']) * H)
               for i, r in gt['rects'].items()}
    lines = []  # (block, region, chars)
    for block in record.get('blocks') or []:
        for line in block['lines']:
            best = max(((cover(line['bounds'], box), -(box[2] - box[0]) * (box[3] - box[1]), rid)
                        for rid, box in regions.items()), default=None)
            if best and best[0] >= 0.5:
                lines.append((block['id'], best[2], max(1, len(line.get('text') or ''))))
    weight = defaultdict(lambda: defaultdict(int))
    for b, rid, n in lines:
        weight[rid][b] += n
    dominant = {rid: max(w.items(), key=lambda kv: (kv[1], -kv[0]))[0] for rid, w in weight.items()}
    fragmented = sorted(rid for rid, w in weight.items() if len(w) > 1)
    matched = sorted(dominant)
    g = gt['group']
    rtp, rpj, rgj = pairs([(dominant[r], None) for r in matched], [g[r] for r in matched])
    ltp, lpj, lgj = pairs([(b, None) for b, _, _ in lines], [g[r] for _, r, _ in lines])
    pred_sets = defaultdict(set)
    true_sets = defaultdict(set)
    for r in matched:
        pred_sets[dominant[r]].add(r)
        true_sets[g[r]].add(r)
    exact = not fragmented and sorted(map(sorted, pred_sets.values())) == sorted(map(sorted, true_sets.values()))
    wrong = [sorted(s) for s in pred_sets.values() if len({g[r] for r in s}) > 1]
    missed = [sorted(s) for s in true_sets.values() if len({dominant[r] for r in s}) > 1]
    return dict(page=record['pageID'], exact=exact, matched=len(matched), unmatched=len(regions) - len(matched),
                fragmented=fragmented, wrongJoins=wrong, missedJoins=missed,
                region=(rtp, rpj, rgj), line=(ltp, lpj, lgj))


def score(runs):
    gt, split = load_gt(), load_split()
    out = []
    for run in runs:
        for f in sorted(Path(run, 'pages').glob('*.json')):
            record = json.loads(f.read_text())
            page = record.get('pageID') or f.stem
            if page not in gt or split.get(page, ('test',))[0] == 'test' or 'blocks' not in record:
                continue
            row = score_page(record, gt[page])
            row['split'], row['fold'] = split[page]
            row['reviewed'] = gt[page]['reviewed']
            out.append(row)
    return out


def summarize(rows):
    s = dict(pages=len(rows), exact=sum(r['exact'] for r in rows))
    for k in ('region', 'line'):
        tp, pj, gj = (sum(r[k][i] for r in rows) for i in range(3))
        s[k + 'P'] = tp / pj if pj else 1
        s[k + 'R'] = tp / gj if gj else 1
    s['frag'] = sum(len(r['fragmented']) for r in rows)
    s['wrong'] = sum(len(r['wrongJoins']) for r in rows)
    s['missed'] = sum(len(r['missedJoins']) for r in rows)
    return s


def subsets(rows):
    yield 'all', rows
    for sp in ('train', 'dev'):
        part = [r for r in rows if r['split'] == sp]
        if not part:
            continue
        yield sp, part
        yield sp + '-reviewed', [r for r in part if r['reviewed']]
        if sp == 'train':
            for fold in sorted({r['fold'] for r in part}):
                yield f'fold{fold}', [r for r in part if r['fold'] == fold]
                yield f'fold{fold}-rev', [r for r in part if r['fold'] == fold and r['reviewed']]


def main():
    args = sys.argv[1:]
    runs = [a for a in args if not a.startswith('--') and not a.endswith('.json')]
    rows = score(runs)
    name = '+'.join(Path(r).name for r in runs)
    print(name)
    for label, part in subsets(rows):
        s = summarize(part)
        print(f"  {label:>14} pages {s['pages']:4} exact {s['exact']:4} ({s['exact'] / max(1, s['pages']):.3f}) "
              f"region P {s['regionP']:.3f} R {s['regionR']:.3f} | line P {s['lineP']:.4f} R {s['lineR']:.4f} | "
              f"frag {s['frag']:4} wrong {s['wrong']:4} missed {s['missed']:3}")
    if '--pages' in args:
        for r in rows:
            if r['reviewed'] and not r['exact']:
                print(f"  {r['split']} {r['page']} frag {r['fragmented']} wrong {r['wrongJoins']} missed {r['missedJoins']}")
    if '--json' in args:
        Path(args[args.index('--json') + 1]).write_text(json.dumps(rows, indent=1))


if __name__ == '__main__':
    main()
