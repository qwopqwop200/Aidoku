from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # tools dir
from workspace import RUNS  # noqa: E402
import json, collections, sys
from errors import pairs, de
from sim import FOLD
def dump(prefix):
    D = {}
    for s in ('dev', 'train', 'test'):
        for line in open(f'{prefix}_{s}.log', errors='ignore'):
            if line.startswith('STYLEDUMP '):
                r = json.loads(line[10:]); D[(r['page'], r['block'])] = r
    return D
if __name__ == '__main__':
    pre = str(RUNS / 'imp/rawdump')
    D = dump(pre); P = pairs(pre)
    c = collections.Counter(); rows = []
    for p in P:
        r = D.get((p['page'], p['block']))
        if not r: c['nodump'] += 1; continue
        cands = sorted(r['cands'], key=lambda q: -q['logit'])
        best = min(cands, key=lambda q: de(q['core'], p['fill']))
        ok = de(p['pfill'], p['fill']) <= 12
        reach = de(best['core'], p['fill']) <= 12
        rank = [q['j'] for q in cands].index(best['j'])
        c[('ok' if ok else 'bad', 'reachable' if reach else 'unreachable')] += 1
        if not ok: rows.append((p, r, cands, best, reach, rank))
    print(c)
    for p, r, cands, best, reach, rank in rows:
        if '--list' in sys.argv:
            print(p['id'], FOLD[p['page']], 'gt', p['fill'], 'pick', [round(v) for v in cands[0]['core']], round(cands[0]['logit'], 2),
                  '| best', [round(v) for v in best['core']], round(de(best['core'], p['fill'])), 'logit', round(best['logit'], 2), 'rank', rank, 'of', len(cands),
                  'font', round(r['font']), 'scale', round(r['scale'], 2), 'stroke', p['stroke'])
