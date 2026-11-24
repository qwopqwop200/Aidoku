#!/usr/bin/env python3
"""Typesetting metrics for a V2 run (JSON only, no pixels).

wordCuts: line breaks that fall inside a whitespace-delimited word.
kinsoku: lines starting with closing punctuation or ending with opening punctuation.
punctOnly: lines that hold only punctuation.
fontRatio: placed px / source px (median, share < 0.6).
overlaps: pairs of painted frames that intersect by > 0.5 px.
Per-fold breakdown with --by-work.
"""
import collections, json, statistics, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))  # tools dir
from workspace import MANIFEST  # noqa: E402

CLOSE = set('!?,.。、，．！？…‥」』）)]】〉》〕"’”~ー・:;' + "'")
OPEN = set('「『（([【〈《〔‘“')


def is_punct(s):
    return s and all(c in CLOSE or c in OPEN or c in '-—―' for c in s)


def analyze(run):
    rows = []
    for f in sorted(Path(run, 'pages').glob('*.json')):
        r = json.load(open(f))
        blocks = {b['id']: b for b in r['blocks']}
        synth = set(r.get('replaySyntheticBlocks') or [])
        frames = []
        for p in r.get('placed', []):
            b = blocks.get(p['blockID'])
            if b is None or p['blockID'] in synth:
                continue
            text = b.get('translation') or ''
            lines = p['lines']
            bounds, pos = set(), 0
            for w in text.split():
                pos += len(w)
                bounds.add(pos)
            cuts = pos = 0
            for ln in lines[:-1]:
                pos += len(''.join(ln.split()))
                if pos not in bounds:
                    cuts += 1
            kin = sum(1 for i, ln in enumerate(lines) if (i > 0 and ln.strip() and ln.strip()[0] in CLOSE)
                      or (i < len(lines) - 1 and ln.strip() and ln.strip()[-1] in OPEN))
            pun = sum(1 for ln in lines if is_punct(ln.strip())) if len(lines) > 1 else 0
            src = (b.get('style') or {}).get('fontPixels') or 0
            ratio = p['fontPixels'] / src if src else None
            (x, y), (w, h) = p['frame']
            frames.append((x, y, x + w, y + h))
            rows.append(dict(page=r['pageID'], block=p['blockID'], cuts=cuts, kin=kin, pun=pun, lines=len(lines),
                             ratio=ratio, vertical=p['vertical'], floor=p['fontPixels'] <= 10.01,
                             outside=x < -0.5 or y < -0.5 or x + w > r['width'] + 0.5 or y + h > r['height'] + 0.5))
        ov = 0
        for i in range(len(frames)):
            for j in range(i + 1, len(frames)):
                a, c = frames[i], frames[j]
                if min(a[2], c[2]) - max(a[0], c[0]) > 0.5 and min(a[3], c[3]) - max(a[1], c[1]) > 0.5:
                    ov += 1
        if rows:
            rows[-1]['pageOverlaps'] = ov
    return rows


def summarize(rows):
    n = len(rows)
    ratios = [r['ratio'] for r in rows if r['ratio']]
    return dict(owners=n, wordCuts=sum(r['cuts'] for r in rows), ownersWithCuts=sum(r['cuts'] > 0 for r in rows),
                kinsoku=sum(r['kin'] for r in rows), punctOnlyLines=sum(r['pun'] for r in rows),
                rows=sum(r['lines'] for r in rows), vertical=sum(r['vertical'] for r in rows),
                floor=sum(r['floor'] for r in rows), outside=sum(r['outside'] for r in rows),
                overlaps=sum(r.get('pageOverlaps', 0) for r in rows),
                fontRatioMedian=round(statistics.median(ratios), 4) if ratios else 0,
                fontRatioMean=round(statistics.mean(ratios), 4) if ratios else 0,
                fontRatioBelow06=sum(x < 0.6 for x in ratios))


if __name__ == '__main__':
    rows = analyze(sys.argv[1])
    print(json.dumps(summarize(rows), indent=1))
    if '--by-work' in sys.argv:
        fold = {p['page_id']: p.get('fold', '?') for p in json.load(open(MANIFEST))['pages']}
        by = collections.defaultdict(list)
        for r in rows:
            by[fold.get(r['page'], '?')].append(r)
        for g, rs in sorted(by.items()):
            s = summarize(rs)
            print(g, s['owners'], 'cuts', s['wordCuts'], 'kin', s['kinsoku'], 'pun', s['punctOnlyLines'],
                  'ratio', s['fontRatioMedian'])
