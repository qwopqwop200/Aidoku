"""Python S4 (PipelineParagraphGrouping.swift) shared by train.py and ref.py: the cascade over line pairs (rule
core, 7-feature logistic resolver, fallback rule in its unsure band), the hyb residual rules (R1cf stacked piece in
one RF text box joins, R2 horizontal CJK pitch veto, R4cf misoriented-row bridges), ruby rails, and the data loaders
(a run's front.recognized lines, GT line boxes and paragraphs from the unified GT).

Ported from the grouping benchmark (cascade_abstain, featsel 7-feature mask) and stageopt/grouping2 (hyb)."""
import glob, json, os, pickle, sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[2]))  # tools dir
import workspace  # noqa: E402

RESOURCE = 'Aidoku/Resources/Translation/PipelineGrouping.json'
FEATURES = ['gap_med', 'head', 'rftext_same', 'balloon_same', 'A_end', 'min_cjk', 'max_wn']
END = set('。．.！!？?…‥」』）)〉》】♡♥♪')
MAXGAP = STACKGAP = 3.0
CORE = dict(GAP=0.45, OV=0.9, WR=1.3, OWR=2.0)
FB = dict(TGAP=0.5, TOV=0.75, OV=0.9, OVW=0.7, VGAP=0.55, VGAP_AL=0.9, ALIGN=0.8, HGAP=1.2, WRMAX=3.2)
RANK = 0.3
R2_CJK = 0.5


def frac(b, r):
    ix = max(0, min(b[2], r[2]) - max(b[0], r[0])) * max(0, min(b[3], r[3]) - max(b[1], r[1]))
    return ix / max(1e-6, (b[2] - b[0]) * (b[3] - b[1]))


def _cjk(ch):
    o = ord(ch)
    return 0x2E80 <= o <= 0xA4CF or 0xAC00 <= o <= 0xD7AF or 0xF900 <= o <= 0xFAFF or 0xFF00 <= o <= 0xFFEF


