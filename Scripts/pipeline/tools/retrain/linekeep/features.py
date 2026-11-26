"""Line-keep gate features, defined exactly as PipelineLineKeep.swift computes them (Unicode scalars, explicit
character classes). Input: one page's S3 lines (dicts: box (x0,y0,x1,y1), vertical, text, conf, det), its S1
layout (kind, score, box) and the page size. Output: one feature row per line (NAMES order)."""
import numpy as np

NAMES = ['det', 'conf', 'chars_per_cell', 'nchar', 'kana', 'kanji', 'latin', 'digit', 'other', 'punct', 'maxrun',
         'uniq', 'has_jp', 'text_sc', 'text_cov', 'balloon_sc', 'balloon_cov', 'sfx_sc', 'sfx_cov', 'frame_sc',
         'frame_cov', 'thick', 'length', 'aspect', 'area', 'vertical', 'thick_rel', 'cx', 'cy', 'edge', 'max_iou',
         'inside_better', 'neighbours', 'page_n']
SPACE = {0x20, 0x3000, 0x09, 0x0A, 0x0D}
PUNCT = {ord(c) for c in '!?！？…・。、．，,.ー〜~-―「」『』（）()♡♥☆★'}
KINDS = ('text', 'balloon', 'sfx', 'frame')


def text_feats(t):
    s = [ord(c) for c in t if ord(c) not in SPACE]
    n = len(s); d = max(n, 1)
    kana = sum(1 for o in s if 0x3040 <= o <= 0x30FF or 0xFF66 <= o <= 0xFF9D)
    kanji = sum(1 for o in s if 0x3400 <= o <= 0x9FFF or 0xF900 <= o <= 0xFAFF)
    latin = sum(1 for o in s if 0x41 <= o <= 0x5A or 0x61 <= o <= 0x7A or 0xFF21 <= o <= 0xFF3A or 0xFF41 <= o <= 0xFF5A)
    digit = sum(1 for o in s if 0x30 <= o <= 0x39 or 0xFF10 <= o <= 0xFF19)
    punct = sum(1 for o in s if o in PUNCT)
    run = best = 1 if n else 0
    for a, b in zip(s, s[1:]):
        run = run + 1 if a == b else 1
        best = max(best, run)
    return [n, kana / d, kanji / d, latin / d, digit / d, (n - kana - kanji - latin - digit) / d, punct / d,
            best / d, len(set(s)) / d, 1.0 if kana + kanji > 0 else 0.0]


def area(b):
    return max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])


def inter(a, b):
    return max(0.0, min(a[2], b[2]) - max(a[0], b[0])) * max(0.0, min(a[3], b[3]) - max(a[1], b[1]))


def covered(b, r):
    A = area(b)
    return inter(b, r) / A if A > 0 else 0.0


def iou(a, b):
    i = inter(a, b); u = area(a) + area(b) - i
    return i / u if u > 0 else 0.0


def page_rows(lines, layout, W, H):
    M = max(W, H)
    th = [(l['box'][2] - l['box'][0]) if l['vertical'] else (l['box'][3] - l['box'][1]) for l in lines]
    good = sorted(t for t, l in zip(th, lines) if l['conf'] >= 0.6)
    if good:
        k = len(good); pt = good[k // 2] if k % 2 else (good[k // 2 - 1] + good[k // 2]) / 2
    else:
        pt = 1.0
    rows = []
    for i, l in enumerate(lines):
        b = l['box']; w, h = b[2] - b[0], b[3] - b[1]
        t = th[i]; ln = h if l['vertical'] else w; tc = max(t, 1.0)
        tf = text_feats(l['text'])
        rf = []
        for kind in KINDS:
            rs = [r for r in layout if r['kind'] == kind]
            rf += [max([covered(b, r['box']) * r['score'] for r in rs] + [0.0]), max([covered(b, r['box']) for r in rs] + [0.0])]
        cx, cy = (b[0] + b[2]) / 2, (b[1] + b[3]) / 2
        mi = ib = 0.0; nb = 0
        for j, o in enumerate(lines):
            if j == i:
                continue
            ob = o['box']
            mi = max(mi, iou(b, ob))
            if o['conf'] > l['conf']:
                ib = max(ib, covered(b, ob))
            if abs((ob[0] + ob[2]) / 2 - cx) < 3 * tc + w / 2 and abs((ob[1] + ob[3]) / 2 - cy) < 3 * tc + h / 2:
                nb += 1
        rows.append([l['det'], l['conf'], tf[0] / max(ln / tc, 0.3)] + tf + rf +
                    [t / M, ln / M, ln / tc, w * h / (W * H), 1.0 if l['vertical'] else 0.0, t / max(pt, 1.0),
                     cx / W, cy / H, min(b[0], W - b[2], b[1], H - b[3]) / M, mi, ib, float(nb), float(len(lines))])
    return rows


def front_lines(front):
    """S3 lines (as the gate sees them: `unrefined` when the run has it, else `recognized`) and the S1 layout from a
    saved stages/ID.front.json."""
    rect = lambda q: (q[0][0], q[0][1], q[0][0] + q[1][0], q[0][1] + q[1][1])
    f32 = lambda v: float(np.float32(v))  # Swift keeps confidence / scores as Float: Double(Float) as the app sees it
    lines = [{'box': rect(l['bounds']), 'vertical': l['vertical'], 'text': l['text'], 'conf': f32(l['confidence']),
              'det': f32(l['detectionScore'])} for l in front.get('unrefined') or front['recognized']]
    layout = [{'kind': r['kind'], 'score': f32(r['score']), 'box': rect(r['bounds'])} for r in front['layout']]
    return lines, layout
