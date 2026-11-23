"""compare.py on the test split (fold 5): cmp_test.py BASE_PREFIX VAR_PREFIX"""
import sys, json, collections
sys.path.insert(0, str(__import__('pathlib').Path(__file__).resolve().parent))
import compare
for p in json.load(open(compare.MAN))['pages']:
    if p['split'] == 'test': compare.FOLD[p['page_id']] = 5
b, v = sys.argv[1], sys.argv[2]
B, V, pages, g, l, nchg, chpages = compare.compare(f'{b}_test,{b}_test', f'{v}_test,{v}_test')
G = sum(g.values(), collections.Counter()); L = sum(l.values(), collections.Counter())
print(f'test {v.split("/")[-1]} vs {b.split("/")[-1]}: changed {sum(nchg.values())} net {sum(G.values()) - sum(L.values()):+d} gains {dict(G)} losses {dict(L)}')