def _prep(layout, lines):
    th = sorted(min(l['box'][2] - l['box'][0], l['box'][3] - l['box'][1]) for l in lines)
    med = max(1.0, th[len(th) // 2]) if th else 1.0
    scope = [r['box'] for r in layout if r['kind'] in ('text', 'balloon')]
    texts = [r['box'] for r in layout if r['kind'] == 'text']
    balloons = [r['box'] for r in layout if r['kind'] == 'balloon']
    sfx = [r['box'] for r in layout if r['kind'] == 'sfx']

    def owner(b, regions):
        k = max(range(len(regions)), key=lambda q: frac(b, regions[q]), default=-1)
        return k if k >= 0 and frac(b, regions[k]) >= 0.5 else -1
    G, info = [], []
    for l in lines:
        b = l['box']; x0, y0, x1, y1 = b
        g = (-x1, -x0, y0, y1) if l['vertical'] else (y0, y1, x0, x1)
        w = g[1] - g[0]; t = ''.join((l.get('text') or '').split())
        tfr = max((frac(b, r) for r in scope), default=0.0)
        sf = max((frac(b, r) for r in sfx), default=0.0)
        wn = w / med
        junk = bool((tfr < 0.5 and (wn > 1.6 or l['conf'] < 0.8 or sf > 0.5)) or (tfr < 0.9 and wn > 1.6))
        nc = len(t)
        G.append(g)
        info.append(dict(w=max(1.0, w), v=bool(l['vertical']), junk=junk, wn=wn,
                         mem=frozenset(k for k, r in enumerate(scope) if frac(b, r) >= 0.8),
                         bt=owner(b, texts), bb=owner(b, balloons), n=nc, endc=int(nc > 0 and t[-1] in END),
                         cjk=(sum(map(_cjk, t)) / nc) if nc else 0.0,
                         pitch=(max(1.0, g[3] - g[2]) / nc) if nc else 0.0))
    return G, info, med


def _candidates(G, info):
    """oriented pairs (i, j): kind 0 = j is a next column/row of i, 1 = stacked in one column, 2 = overlap."""
    n = len(G); out = {}
    for i in range(n):
        u0, u1, v0, v1 = G[i]; wi = u1 - u0
        for j in range(n):
            if j == i or info[j]['v'] != info[i]['v']: continue
            a0, a1, b0, b1 = G[j]; wj = a1 - a0; w = (wi + wj) / 2
            ov = min(v1, b1) - max(v0, b0); uov = min(u1, a1) - max(u0, a0)
            if ov > 0 and uov > 0 and ov * uov > 0.3 * min(wi * (v1 - v0), wj * (b1 - b0)):
                if i < j: out[(i, j)] = 2
                continue
            if ov > 0 and a0 >= u0 + 0.5 * wi and a0 - u1 < MAXGAP * w:
                out[(i, j)] = 0
            elif uov > 0.5 * min(wi, wj) and b0 >= v1 - 0.2 * w and b0 - v1 < STACKGAP * w:
                out[(i, j)] = 1
    return out


def _fallback_links(G, info, cand):
    """each line links to its nearest next column passing hand geometry rules; an aligned (loose) link is dropped
    where the chain around it is over 3x tighter."""
    link = {}; byi = {}
    for (i, j), k in cand.items():
        if k == 0: byi.setdefault(i, []).append(j)
    for i, js in byi.items():
        if info[i]['junk']: continue
        u0, u1, v0, v1 = G[i]; wi = u1 - u0; cs = []
        for j in js:
            if info[j]['junk']: continue
            a0, a1, b0, b1 = G[j]; wj = a1 - a0
            cs.append((a0 - u1, j, min(v1, b1) - max(v0, b0), (wi + wj) / 2, abs(b0 - v0), min(v1 - v0, b1 - b0),
                       max(wi, wj) / max(1e-6, min(wi, wj))))
        for gap, j, ov, w, head, short, wr in sorted(cs):
            mi, mj = info[i]['mem'], info[j]['mem']
            if mi and mj and not (mi & mj): continue
            if wr > FB['WRMAX']: continue
            if not info[i]['v'] and wr > 1.2 and min(info[i]['n'], info[j]['n']) > 0 and max(info[i]['n'], info[j]['n']) <= 5:
                continue
            k = 0
            if gap < FB['TGAP'] * w and (ov >= FB['TOV'] * short or (ov >= 0.5 * short and wr < 1.5)): k = 1
            elif short - ov > max((1 - FB['OV']) * short, FB['OVW'] * w): k = 0
            elif info[i]['v']:
                k = 1 if gap < FB['VGAP'] * w else (2 if gap < FB['VGAP_AL'] * w and head < FB['ALIGN'] * w else 0)
            else:
                k = 1 if gap < FB['HGAP'] * w else 0
            if k:
                link[i] = (j, k, gap / w); break
    into = {}
    for i, (j, k, g) in link.items(): into.setdefault(j, []).append(g if k == 1 else None)
    acc = set()
    for i, (j, k, g) in link.items():
        if k == 2:
            adj = [x for x in into.get(i, []) if x is not None]
            if j in link and link[j][1] == 1: adj.append(link[j][2])
            if adj and min(adj) < 0.33 * g: continue
        acc.add((i, j))
    return acc


def _bridges(G, info):
    """R4cf: two vertical columns of one RF text box with >= 2 horizontal lines of that box centred between them (the
    detector read the middle columns as rows): join the columns and the rows."""
    n = len(G); out = []
    for i in range(n):
        A = info[i]
        if not A['v'] or A['junk'] or A['bt'] < 0: continue
        u0, u1, v0, v1 = G[i]
        for j in range(n):
            B = info[j]
            if j == i or not B['v'] or B['junk'] or B['bt'] != A['bt']: continue
            a0, a1, b0, b1 = G[j]; w = (A['w'] + B['w']) / 2
            if not (0.5 * w < a0 - u1): continue
            if min(v1, b1) - max(v0, b0) < 0.3 * min(v1 - v0, b1 - b0): continue
            br = []
            for m in range(n):
                if info[m]['v'] or info[m]['bt'] != A['bt']: continue
                y0, y1, x0, x1 = G[m]; cx = -(x0 + x1) / 2; cy = (y0 + y1) / 2
                if u1 < cx < a0 and max(v0, b0) - w < cy < min(v1, b1) + w: br.append(m)
            if len(br) >= 2: out += [(i, j)] + [(i, m) for m in br]
    return out


def page_data(layout, lines):
    """Per candidate pair: the 7 resolver features X, rule-core / fallback / eligible flags, the R1cf force flag, the
    R2 char pitches (max, min; (0, 1) where R2 does not apply); plus the R4cf bridges."""
    G, info, med = _prep(layout, lines)
    cand = _candidates(G, info)
    fb = _fallback_links(G, info, cand)
    n = len(G); outg = [9.0] * n; ing = [9.0] * n
    for (i, j), k in cand.items():
        if k != 0: continue
        w = (info[i]['w'] + info[j]['w']) / 2; g = (G[j][0] - G[i][1]) / w
        outg[i] = min(outg[i], g); ing[j] = min(ing[j], g)
    keys = list(cand); X, core, elig, isfb, force, ratio = [], [], [], [], [], []
    for (i, j) in keys:
        k = cand[(i, j)]; A, B = info[i], info[j]
        u0, u1, v0, v1 = G[i]; a0, a1, b0, b1 = G[j]
        w = (A['w'] + B['w']) / 2; wr = max(A['w'], B['w']) / min(A['w'], B['w'])
        if k == 1:
            gap = (b0 - v1) / w; ov = (min(u1, a1) - max(u0, a0)) / min(A['w'], B['w']); head = abs(a0 - u0) / w
        else:
            gap = (a0 - u1) / w; ov = (min(v1, b1) - max(v0, b0)) / max(1.0, min(v1 - v0, b1 - b0)); head = abs(b0 - v0) / w
        rank_i = gap - outg[i] if k == 0 else 0.0
        rank_j = gap - ing[j] if k == 0 else 0.0
        mi, mj = A['mem'], B['mem']; regdiff = bool(mi) and bool(mj) and not (mi & mj)
        same_text = A['bt'] >= 0 and A['bt'] == B['bt']
        X.append([gap * w / med, head, float(same_text), float(A['bb'] >= 0 and A['bb'] == B['bb']), A['endc'],
                  min(A['cjk'], B['cjk']), max(A['wn'], B['wn'])])
        nj = A['junk'] + B['junk']; f = (i, j) in fb
        c = (k == 0 and A['v'] and not nj and gap < CORE['GAP'] and ov >= CORE['OV']
             and wr < CORE['WR'] and not regdiff and rank_i <= 1e-9 and rank_j <= 1e-9)
        c = c or (f and A['v'] and gap < FB['VGAP'])
        c = c or (k == 2 and not nj and wr < CORE['OWR'] and ov >= 0.8 and not regdiff)
        c = c or (k != 1 and nj == 1 and ov >= 0.8 and gap < 0.5 and wr < 1.3)
        core.append(bool(c)); isfb.append(f)
        elig.append(k > 0 or min(rank_i, rank_j) <= RANK or f)
        force.append(k == 1 and A['v'] and same_text and not nj)
        r2 = k == 0 and not A['v'] and min(A['cjk'], B['cjk']) >= R2_CJK and min(A['n'], B['n']) >= 2
        ratio.append((max(A['pitch'], B['pitch']), min(A['pitch'], B['pitch'])) if r2 else (0.0, 1.0))
    m = len(keys)
    return dict(keys=keys, X=np.array(X, float).reshape(m, len(FEATURES)), core=np.array(core, bool),
                fb=np.array(isfb, bool), elig=np.array(elig, bool), force=np.array(force, bool),
                ratio=np.array(ratio, float).reshape(m, 2), n=n, junk=[x['junk'] for x in info], bridges=_bridges(G, info))


def union(n, edges):
    par = list(range(n))

    def find(i):
        while par[i] != i:
            par[i] = par[par[i]]; i = par[i]
        return i
    for i, j in edges:
        a, b = find(i), find(j)
        if a != b: par[b] = a
    return [find(i) for i in range(n)]


def proba(model, D):
    """resolver p per pair; model = dict(mean, scale, weights, bias)"""
    if not len(D['keys']): return np.zeros(0)
    z = ((D['X'] - np.asarray(model['mean'])) / np.asarray(model['scale'])) @ np.asarray(model['weights']) + model['bias']
    return 1 / (1 + np.exp(-z))


def decide(D, p, hi, lo, pitch):
    """join edges: rule core (+ R1cf); else the resolver joins p >= hi and defers lo < p < hi to the fallback rule;
    R2 (pitch ratio > pitch, None = off) vetoes the pair; a junk line joins only its strongest partner; + R4cf."""
    veto = D['ratio'][:, 0] > pitch * D['ratio'][:, 1] if pitch is not None else np.zeros(len(D['keys']), bool)
    join = (D['core'] | D['force']) & ~veto
    elig = D['elig'] & ~veto; fb = D['fb'] & ~veto
    if p is not None and len(p):
        amb = ~join & elig
        join |= amb & (p >= hi)
        join |= amb & (p > lo) & (p < hi) & fb
    else:
        join |= fb
    junk = D['junk']; best = {}; out = []
    for e in np.nonzero(join)[0]:
        i, j = D['keys'][e]
        if junk[i] or junk[j]:
            if junk[i] and junk[j]: continue
            jk = i if junk[i] else j
            s = p[e] if p is not None and len(p) else 1.0
            if jk not in best or s > best[jk][0]: best[jk] = (s, (i, j))
        else:
            out.append((i, j))
    return out + [v[1] for v in best.values()] + D['bridges']


def components(n, edges):
    root = union(n, edges); g = {}
    for i in range(n): g.setdefault(root[i], []).append(i)
    return list(g.values())


def page_exact(n, edges, ids, para):
    root = union(n, edges); blocks = {}; paras = {}
    for i in range(n):
        if ids[i] not in para: continue
        blocks.setdefault(root[i], set()).add(para[ids[i]]); paras.setdefault(para[ids[i]], set()).add(root[i])
    return all(len(v) == 1 for v in blocks.values()) and all(len(v) == 1 for v in paras.values())


def labels(D, ids, para):
    """pair label: 1 same GT paragraph, 0 different, -1 a line without GT paragraph"""
    y = np.full(len(D['keys']), -1)
    for e, (i, j) in enumerate(D['keys']):
        a, b = ids[i], ids[j]
        if a in para and b in para: y[e] = int(para[a] == para[b])
    return y


# ---------------------------------------------------------------- inputs

def box_of(bounds):
    (x, y), (w, h) = bounds
    return [x, y, x + w, y + h]


def front_layout(front):
    return [dict(kind=r['kind'], score=r['score'], box=box_of(r['bounds'])) for r in front['layout']]


def front_lines(front):
    """front.recognized as S4 lines (id = index in recognized)"""
    return [dict(id=k, box=box_of(l['bounds']), poly=l['polygon'], vertical=l['vertical'], text=l['text'],
                 conf=l['confidence']) for k, l in enumerate(front.get('recognized') or [])]


def fronts(prefix, split):
    """(page id, front dict) of RUN_PREFIX_split/stages/*.front.json, sorted"""
    for f in sorted(glob.glob(f'{prefix}_{split}/stages/*.front.json')):
        yield os.path.basename(f).split('.')[0], json.load(open(f))


def gt_pages():
    """{page: (GT line boxes {id: polygon}, GT paragraphs [[id...]])} from the unified GT (canonical records), and the
    reviewed merge GT of merge_gt_eval.load_gt(); cached under workspace.data('retrain', 'grouping')."""
    st = os.stat(workspace.GT); key = (str(workspace.GT), st.st_size, st.st_mtime)
    path = workspace.data('retrain', 'grouping', 'gt.pkl')
    if path.exists():
        c = pickle.load(open(path, 'rb'))
        if c['key'] == key: return c['bench'], c['merge']
    lines, groups = {}, {}
    for r in json.load(open(workspace.GT))['records']:
        if r.get('status') != 'canonical': continue
        if r['scope'] == 'individual_premerge_bbox':
            lines.setdefault(r['page_id'], {})[r['label']['id']] = [[p['x'], p['y']] for p in r['label']['polygon']]
        elif r['scope'] == 'merge_membership':
            groups.setdefault(r['page_id'], []).append(r['label']['sourceRegionIDs'])
    bench = {pid: (lines.get(pid, {}), g) for pid, g in groups.items()}
    import merge_gt_eval
    merge = merge_gt_eval.load_gt()
    pickle.dump(dict(key=key, bench=bench, merge=merge), open(path, 'wb'))
    return bench, merge


def _iou(a, b):
    w = max(0, min(a[2], b[2]) - max(a[0], b[0])); h = max(0, min(a[3], b[3]) - max(a[1], b[1]))
    u = (a[2] - a[0]) * (a[3] - a[1]) + (b[2] - b[0]) * (b[3] - b[1]) - w * h
    return w * h / u if u > 0 else 0


def gt_input(det, gt_polys):
    """GT line boxes as S4 lines (orientation, text and confidence of the best IoU >= 0.3 detected line) and the
    detected -> GT line map (IoU >= 0.3, best), as the grouping benchmark export."""
    gt = []
    for gid, poly in gt_polys.items():
        xs = [p[0] for p in poly]; ys = [p[1] for p in poly]; b = [min(xs), min(ys), max(xs), max(ys)]
        best = max(det, key=lambda d: _iou(b, d['box']), default=None)
        m = best is not None and _iou(b, best['box']) >= 0.3
        gt.append(dict(id=gid, box=b, vertical=best['vertical'] if m else (b[3] - b[1]) > (b[2] - b[0]),
                       text=best['text'] if m else '', conf=best['conf'] if m else None))
    d2g = {}
    for d in det:
        g = max(gt, key=lambda g: _iou(d['box'], g['box']), default=None)
        if g is not None and _iou(d['box'], g['box']) >= 0.3: d2g[d['id']] = g['id']
    return gt, d2g


def load_run(prefix):
    """Pages of a run with merge-GT paragraphs: per page the layout, both inputs ('det' = front.recognized, 'gt' = GT
    line boxes) as page data, line ids and GT paragraph map. split/fold from the manifest (train: 'f2'..'f4')."""
    bench, _ = gt_pages()
    man = {p['page_id']: p for p in json.load(open(workspace.MANIFEST))['pages']}
    out = []
    for split in ('train', 'dev', 'test'):
        for pid, front in fronts(prefix, split):
            if pid not in bench or pid not in man: continue
            polys, groups = bench[pid]
            det = front_lines(front); layout = front_layout(front)
            gt, d2g = gt_input(det, polys)
            known = set(polys)
            gpara = {i: k for k, g in enumerate(k for k in ([i for i in g if i in known] for g in groups) if k) for i in g}
            dpara = {d: gpara[g] for d, g in d2g.items() if g in gpara}
            mp = man[pid]
            fold = f"f{mp['fold']}" if mp['split'] == 'train' else mp['split']
            page = dict(page=pid, split=mp['split'], fold=fold, size=(mp['width'], mp['height']), front=front)
            for inp, ls, para in (('det', det, dpara), ('gt', gt, gpara)):
                D = page_data(layout, ls); ids = [l['id'] for l in ls]
                page[inp] = dict(D=D, ids=ids, para=para, y=labels(D, ids, para))
            out.append(page)
    return out


# ---------------------------------------------------------------- app S4 on a front checkpoint

def _pbox(poly):
    xs = [p[0] for p in poly]; ys = [p[1] for p in poly]
    return min(xs), min(ys), max(xs), max(ys)


def ruby_rails(lines):
    """{rail index: host index}: a kana-only vertical singleton column at most 1/1.5 as wide just right of ONE kanji
    column and within its extent, unless it continues another column end to end (PipelineParagraphGrouping.rubyRails)."""
    def kana(c):
        o = ord(c); return 0x3041 <= o <= 0x3096 or 0x30A1 <= o <= 0x30FA or o in (0x3099, 0x309A, 0x30FC)

    def kanji(c):
        o = ord(c); return 0x3400 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF
    B = [_pbox(l['poly']) for l in lines]
    W = [b[2] - b[0] for b in B]; H = [b[3] - b[1] for b in B]
    rails = {}
    for i, rail in enumerate(lines):
        if not rail['vertical']: continue
        c = B[i]; t = rail['text']
        if not (H[i] > W[i] and t and all(map(kana, t))): continue
        cmx = (c[0] + c[2]) / 2
        hosts = []
        for j, h in enumerate(B):
            size = W[j]; gap = c[0] - h[2]
            if (j != i and lines[j]['vertical'] and H[j] > size and W[i] * 1.5 <= size and any(map(kanji, lines[j]['text']))
                    and -size / 4 <= gap <= size / 2 and cmx > h[2] - size / 4
                    and c[1] >= h[1] - size / 4 and c[3] <= h[3] + size / 4):
                hosts.append(j)
        if len(hosts) != 1: continue
        host = hosts[0]; cont = False
        for j, p in enumerate(B):
            if j in (i, host) or not lines[j]['vertical']: continue
            glyph = min(W[i], W[j]); gap = max(c[1], p[1]) - min(c[3], p[3])
            if (max(W[i], W[j]) >= W[host] * 0.75 and max(W[i], W[j]) <= glyph * 1.8
                    and abs(cmx - (p[0] + p[2]) / 2) <= glyph / 2 and -min(H[i], H[j]) / 4 <= gap <= glyph * 0.75):
                cont = True; break
        if not cont: rails[i] = host
    return rails


def app_groups(front, model):
    """The app's S4 blocks of a front checkpoint as sorted groups of front.recognized indices: members plus their
    ruby readings; lines S4 cannot use (polygon < 3 points or non-finite) stand alone."""
    rec = front.get('recognized') or []
    lines = front_lines(front)
    usable = [k for k, l in enumerate(rec) if len(l['polygon']) >= 3 and all(np.isfinite(v) for p in l['polygon'] for v in p)]
    alone = [[k] for k in range(len(rec)) if k not in set(usable)]
    ls = [lines[k] for k in usable]
    if not ls: return sorted(alone)
    if not all(np.isfinite(v) for l in ls for v in l['box']):
        return sorted(alone + [[k] for k in usable])
    layout = [r for r in front_layout(front) if all(np.isfinite(v) for v in r['box'])]
    D = page_data(layout, ls)
    edges = decide(D, proba(model, D), model['joinAbove'], model['cutBelow'], model['pitchRatio'])
    root = union(D['n'], edges); rails = ruby_rails(ls)
    comp = {}
    for i in range(D['n']):
        if i not in rails: comp.setdefault(root[i], []).append(i)
    host_root = {r: root[h] for r, h in rails.items()}
    groups = [sorted(usable[i] for i in ms + [r for r in rails if host_root[r] == rt]) for rt, ms in comp.items()]
    return sorted(groups + alone)


def load_model(path=None):
    return json.load(open(path or workspace.REPO / RESOURCE))
