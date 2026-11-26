"""One typesetting score for a run: what the painter draws, scored per GT text region as
(share of its text a reader gets) x (how well it is set). Numbers only.

usage: typeset_score.py RUN_DIR...              score and aspect means of each run directory
       typeset_score.py --cmp BASE_DIR VAR_DIR  paired difference with a page-bootstrap 95% interval
       typeset_score.py --selftest RUN_DIR      the score under synthetic damage (each must lower it)

    score = 100 * sum(q) / (GT text regions + paint that is at no GT region's place)

A GT region that is not painted has q = 0. Region weight 1, pages pooled. No model, no OCR, no pixels of the output:
the page JSON of a run against the GT. Text is handled as opaque strings (lengths, character classes, spaces).

What is scored is the paint, rebuilt from the record as PipelinePainter draws it, never the numbers the record claims:
  lines     horizontal: line i has its ink top at frame top + stroke + i * 1.18 em, is 0.94 em high and
            advance(line) * em * condense wide (advances of the painter's font), centred on the frame's centre x
            (from the frame's left edge when `leading`; narration leads by default);
            vertical: columns of 1 em from the frame's right edge every 1.18 em, 1.02 em per character;
            all turned by `angle` about the frame centre and clipped to the frame grown by 2 px (the painter's clip:
            a frame smaller than its text cuts the text off).
  outline   only with a strokeColor and a strokeWidth > 0, at clamp(strokeWidth * em / style.fontPixels, 0.035 em,
            0.25 em); a block without a style is black on a white outline of max(1 px, em / 12).
  text      the translation after the painter's display normalisation (markup and separators become spaces).
  malformed a placed block with a non-finite or non-positive font size, a non-finite frame, lines that are not
            strings, a bad angle or condense, or no block record is not painted and counts as paint at no region's
            place; a colour that is not a colour makes the block unreadable (contrast 0).
Blocks in `replaySyntheticBlocks` are not scored (the app drops them after the LLM); their paint is an obstacle.

A painted block belongs to the GT region that its detector bounds share most area with, when that is at least half
of the smaller of the two. `place` says whether its paint is there: 1 while the paint touches the region box, the
source ink box or the balloon's box, falling with the gap to the nearest of them to 0 at POSITION_SCALE em. A block
counts 1 - place as paint at no region's place (a block with no region: 1). Speech blocks (dialogue, narration) with
a translation are members of their region whether they are painted or not; a painted block carries weight = its
share of the members' translation characters, and q of a region = sum over its painted blocks of weight * L * A.

L, the share of the block's text a reader gets (shares of the same text: they multiply):
  aspect    share that is right                                                              GT used
  group     1 / (GT regions the block's bounds cover) / (the region's members or paintings)  merged_bbox
  text      translation characters in the painted lines x part of the ink inside the clip    -
  place     see above                                                                        merged_bbox, glyph mask bounds,
                                                                                             balloon masks
  balloon   part of the ink inside the region's GT balloon                                   balloon masks
  overlap   part of the ink not under other paint or under source ink that nothing replaces  glyph mask bounds
  inpage    part of the ink inside the page                                                  -
  art       part of the ink that is not on art edges of the source page                      source image, merged_bbox
  contrast  readability: L* difference of the fill to its outline, or to the worst listed    source_appearance
            background colour, / min(40, the source's own)
A, how well the readable text is set (the mean of six shares):
  size        painted size / target below the target, 1 from there to the top of the GT size   source_font_size,
              interval, top / painted above. Painted size = fontPixels * sqrt(condense);         balloon masks
              target = min(GT size, the largest size at which the text, re-broken at spaces,
              fits the region's part of its balloon with the margin bar on every side)
  consistency exp(-|ln(painted / GT size) - the median of that over the region's GT size class|)  exact_source_font_size_partition
  margin      the largest scale <= 1 about the ink's centre at which every line keeps the margin  balloon masks,
              bar = min(the source ink's own distance, TAU em) from the balloon edge              glyph mask bounds
  position    1 / (1 + (offset / 3.4 em)^2) x (1 - tilt error); offset of the ink's centre from  glyph mask bounds,
              the source ink's centre, or from the balloon's area centroid when that is nearer    balloon masks,
              and the balloon holds this region only; tilt against the region polygon's           merged_bbox polygon
  breaks      (1 - cut loss)(1 - shape loss): the characters of words cut by a line break (a cut  balloon masks
              no wrap could avoid costs only a bad split point), and the part of the lines that
              sticks out of the balloon's free-width profile
  style       fidelity: (1 - W fill loss)(1 - W outline loss)(1 - W weight loss); CIEDE2000 with  source_appearance,
              dead zones, outline presence by how visible / needed it is, outline width range     source_font_weight

GT: typeset_gt.gt() (regions, size + interval, size classes, source ink boxes, weight, the balloon of each region
with its inside-distance map), plus two caches under $AIDOKU_EVAL_DIR/typeset/score: gt.pkl (appearance records and
region tilt, read once from the GT file) and rooms.pkl (the room of each region in its balloon, the balloons'
centroids). Both are keyed on the GT file's size and mtime and on CACHE_VERSION. Every constant below names its
source; those fitted on the GT are fitted on train pages only (`train_constants()` recomputes them).

A page of the run's manifest split that has GT regions but no page record (a failed page) counts as not painted.
How this definition was chosen: $AIDOKU_EVAL_DIR/typeset/FINAL_RANKING.md (eight research directions, a damage /
gaming / red-team harness; the product form of the six look aspects is `rule='product'`).
"""
import collections, copy, json, math, os, pickle, re, sys
from functools import lru_cache
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))  # tools dir
import workspace as ws  # noqa: E402
import render_metrics as rm  # noqa: E402
import typeset_gt as tg  # noqa: E402

# ---------- constants ----------

# The painter (PipelineLayout / PipelinePainter / PipelineRotation).
LINE_PITCH = 1.18                        # PipelineLayout.lineHeightEm
INK_HEIGHT = 0.94                        # PipelineLayout.inkHeightEm
CELL = 1.02                              # PipelineLayout.verticalAdvanceEm
STROKE_MIN, STROKE_MAX = 0.035, 0.25     # PipelineLayout.strokeWidth clamp, em
STROKE_FALLBACK = 1 / 12                 # outline of a block without a style, em (at least 1 px)
CLIP_PAD = 2.0                           # PipelinePainter: each block is clipped to its frame grown by 2 px
# Advances in 1/1000 em of AppleSDGothicNeo-Medium (regular) and -Heavy (bold), the fonts PipelineLayout.font uses,
# read from the font file (`font_tables()` regenerates them). With them the widest line reproduces the frame width
# of 99.6% of the horizontal blocks of retune/aug1/oldfont_train to 0.5%.
WIDE = 865                               # every Hangul syllable, kana, CJK ideograph, full-width form, and the default
ASCII = (  # U+0020 .. U+007E
    (263, 270, 350, 509, 496, 830, 623, 196, 318, 318, 366, 547, 244, 438, 244, 335, 633, 367, 533, 536, 561, 502, 558,
     494, 579, 558, 291, 304, 583, 526, 583, 462, 878, 599, 580, 560, 644, 542, 508, 626, 663, 258, 422, 581, 495, 792,
     659, 679, 550, 679, 572, 494, 533, 648, 593, 847, 594, 550, 531, 338, 335, 338, 451, 323, 492, 467, 540, 442, 540,
     494, 317, 500, 530, 227, 227, 476, 227, 796, 530, 527, 540, 537, 340, 409, 344, 524, 488, 724, 473, 477, 446, 362,
     281, 362, 557),
    (263, 284, 425, 543, 539, 901, 698, 224, 368, 368, 398, 508, 251, 365, 251, 384, 668, 374, 538, 564, 621, 533, 610,
     551, 620, 609, 273, 274, 472, 518, 472, 450, 896, 695, 647, 583, 694, 581, 562, 669, 715, 323, 458, 679, 540, 876,
     710, 723, 637, 723, 655, 555, 592, 689, 684, 948, 691, 642, 587, 368, 384, 368, 470, 372, 483, 531, 599, 480, 599,
     554, 384, 556, 588, 283, 283, 567, 283, 872, 588, 589, 599, 598, 407, 470, 399, 583, 573, 797, 572, 567, 498, 373,
     269, 373, 655))
MARKS = {  # marks narrower than WIDE that occur in translations: code point -> (regular, bold)
    0x2025: (799, 684), 0x00B7: (295, 363), 0x30FB: (295, 363), 0x300C: (330, 395), 0x300D: (330, 395),
    0x300E: (349, 432), 0x300F: (344, 433), 0x201C: (329, 498), 0x201D: (329, 498), 0x2018: (188, 266),
    0x2019: (188, 266), 0x2014: (812, 812), 0x2015: (812, 812), 0x3001: (681, 682), 0x3002: (773, 773),
    0x266A: (507, 507)}

# Fitted on the train pages' GT (`train_constants()`), GT 20261116.
TAU = 0.47          # em: the margin that is enough = lower quartile of (source ink box to balloon edge / GT size) over
                    # the train regions in a balloon (0.467; p10 0.273, median 0.74): three source texts in four keep it
POSITION_SCALE = 3.4  # em: offset at which position is half = the balloon's inscribed radius / GT size, median over
                      # the train regions in a balloon (3.38): the centre moved to where a typical balloon's edge was
TILT_FREE = 0.02    # rad: 95th percentile of the tilt of the train GT region polygons (annotation noise)
INTERVAL = (0.875, 1.125)   # median low / high end of the GT size interval relative to the GT size
# style / contrast (notes/style.md; train GT)
JND = 2.0                                   # CIEDE2000 not seen at a glance
DEAD_FILL = ((0.8, 6.2), (0.9, 3.4))        # (label confidence below, dead zone): p95 of the GT's same-page repeat noise
DEAD_STROKE = ((0.8, 2.5),)
FAR = 50.0                                  # CIEDE2000 from which two colours count as different colours (p90 of the
                                            # distances between distinct fills of a page: 53)
READABLE = 40.0                             # L* difference every unoutlined source text keeps to its background (p1 41)
NEEDED = {'flat': 0.04, 'gradient': 0.63, 'textured': 0.63, 'mixed': 0.82}   # share of source texts outlined on this
                                            # background mode although the fill is READABLE on every listed colour
# Conventions (not fitted).
W_LOOK = 0.25       # share of a region lost by one categorically wrong look component (fill, outline, weight)
CONDENSE_POWER = 0.5  # painted size = fontPixels * condense ** this: a glyph squeezed to 85% covers the area of a
                      # glyph 92% the size
SHAPE_FREE = 1.0    # em of a line that may stick out of the balloon's width profile (one syllable)
MAX_LINES = 14      # most lines the feasibility oracle tries
ROOM_SIDE = 256     # a balloon is reduced to at most this many cells on its long side for the oracle
FIT_STEPS = 7       # bisection steps of the margin scale (1 / 128)
LIMIT = 1e6         # px: no page coordinate or size is beyond this
SPEECH = ('dialogue', 'narration')          # roles the painter paints whenever they have a translation
CLOSERS = '-\u2014\u2015'     # counted as punctuation next to render_metrics.CLOSE / OPEN
CACHE_VERSION = 1   # bump when the cached GT extras change
TEST_SPLIT = None   # a manifest split whose pages are kept out of the caches (research runs set 'test')

LOST = ('group', 'text', 'place', 'balloon', 'overlap', 'inpage', 'art', 'contrast')
LOOK = ('size', 'consistency', 'margin', 'position', 'breaks', 'style')
CONFIG = dict(
    rule='two',         # 'two': q = prod(LOST) * mean(LOOK); 'product': q = prod(LOST) * prod(LOOK)
    margin='fit',       # 'fit': in-place scale; 'line': smallest line-box distance / bar; 'cell': worst glyph cell credit
    position='quad',    # 'quad': 1 / (1 + (offset / POSITION_SCALE em)^2); 'dead': 1 within DEAD_ZONE em, then linear
    fill='exact',       # 'exact': style.py's fill error; 'standout': a fill that stands out more than the source's is no error
    place='gap',        # 'gap': 1 - gap between the paint and the region's place / POSITION_SCALE em; 'overlap': the kept
                        # share of the paint's possible overlap with the place (0 as soon as it touches none)
    tau=TAU, oracle=True, shape=True)
DEAD_ZONE = 0.279   # em, position='dead' only: 90th percentile of the source's own centring error in one-region balloons
EMPTY = dict(regions={}, size={}, classes=[], ink={}, look={}, weight={}, balloon={})
_cache = {}


# ---------- text (opaque strings) ----------

def font_tables():
    """ASCII / MARKS as read from the font file (needs PIL and the macOS system font; documentation of the tables)."""
    from PIL import ImageFont
    faces = [ImageFont.truetype('/System/Library/Fonts/AppleSDGothicNeo.ttc', 1000, index=i, layout_engine=ImageFont.Layout.BASIC) for i in (3, 17)]
    return (tuple(tuple(round(f.getlength(chr(c))) for c in range(0x20, 0x7F)) for f in faces),
            {c: tuple(round(f.getlength(chr(c))) for f in faces) for c in MARKS})


@lru_cache(maxsize=400000)
def advance(s, bold=False):
    """Advance of a string in em."""
    k, t = int(bool(bold)), 0
    for ch in s:
        o = ord(ch)
        t += ASCII[k][o - 0x20] if 0x20 <= o < 0x7F else MARKS[o][k] if o in MARKS else 0 if o < 0x20 else WIDE
    return t / 1000


_BR = re.compile(r'<br\s*/?>', re.I)
_LONG = re.compile('(?<=[\uac00-\ud7a3])[\u30fc\uff70]+')
_SLASH = re.compile(r'(?<![A-Za-z0-9] )(?<![A-Za-z0-9])/(?! ?[A-Za-z0-9])')


@lru_cache(maxsize=100000)
def display(text):
    """The translation as painted (PipelineLayout.displayText): markup and separators become spaces."""
    t = _BR.sub(' ', text) if '<' in text else text
    hangul = any('\uac00' <= c <= '\ud7a3' for c in t)
    t = ''.join(' ' if (c in '\u2028\u2029\u200b\u2800\ufeff' or (c == '|' and hangul)) else c for c in t)
    if hangul:
        t = _SLASH.sub(' ', _LONG.sub('~', t))
        kana = [c for c in t if '\u3040' <= c <= '\u30ff']
        if kana and all(c in '\u3063\u30c3' for c in kana):
            t = t.replace('\u3063', '').replace('\u30c3', '')
    return t


@lru_cache(maxsize=100000)
def aligned(text, lines):
    """The painted lines against the displayed translation -> (painted non-space characters, the token of each,
    the character offset of every line break, translation characters found in the lines / translation characters).
    The lines are aligned as a subsequence; lines that are not the translation's text are their own tokens."""
    J = [c for ln in lines for c in ln if not c.isspace()]
    flat = [(c, k) for k, w in enumerate(text.split()) for c in w]
    wid, i, found = [], 0, 0
    for c in J:
        j = i
        while j < len(flat) and flat[j][0] != c:
            j += 1
        if j < len(flat):
            wid.append(flat[j][1]); i = j + 1; found += 1
        else:
            wid.append(None)
    if found < len(J):
        wid, k = [], 0
        for ln in lines:
            for w in ln.split():
                wid += [k] * len(w); k += 1
    ends, pos = [], 0
    for ln in lines[:-1]:
        pos += sum(1 for c in ln if not c.isspace()); ends.append(pos)
    return J, wid, ends, (found / len(flat) if flat else 1.0)


# ---------- GT ----------

def _cache_file(name):
    return ws.data('typeset', 'score', name)


def _key():
    st = os.stat(ws.GT)
    return (ws.GT.name, st.st_size, st.st_mtime_ns, tg.GT_CACHE, CACHE_VERSION, TEST_SPLIT)


def _splits():
    if 'split' not in _cache:
        _cache['split'] = {p['page_id']: p['split'] for p in json.load(open(ws.MANIFEST))['pages']}
    return _cache['split']


def _lab(c):
    def lin(v):
        v /= 255
        return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(float(v)) for v in c)
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047; y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    f = lambda t: t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    return 116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z))


@lru_cache(maxsize=200000)
def _lab3(r, g, b):
    return _lab((r, g, b))


def extras():
    """{page: dict(look={region: appearance GT as numbers}, tilt={region: radians})} from the GT file's
    source_appearance and merged_bbox records, cached in gt.pkl (see the module doc)."""
    if 'extras' in _cache:
        return _cache['extras']
    f, key = _cache_file('gt.pkl'), _key()
    if f.exists():
        c = pickle.load(open(f, 'rb'))
        if c['key'] == key:
            _cache['extras'] = c['pages']
            return c['pages']
    split = _splits()
    out = collections.defaultdict(lambda: dict(look={}, tilt={}))
    labs = lambda cs: [tuple(_lab(c)) for c in dict.fromkeys(tuple(c) for c in cs)]
    for r in json.load(open(ws.GT))['records']:
        if split.get(r['page_id']) == TEST_SPLIT:
            continue
        l = r['label']
        if r['scope'] == 'merged_bbox' and r.get('status') == 'canonical' and len(l['polygon']) == 4:
            (a, b) = l['polygon'][:2]
            t = math.atan2(b['y'] - a['y'], b['x'] - a['x']) % (math.pi / 2)        # a rectangle: any edge, mod 90 degrees
            out[r['page_id']]['tilt'][r['entity_id']] = t - math.pi / 2 if t > math.pi / 4 else t
        elif r['scope'] == 'source_appearance' and r.get('status') == 'current':
            fi, o, bg = l['fill'], l['outline'], l.get('background') or {}
            fills = [c for c in [fi.get('rgb')] + list(fi.get('colors') or []) if c is not None]
            fills += [s['fill']['rgb'] for s in l.get('substyles') or [] if (s.get('fill') or {}).get('rgb') is not None]
            if not fills:
                continue
            layers = o.get('layers') or []
            strokes = [c for c in [o.get('rgb')] + [y.get('rgb') for y in layers] if c is not None]
            ref = float(l.get('fontPixels') or 0)
            wlo = whi = None
            if o.get('present') and ref > 0:
                ranges = [q for q in [o.get('widthRangePx')] + [y.get('widthRangePx') for y in layers] if q]
                if ranges:
                    wlo = min(q[0] for q in ranges) / ref
                    whi = max([q[1] for q in ranges] + [sum(y['widthRangePx'][1] for y in layers if y.get('widthRangePx'))]) / ref
            bgs = [c for c in [bg.get('rgb')] + list(bg.get('colors') or []) if c is not None]
            out[r['page_id']]['look'][l['regionID']] = dict(
                fills=labs(fills), conf_fill=fi.get('confidence'), out=o.get('present'), strokes=labs(strokes),
                conf_stroke=o.get('confidence'), wlo=wlo, whi=whi, bgs=labs(bgs), mode=bg.get('mode'))
    pages = {pid: dict(v) for pid, v in out.items()}
    pickle.dump(dict(key=key, pages=pages), open(f, 'wb'), protocol=4)
    _cache['extras'] = pages
    return pages


def _pool(mask, k):
    if k == 1:
        return mask
    h, w = mask.shape
    hh, ww = -(-h // k), -(-w // k)
    pad = np.zeros((hh * k, ww * k), dtype=np.float32)
    pad[:h, :w] = mask
    return pad.reshape(hh, k, ww, k).mean((1, 3)) >= 0.5


def _nearest(shape, boxes):
    """Index of the nearest box (cell coordinates) per cell."""
    ys, xs = np.mgrid[0:shape[0], 0:shape[1]]
    xs = xs + 0.5; ys = ys + 0.5
    best, arg = None, np.zeros(shape, dtype=np.int32)
    for k, (x0, y0, x1, y1) in enumerate(boxes):
        d = np.hypot(np.maximum(0, np.maximum(x0 - xs, xs - x1)), np.maximum(0, np.maximum(y0 - ys, ys - y1)))
        if best is None:
            best = d
        else:
            closer = d < best
            best = np.where(closer, d, best); arg[closer] = k
    return arg


def _frontier(cell, cx, cy):
    """widest[k] = the widest all-free rectangle of height k + 1 cells that contains cell (cx, cy) (the nearest free
    cell when that one is not free); None when no cell is free."""
    hh, ww = cell.shape
    cx, cy = int(min(ww - 1, max(0, cx))), int(min(hh - 1, max(0, cy)))
    if not cell[cy, cx]:
        ys, xs = np.nonzero(cell)
        if not len(xs):
            return None
        k = int(np.argmin((xs - cx) ** 2 + (ys - cy) ** 2)); cx, cy = int(xs[k]), int(ys[k])
    col = cell[:, cx]
    top = cy
    while top > 0 and col[top - 1]:
        top -= 1
    bot = cy
    while bot < hh - 1 and col[bot + 1]:
        bot += 1
    blocked = ~cell[top:bot + 1]
    left = np.where(blocked[:, :cx + 1], np.arange(cx + 1)[None, :] + 1, 0).max(1)       # first free column of the run
    right = np.where(blocked[:, cx:], np.arange(cx, ww)[None, :], ww).min(1)             # one past its last
    c = cy - top
    up_l = np.maximum.accumulate(left[c::-1]); up_r = np.minimum.accumulate(right[c::-1])
    dn_l = np.maximum.accumulate(left[c:]); dn_r = np.minimum.accumulate(right[c:])
    width = np.minimum(up_r[:, None], dn_r[None, :]) - np.maximum(up_l[:, None], dn_l[None, :])
    height = np.arange(len(up_l))[:, None] + np.arange(len(dn_l))[None, :]
    widest = np.zeros(bot - top + 1, dtype=np.float32)
    np.maximum.at(widest, height.ravel(), width.ravel())
    return widest


def rooms(pid):
    """dict(room={region: (widest rectangle per height in cells, cells per px)}, centroid={balloon index: (x, y)},
    alone={balloon index: it holds one GT region}) of a page: the part of its GT balloon each region may fill (the
    cells nearer to its source ink than to another region's) as the frontier of rectangles around the source ink
    centre, and the balloons' area centroids. GT only; kept in rooms.pkl (written by save())."""
    if 'rooms' not in _cache:
        f = _cache_file('rooms.pkl')
        c = pickle.load(open(f, 'rb')) if f.exists() else None
        _cache['rooms'] = c['pages'] if c and c['key'] == _key() else {}
    R = _cache['rooms']
    if pid not in R:
        g = tg.gt().get(pid) or EMPTY
        out = dict(room={}, centroid={}, alone={})
        by = collections.defaultdict(list)
        for rid, (idx, _, _) in g['balloon'].items():
            by[idx].append(rid)
        bl = tg.balloons(pid) if by else []
        for idx, rids in by.items():
            x0, y0, x1, y1, dist = bl[idx]
            inside = dist > 0
            ys, xs = np.nonzero(inside)
            out['centroid'][idx] = (x0 + float(xs.mean()) + 0.5, y0 + float(ys.mean()) + 0.5)
            out['alone'][idx] = len(rids) == 1
            k = max(1, -(-max(dist.shape) // ROOM_SIDE)); s = 1 / k
            mask = _pool(inside, k)
            src = [g['ink'].get(r, g['regions'][r]) for r in rids]
            boxes = [((a[0] - x0) * s, (a[1] - y0) * s, (a[2] - x0) * s, (a[3] - y0) * s) for a in src]
            own = _nearest(mask.shape, boxes) if len(rids) > 1 else np.zeros(mask.shape, dtype=np.int32)
            for j, rid in enumerate(rids):
                fr = _frontier(mask & (own == j), (boxes[j][0] + boxes[j][2]) / 2, (boxes[j][1] + boxes[j][3]) / 2)
                if fr is not None:
                    out['room'][rid] = (fr, s)
        R[pid] = out
        _cache['rooms_dirty'] = True
    return R[pid]


def save():
    """Write the rooms cache when a page was added to it."""
    if _cache.pop('rooms_dirty', False):
        pickle.dump(dict(key=_key(), pages=_cache['rooms']), open(_cache_file('rooms.pkl'), 'wb'), protocol=4)


def train_constants():
    """The GT-fitted constants recomputed from the train pages: dict(TAU candidates, POSITION_SCALE, DEAD_ZONE,
    TILT_FREE, INTERVAL)."""
    G, split = tg.gt(), _splits()
    X = extras()
    margin, radius, centre, tilt, low, high = [], [], [], [], [], []
    for pid, g in G.items():
        if split.get(pid) != 'train':
            continue
        R = rooms(pid)
        bl = tg.balloons(pid) if g['balloon'] else []
        tilt += [abs(t) for t in X.get(pid, {}).get('tilt', {}).values()]
        for rid, (px, lo, hi) in g['size'].items():
            low.append(lo / px); high.append(hi / px)
            if rid in g['balloon']:
                idx, _, source_margin = g['balloon'][rid]
                margin.append(source_margin / px)
                d = float(bl[idx][4].max())
                if d < 255:                                   # the distance maps are clipped at 255 px
                    radius.append(d / px)
                if R['alone'][idx]:
                    a = g['ink'].get(rid, g['regions'][rid]); c = R['centroid'][idx]
                    centre.append(math.hypot((a[0] + a[2]) / 2 - c[0], (a[1] + a[3]) / 2 - c[1]) / px)
    q = lambda v, p: round(float(np.percentile(v, p)), 3)
    return dict(TAU_p10=q(margin, 10), TAU_p25=q(margin, 25), POSITION_SCALE=q(radius, 50), DEAD_ZONE=q(centre, 90),
                TILT_FREE=q(tilt, 95), INTERVAL=(q(low, 50), q(high, 50)), regions=len(margin))


# ---------- the paint ----------

def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) and abs(v) < LIMIT


def _rgb(c):
    """(r, g, b) within 0..255, or None when the colour is missing or not finite."""
    try:
        v = (c['r'], c['g'], c['b'])
    except (TypeError, KeyError):
        return None
    if not all(isinstance(x, (int, float)) and math.isfinite(x) for x in v):
        return None
    return tuple(int(min(255, max(0, round(x)))) for x in v)


def _stroke(st, em):
    """Outline width in px as PipelineLayout.strokeWidth(for:fontPixels:)."""
    if st is None:
        return max(1.0, em * STROKE_FALLBACK)
    w = st.get('strokeWidth')
    if st.get('strokeColor') is None or not _num(w) or w <= 0:
        return 0.0
    if st.get('painted'):   # already the painted width in px
        return float(w)
    ref = st.get('fontPixels')
    return min(max(w * em / ref if _num(ref) and ref > 0 else w, em * STROKE_MIN), em * STROKE_MAX)


def _valid(p, blocks):
    """The block record of a placed entry the painter can draw, else None."""
    if not isinstance(p, dict):
        return None
    try:
        b = blocks.get(p.get('blockID'))
        (x, y), (w, h) = p.get('frame')
    except (TypeError, ValueError):
        return None
    lines, em = p.get('lines'), p.get('fontPixels')
    ok = (isinstance(b, dict) and all(_num(v) for v in (x, y, w, h, em)) and em > 0
          and isinstance(lines, list) and all(isinstance(s, str) for s in lines)
          and (p.get('angle') is None or _num(p['angle'])) and (p.get('condense') is None or (_num(p['condense']) and p['condense'] > 0))
          and (b.get('style') is None or isinstance(b['style'], dict)))
    return b if ok else None


def _clip(r, c):
    x0, y0, x1, y1 = max(r[0], c[0]), max(r[1], c[1]), min(r[2], c[2]), min(r[3], c[3])
    return (x0, y0, x1, y1) if x1 > x0 and y1 > y0 else None


def paint(p, b):
    """What the painter draws for a valid placed entry -> dict(rects = ink rectangles (x0, y0, x1, y1) with their
    outline, one per line or column (cells of a line when the block is turned), clipped to the painter's clip;
    box = their bounding box; seen = part of the ink inside the clip; chars = (translation characters painted,
    translation characters); stroke = outline px; top, mid = the frame's top and centre x), or None when nothing
    is painted."""
    (x, y), (w, h) = p['frame']
    if w < 0:
        x, w = x + w, -w
    if h < 0:
        y, h = y + h, -h
    em, lines = p['fontPixels'], p['lines']
    st = b.get('style')
    s = _stroke(st, em)
    text = b.get('translation')
    inked = [ln for ln in lines if ln.strip()]
    if not isinstance(text, str):
        if not inked:          # neither text nor lines (the harness anchor): the frame is all there is
            return dict(rects=[(x, y, x + w, y + h)], box=(x, y, x + w, y + h), seen=1.0, chars=(0, 0), stroke=s, al=None, top=y, mid=x + w / 2)
        shown, al = None, None
    else:
        shown = display(text)
        al = aligned(shown, tuple(lines))
    if not inked:
        return None
    bold = bool(st.get('bold')) if st else False
    k = p.get('condense') or 1
    mx, my = x + w / 2, y + h / 2
    rects = []
    if p.get('vertical'):
        for c, ln in enumerate(lines):
            cells = sum(0.5 if ch.isspace() else 1 for ch in ln.strip().replace('...', '\u2026'))
            if cells > 0:
                cx = x + w - s - em / 2 - c * LINE_PITCH * em
                rects.append((mx + (cx - em / 2 - s - mx) * k, y, mx + (cx + em / 2 + s - mx) * k, y + cells * CELL * em + 2 * s))
    else:
        lead = p['leading'] if isinstance(p.get('leading'), bool) else b.get('role') == 'narration'
        for i, ln in enumerate(lines):
            if not ln.strip():
                continue
            wd = advance(ln, bold) * em * k
            left = x if lead else mx - wd / 2 - s
            top = y + i * LINE_PITCH * em
            rects.append((left, top, left + wd + 2 * s, top + INK_HEIGHT * em + 2 * s))
    a = p.get('angle') or 0
    if a:
        ca, sa = math.cos(a), math.sin(a)
        turned = []
        for r in rects:              # cut into squares along the long side; each square turns about the frame centre
            rw, rh = r[2] - r[0], r[3] - r[1]
            n = max(1, int(round(max(rw, rh) / max(1e-9, min(rw, rh)))))
            cw, ch = (rw / n, rh) if rw >= rh else (rw, rh / n)
            hw, hh = (cw * abs(ca) + ch * abs(sa)) / 2, (cw * abs(sa) + ch * abs(ca)) / 2
            for j in range(n):
                ux, uy = (r[0] + (j + 0.5) * cw, (r[1] + r[3]) / 2) if rw >= rh else ((r[0] + r[2]) / 2, r[1] + (j + 0.5) * ch)
                dx, dy = ux - mx, uy - my
                tx, ty = mx + dx * ca - dy * sa, my + dx * sa + dy * ca
                turned.append((tx - hw, ty - hh, tx + hw, ty + hh))
        rects = turned
        cw, ch = (w * abs(ca) + h * abs(sa)) / 2, (w * abs(sa) + h * abs(ca)) / 2          # PipelineRotation.bounds
        clip = (mx - cw - CLIP_PAD, my - ch - CLIP_PAD, mx + cw + CLIP_PAD, my + ch + CLIP_PAD)
    else:
        clip = (x - CLIP_PAD, y - CLIP_PAD, x + w + CLIP_PAD, y + h + CLIP_PAD)
    area = sum((r[2] - r[0]) * (r[3] - r[1]) for r in rects)
    rects = [c for c in (_clip(r, clip) for r in rects) if c]
    if not rects or area <= 0:
        return None
    seen = sum((r[2] - r[0]) * (r[3] - r[1]) for r in rects) / area
    box = (min(r[0] for r in rects), min(r[1] for r in rects), max(r[2] for r in rects), max(r[3] for r in rects))
    want = len(''.join(shown.split())) if shown is not None else 0
    chars = (min(want, int(round(al[3] * want))), want) if al else (0, 0)
    return dict(rects=rects, box=box, seen=min(1.0, seen), chars=chars, stroke=s, al=al, top=y, mid=mx)


# ---------- geometry ----------

def _inter(a, b):
    return max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))


def _area(rects):
    return max(1e-9, sum((r[2] - r[0]) * (r[3] - r[1]) for r in rects))


def _under(rects, box, others):
    """Area of `rects` under the rectangle lists `others` = [(box, rects)]."""
    t = 0.0
    for obox, orects in others:
        if _inter(box, obox) > 0:
            t += sum(_inter(a, o) for a in rects for o in orects)
    return t


def _inside(dist, x0, y0, rects):
    """Part of the rectangles' area on cells of the balloon crop `dist` (origin x0, y0) that are inside the balloon."""
    hh, ww = dist.shape
    area = inside = 0
    for r in rects:
        X0, Y0, X1, Y1 = int(round(r[0] - x0)), int(round(r[1] - y0)), int(round(r[2] - x0)), int(round(r[3] - y0))
        X1 = max(X1, X0 + 1); Y1 = max(Y1, Y0 + 1)
        area += (X1 - X0) * (Y1 - Y0)
        cx0, cy0, cx1, cy1 = max(0, X0), max(0, Y0), min(ww, X1), min(hh, Y1)
        if cx1 > cx0 and cy1 > cy0:
            inside += int(np.count_nonzero(dist[cy0:cy1, cx0:cx1]))
    return inside / area


def _edge(dist, box):
    """Smallest value of the distance map on the border of `box` (crop coordinates); 0 when the box leaves the crop."""
    h, w = dist.shape
    x0, y0, x1, y1 = int(round(box[0])), int(round(box[1])), int(round(box[2])), int(round(box[3]))
    if x0 < 0 or y0 < 0 or x1 > w or y1 > h or x1 - x0 < 1 or y1 - y0 < 1:
        return 0.0
    x1 -= 1; y1 -= 1
    return float(min(dist[y0, x0:x1 + 1].min(), dist[y1, x0:x1 + 1].min(), dist[y0:y1 + 1, x0].min(), dist[y0:y1 + 1, x1].min()))


def _keeps(dist, rects, ref):
    return all(_edge(dist, r) >= ref for r in rects)


def _cell_credit(dist, rects, ref):
    """The lowest clearance credit of a glyph cell: cells = squares of a rectangle's short side along it, credit =
    mean over the cell of min(1, distance to the balloon edge / ref); 0 for a cell outside the crop."""
    hh, ww = dist.shape
    worst = 1.0
    for r in rects:
        X0, Y0, X1, Y1 = int(round(r[0])), int(round(r[1])), int(round(r[2])), int(round(r[3]))
        X1 = max(X1, X0 + 1); Y1 = max(Y1, Y0 + 1)
        cx0, cy0, cx1, cy1 = max(0, X0), max(0, Y0), min(ww, X1), min(hh, Y1)
        if cx1 <= cx0 or cy1 <= cy0:
            return 0.0
        c = np.minimum(dist[cy0:cy1, cx0:cx1], ref)
        along = 1 if X1 - X0 >= Y1 - Y0 else 0
        n, side = (X1 - X0, Y1 - Y0) if along else (Y1 - Y0, X1 - X0)
        line = np.zeros(n)
        o = (cx0 - X0) if along else (cy0 - Y0)
        line[o:o + c.shape[along]] = c.sum(axis=1 - along) / (side * ref)
        k = max(1, int(round(n / side)))
        cuts = [int(round(i * n / k)) for i in range(k + 1)]
        worst = min(worst, min(float(line[cuts[i]:cuts[i + 1]].mean()) for i in range(k)))
    return worst


# ---------- aspects of one painted block (B: the block's context, see page()) ----------

def margin(B, form, tau):
    """How much of the text size keeps the margin bar min(the source ink's own distance, tau em) from the balloon edge."""
    if B['balloon'] is None:
        return 1.0
    x0, y0, dist = B['balloon']
    ref = min(B['source_margin'], tau * B['em'])
    if ref < 1:
        return 1.0
    rects = [(r[0] - x0, r[1] - y0, r[2] - x0, r[3] - y0) for r in B['rects']]
    if form == 'line':
        return min(1.0, min(_edge(dist, r) for r in rects) / ref)
    if form == 'cell':
        return _cell_credit(dist, rects, ref)
    if _keeps(dist, rects, ref):
        return 1.0
    cx, cy = (B['box'][0] + B['box'][2]) / 2 - x0, (B['box'][1] + B['box'][3]) / 2 - y0
    lo, hi = 0.0, 1.0
    for _ in range(FIT_STEPS):
        c = (lo + hi) / 2
        if _keeps(dist, [(cx + (r[0] - cx) * c, cy + (r[1] - cy) * c, cx + (r[2] - cx) * c, cy + (r[3] - cy) * c) for r in rects], ref):
            lo = c
        else:
            hi = c
    return lo


@lru_cache(maxsize=100000)
def _demand(words, space):
    """(smallest possible widest line when the words are broken into n = 1..N lines, the height of n lines), em."""
    n = len(words)
    c = np.concatenate([[0.0], np.cumsum(np.asarray(words, float))])
    j, i = np.meshgrid(np.arange(n + 1), np.arange(n + 1), indexing='ij')
    width = np.where(i > j, c[i] - c[j] + space * (i - j - 1), np.inf)      # words j .. i - 1 on one line
    f = width[0].copy()
    best = [f[n]]
    for _ in range(1, min(n, MAX_LINES)):
        f = np.maximum(f[:, None], width).min(0)
        best.append(f[n])
    return np.asarray(best), LINE_PITCH * np.arange(len(best)) + INK_HEIGHT


def achievable(B, tau):
    """The largest font size at which the block's text, re-broken at spaces, fits a rectangle of the region's room in
    its GT balloon with the margin bar and its outline on every side; None when the region has no room or the block
    is vertical."""
    room = B['room']
    if room is None or B['p'].get('vertical') or not B['words']:
        return None
    widest, scale = room
    wide, high = _demand(B['words'], advance(' ', B['bold']))
    bar = min(B['source_margin'], tau * B['em'])
    sigma = 2 * B['stroke'] / B['p']['fontPixels']
    w = widest / scale - 2 * bar
    h = np.arange(1, len(widest) + 1) / scale - 2 * bar
    return max(0.0, float(np.minimum(w[:, None] / (wide[None, :] + sigma), h[:, None] / (high[None, :] + sigma)).max()))


def size(B, tau, oracle):
    """painted / target below the target, 1 up to the top of the GT interval, top / painted above; target = min(GT
    size, achievable size)."""
    px, lo, hi = B['gt_size']
    if px is None:
        return 1.0
    target = px
    if oracle:
        fit = achievable(B, tau)
        if fit is not None:
            target = min(px, fit)
    s = B['painted']
    return s / target if s < target else 1.0 if s <= hi else hi / s


def position(B, form):
    """Where the ink sits: its centre against the source ink's centre (or the balloon's centroid, when that is nearer
    and the balloon holds this region only), in GT em; times the tilt agreement."""
    box, src, em = B['box'], B['src'], B['em']
    cx, cy = (box[0] + box[2]) / 2, (box[1] + box[3]) / 2
    off = math.hypot(cx - (src[0] + src[2]) / 2, cy - (src[1] + src[3]) / 2)
    if B['centroid'] is not None:
        off = min(off, math.hypot(cx - B['centroid'][0], cy - B['centroid'][1]))
    if form == 'dead':
        zero = max(DEAD_ZONE * em + 1e-9, math.hypot(src[2] - src[0], src[3] - src[1]) / 2)     # v1's zero point
        v = 1.0 if off <= DEAD_ZONE * em else max(0.0, 1 - (off - DEAD_ZONE * em) / (zero - DEAD_ZONE * em))
    else:
        v = 1 / (1 + (off / (POSITION_SCALE * em)) ** 2)
    d = abs((B['p'].get('angle') or 0) - B['tilt'])
    d = min(d % (2 * math.pi), 2 * math.pi - d % (2 * math.pi))
    return v * (1 - min(1.0, max(0.0, d - TILT_FREE) / (math.pi / 2 - TILT_FREE)))


def _punct():
    if 'punct' not in _cache:
        _cache['punct'] = (frozenset(rm.CLOSE | rm.OPEN | set(CLOSERS)), frozenset(rm.CLOSE), frozenset(rm.OPEN))
    return _cache['punct']


def _cut_tokens(J, wid, ends, sets):
    """{token: dict(chars, letters, kin, m, frags)} of the tokens with a defective break: a break between two letters
    of a token (m = letters of its smallest fragment), or one that puts a closing mark of the token at a line start
    or leaves an opening mark at a line end (kin)."""
    PUN, CLOSE, OPEN = sets
    N, out, cuts = len(J), {}, collections.defaultdict(list)
    for e in ends:
        if not (0 < e < N) or wid[e - 1] != wid[e]:
            continue
        a, b = J[e - 1], J[e]
        if a not in PUN and b not in PUN:
            cuts[wid[e]].append((e, 'LL'))
        elif b in CLOSE or a in OPEN:
            cuts[wid[e]].append((e, 'K'))
    for w, cs in cuts.items():
        idx = [i for i, x in enumerate(wid) if x == w]
        first, last = idx[0], idx[-1] + 1
        letters = lambda lo, hi: sum(1 for c in J[lo:hi] if c not in PUN)
        ll = sorted(e for e, k in cs if k == 'LL')
        frags = [letters(lo, hi) for lo, hi in zip([first] + ll, ll + [last])] if ll else []
        out[w] = dict(chars=last - first, letters=letters(first, last), kin=any(k == 'K' for _, k in cs),
                      m=max(1, min(frags)) if frags else None, frags=len(frags))
    return out


def _units(J, wid, sets, bold):
    """Unbreakable units of the painted text [(advance em, a space goes before it)]: tokens, also breakable after
    punctuation that a letter follows."""
    PUN, CLOSE, OPEN = sets
    out, seg, first = [], [], True
    for i, c in enumerate(J):
        seg.append(c)
        last = i + 1 == len(J) or wid[i + 1] != wid[i]
        if last or (c in PUN and c not in OPEN and J[i + 1] not in PUN):
            out.append((advance(''.join(seg), bold), first)); seg, first = [], last
    return out


def _fits(us, caps, space):
    """Greedy first-fit of the units into lines of the given capacities (em): optimal for feasibility."""
    j, used = 0, 0.0
    for a, sp in us:
        need = a + (space if sp and used > 0 else 0.0)
        if used + need <= caps[j] + 1e-9:
            used += need
            continue
        j += 1
        if j >= len(caps) or a > caps[j] + 1e-9:
            return False
        used = a
    return True


def _half_widths(pid, rid, g):
    """(free half width of each row of the region's GT balloon about the source ink centre column, the centre row),
    or None when the centre is not inside the balloon."""
    key = ('half', pid, rid)
    if key not in _cache:
        x0, y0, x1, y1, dist = tg.balloons(pid)[g['balloon'][rid][0]]
        src = g['ink'].get(rid, g['regions'][rid])
        cx, cy = (src[0] + src[2]) / 2 - x0, (src[1] + src[3]) / 2 - y0
        xi, inside = int(round(cx)), dist > 0
        h, w = inside.shape
        if not (0 <= xi < w and 0 <= int(round(cy)) < h and inside[int(round(cy)), xi]):
            _cache[key] = None
        else:
            lw = np.pad(~inside[:, xi::-1], ((0, 0), (0, 1)), constant_values=True).argmax(1)
            rw = np.pad(~inside[:, xi:], ((0, 0), (0, 1)), constant_values=True).argmax(1)
            _cache[key] = (np.minimum(lw, rw).astype(np.float32), cy)
    return _cache[key]


def _clean_wrap(us, half, cy, em, bar, sigma, space):
    """Whether a wrap at unit boundaries fits the balloon at font size em: n lines of the painter's pitch stacked
    about the source ink centre, each as wide as the narrowest free row of its line, the margin bar kept on both sides."""
    h = len(half)
    for n in range(1, MAX_LINES + 1):
        caps = []
        for j in range(n):
            yc = cy + (j - (n - 1) / 2) * LINE_PITCH * em
            lo, hi = int(round(yc - em / 2)), int(round(yc + em / 2)) + 1
            if lo < 0 or hi > h:
                return False          # the stack no longer fits the balloon's height: taller stacks do not either
            c = float(half[lo:hi].min())
            if c <= 0:
                return False
            caps.append((2 * c - 2 * bar) / em - sigma)
        if _fits(us, caps, space):
            return True
    return False


def _shape_loss(B, lines):
    """Share of the line advances outside the balloon's free-width profile scaled to the paragraph."""
    w = np.array([advance(ln.strip(), B['bold']) for ln in lines])
    if len(w) < 2 or w.sum() <= 0:
        return 0.0
    f = np.ones(len(w))
    if B['balloon'] is not None:
        x0, y0, dist = B['balloon']
        em = B['p']['fontPixels']
        xi = int(round(B['mid'] - x0))
        prof = []
        for j in range(len(w)):
            yi = int(round(B['top'] + B['stroke'] + (j * LINE_PITCH + INK_HEIGHT / 2) * em - y0))
            if 0 <= yi < dist.shape[0] and 0 <= xi < dist.shape[1] and dist[yi, xi] > 0:
                row = dist[yi] > 0
                l = xi - int(np.append(~row[xi::-1], True).argmax()); r = xi + int(np.append(~row[xi:], True).argmax())
                prof.append(r - l - 1)
            else:
                prof.append(0.0)
        if sum(prof) > 0:
            f = np.array(prof, float)
    rho = w.sum() / f.sum()
    return float(np.maximum(0.0, w - rho * f - SHAPE_FREE).sum() / w.sum())


def breaks(B, tau, shape):
    """(1 - cut loss) * (1 - shape loss), both shares of the block's painted characters (notes/brk.md): a cut word
    costs its characters / m (m = letters of its smallest fragment), a kinsoku break its token; when no clean wrap
    exists at the painted size, in the painted footprint or in the GT balloon, a cut costs only what the best split
    point would have saved."""
    p, al = B['p'], B['al']
    lines = p['lines']
    if al is None or len(lines) < 2 or p.get('vertical'):
        return 1.0
    J, wid, ends, _ = al
    if not J:
        return 1.0
    sets = _punct()
    toks = _cut_tokens(J, wid, ends, sets)
    loss = 0.0
    if toks:
        forced = False
        if any(t['m'] for t in toks.values()):
            space = advance(' ', B['bold'])
            us = _units(J, wid, sets, B['bold'])
            forced = not _fits(us, [max(advance(ln.strip(), B['bold']) for ln in lines)] * len(lines), space)
            if forced and B['balloon'] is not None:
                hc = _half_widths(B['pid'], B['rid'], B['g'])
                if hc is not None:
                    em = p['fontPixels']
                    forced = not _clean_wrap(us, hc[0], hc[1], em, min(B['source_margin'], tau * B['em']), 2 * B['stroke'] / em, space)
        for t in toks.values():
            s = 1.0 if t['kin'] else 0.0
            if t['m']:
                s = max(s, 1.0 / t['m'] - (1.0 / max(1, t['letters'] // t['frags']) if forced else 0.0))
            loss += t['chars'] * s
        loss = min(1.0, loss / len(J))
    if shape:
        loss = 1 - (1 - loss) * (1 - _shape_loss(B, lines))
    return 1 - loss


def _de00(p, q):
    """CIEDE2000 between two L*a*b* triples."""
    L1, a1, b1 = p; L2, a2, b2 = q
    C1 = math.hypot(a1, b1); C2 = math.hypot(a2, b2)
    m = ((C1 + C2) / 2) ** 7
    G = 0.5 * (1 - math.sqrt(m / (m + 6103515625.0)))
    a1 *= 1 + G; a2 *= 1 + G
    C1 = math.hypot(a1, b1); C2 = math.hypot(a2, b2)
    h1 = math.degrees(math.atan2(b1, a1)) % 360 if C1 else 0.0
    h2 = math.degrees(math.atan2(b2, a2)) % 360 if C2 else 0.0
    dL = L2 - L1; dC = C2 - C1
    if C1 * C2 == 0:
        dh, hm = 0.0, h1 + h2
    else:
        dh = h2 - h1
        dh = dh - 360 if dh > 180 else dh + 360 if dh < -180 else dh
        hm = (h1 + h2) / 2 if abs(h1 - h2) <= 180 else (h1 + h2 + 360) / 2 if h1 + h2 < 360 else (h1 + h2 - 360) / 2
    dH = 2 * math.sqrt(C1 * C2) * math.sin(math.radians(dh / 2))
    Lm = (L1 + L2) / 2; Cm = (C1 + C2) / 2
    T = (1 - 0.17 * math.cos(math.radians(hm - 30)) + 0.24 * math.cos(math.radians(2 * hm))
         + 0.32 * math.cos(math.radians(3 * hm + 6)) - 0.20 * math.cos(math.radians(4 * hm - 63)))
    Rc = 2 * math.sqrt(Cm ** 7 / (Cm ** 7 + 6103515625.0))
    Sl = 1 + 0.015 * (Lm - 50) ** 2 / math.sqrt(20 + (Lm - 50) ** 2); Sc = 1 + 0.045 * Cm; Sh = 1 + 0.015 * Cm * T
    Rt = -math.sin(math.radians(60 * math.exp(-((hm - 275) / 25) ** 2))) * Rc
    return math.sqrt(max(0.0, (dL / Sl) ** 2 + (dC / Sc) ** 2 + (dH / Sh) ** 2 + Rt * (dC / Sc) * (dH / Sh)))


def _colour_loss(d, dead):
    return min(1.0, max(0.0, (d - dead) / (FAR - dead)))


def _dead(conf, table):
    for below, zone in table:
        if conf is not None and conf < below:
            return max(JND, zone)
    return JND


def _seen(fill, stroke, bgs):
    """L* difference that makes the text visible: the fill against its outline, or fill + outline against every
    background colour; without an outline the fill against the worst background colour."""
    if stroke is None:
        return min(abs(fill[0] - c[0]) for c in bgs) if bgs else 100.0
    fat = min(min(abs(fill[0] - c[0]), abs(stroke[0] - c[0])) for c in bgs) if bgs else 0.0
    return max(abs(fill[0] - stroke[0]), fat)


def _fill_error(fill, lk, standout):
    """CIEDE2000 of the painted fill to the nearest GT fill colour. With `standout`, a fill whose lightness is at
    least as far from the source's surround (its outline, else the listed background colours) as that GT fill's is
    compared at its own lightness: text that stands out more than the source did is not a colour error."""
    around = [c[0] for c in ((lk['strokes'] if lk['out'] else None) or lk['bgs'])] if standout else []
    best = float('inf')
    for q in lk['fills']:
        if around and min(abs(fill[0] - a) for a in around) >= min(abs(q[0] - a) for a in around):
            q = (fill[0], q[1], q[2])
        best = min(best, _de00(fill, q))
    return best


def appearance(lk, st, em, stroke_px, bold_gt, standout=False):
    """(style, contrast) of a painted block against the appearance GT `lk` and the weight GT (None: no GT), for the
    style as the painter draws it (notes/style.md)."""
    if st is None:
        fill, stroke, bold = (0, 0, 0), (255, 255, 255), False
    else:
        fill, bold = _rgb(st.get('textColor')), bool(st.get('bold'))
        stroke = _rgb(st.get('strokeColor')) if stroke_px > 0 else None
        if fill is None or (stroke_px > 0 and stroke is None):
            return 0.0, 0.0                     # a colour the painter cannot draw
    keep, contrast = 1.0, 1.0
    if lk:
        fill = _lab3(*fill)
        stroke = _lab3(*stroke) if stroke is not None else None
        keep *= 1 - W_LOOK * _colour_loss(_fill_error(fill, lk, standout), _dead(lk['conf_fill'], DEAD_FILL))
        if lk['out'] is None:
            pass
        elif lk['out'] != (stroke is not None):
            edge = stroke if stroke is not None else lk['strokes'][0] if lk['strokes'] else None
            seen = float(np.mean([_colour_loss(_de00(edge, q), JND) for q in lk['bgs']])) if edge is not None and lk['bgs'] else 1.0
            keep *= 1 - W_LOOK * (max(seen, NEEDED.get(lk['mode'], 0.0)) if stroke is None else seen)
        elif stroke is not None:
            agree = 1 - _colour_loss(min(_de00(stroke, q) for q in lk['strokes']), _dead(lk['conf_stroke'], DEAD_STROKE)) if lk['strokes'] else 1.0
            if lk['wlo'] is not None:
                w = stroke_px / em
                agree *= 1.0 if lk['wlo'] <= w <= lk['whi'] else w / lk['wlo'] if w < lk['wlo'] else lk['whi'] / w
            keep *= 1 - W_LOOK * (1 - agree)
        source = _seen(lk['fills'][0], lk['strokes'][0] if lk['out'] is not False and lk['strokes'] else None, lk['bgs'])
        if source >= 1:
            contrast = min(1.0, _seen(fill, stroke, lk['bgs']) / min(READABLE, source))
    if bold_gt is not None and bold != bold_gt:
        keep *= 1 - W_LOOK
    return keep, contrast


# ---------- one page ----------

def page(r, cfg=CONFIG, study=None):
    """-> (rows, GT regions, blocks without a GT region): one row {aspect: share, region, weight} per painted block
    that belongs to a GT region; weight = the part of its region's text the block carries (its share of the
    translation characters of the region's speech blocks, painted or not), so q of a region = sum of weight * q of
    its rows. `study(B)` may return further columns for a painted block (variant studies only)."""
    ts = tg
    pid = r['pageID']
    W, Hh = (r.get('width') if _num(r.get('width')) else 0), (r.get('height') if _num(r.get('height')) else 0)
    g = ts.gt().get(pid) or EMPTY
    need = g['regions']
    X = extras().get(pid) or dict(look={}, tilt={})
    blocks = {b['id']: b for b in r.get('blocks') or [] if isinstance(b, dict) and 'id' in b}
    # `paints` (newer runs): what S10 painted each block with, after the painter's legibility outline. It replaces
    # the style the outline would otherwise be modelled from.
    for q in r.get('paints') or []:
        b = blocks.get(q.get('blockID')) if isinstance(q, dict) else None
        if b is not None and isinstance(q.get('fill'), dict):
            wide = q.get('strokeWidth') if q.get('stroke') is not None else 0
            blocks[b['id']] = dict(b, style=dict(b.get('style') if isinstance(b.get('style'), dict) else {}, textColor=q['fill'],
                                                 strokeColor=q.get('stroke'), strokeWidth=wide, painted=True))
    syn = set(r.get('replaySyntheticBlocks') or [])
    sizes = [v[0] for v in g['size'].values()]
    page_px = float(np.median(sizes)) if sizes else None
    owner = {}

    def match(bid):
        """(the GT region the block's bounds belong to or None, the GT regions they cover by half or more)."""
        if bid not in owner:
            best, val, covered = None, 0, []
            try:
                (x, y), (w, h) = blocks[bid]['bounds']
                sane = all(_num(v) for v in (x, y, w, h)) and w > 0 and h > 0
            except (TypeError, ValueError, KeyError):
                sane = False
            if sane:
                bb = (x, y, x + w, y + h)
                for rid, box in need.items():
                    i = _inter(bb, box)
                    if i > val:
                        best, val = rid, i
                    if i >= 0.5 * max(1e-9, (box[2] - box[0]) * (box[3] - box[1])):
                        covered.append(rid)
                if best is not None:
                    box = need[best]
                    if val < 0.5 * min(w * h, max(1e-9, (box[2] - box[0]) * (box[3] - box[1]))):
                        best = None
            owner[bid] = (best, covered)
        return owner[bid]

    def place(rid, box):
        """Whether paint with this bounding box is at the region's place (the region box, its source ink box or its
        balloon's box): 1 when it touches one of them, falling with the gap to 0 at POSITION_SCALE em."""
        spots = [need[rid], g['ink'].get(rid, need[rid])]
        if rid in g['balloon']:
            spots.append(ts.balloons(pid)[g['balloon'][rid][0]][:4])
        if cfg['place'] == 'gap':
            src = g['ink'].get(rid, need[rid])
            em = (g['size'].get(rid) or (None,))[0] or min(page_px or float('inf'), src[2] - src[0], src[3] - src[1])
            gap = min(math.hypot(max(0, o[0] - box[2], box[0] - o[2]), max(0, o[1] - box[3], box[1] - o[3])) for o in spots)
            return max(0.0, 1 - gap / (POSITION_SCALE * max(1e-9, em)))
        best = 0.0
        for o in spots:
            most = min(box[2] - box[0], o[2] - o[0]) * min(box[3] - box[1], o[3] - o[1])
            if most > 0:
                best = max(best, _inter(box, o) / most)
        return min(1.0, best)

    extra, entries, obstacles, claimed = 0, [], [], set()
    for p in r.get('placed') or []:
        b = _valid(p, blocks)
        try:
            listed = p['blockID'] in syn
        except (TypeError, KeyError):
            listed = False
        if b is None:
            extra += not listed
            continue
        pt = paint(p, b)
        if pt is None:
            continue
        best, covered = match(p['blockID'])
        at = place(best, pt['box']) if best is not None else 0.0
        if at <= 0:
            best = None
        if listed:
            obstacles.append((pt['box'], pt['rects']))
            claimed.add(best); claimed.update(covered)
        elif best is None:
            extra += 1
            obstacles.append((pt['box'], pt['rects']))
        else:
            extra += 1 - at
            entries.append((p, b, pt, best, covered, at))
            claimed.add(best); claimed.update(covered)
    # the source ink of a GT region that no painted block's bounds hold is still on the page
    for rid, box in need.items():
        if rid not in claimed:
            a = g['ink'].get(rid, box)
            obstacles.append((a, [a]))
    # speech blocks with a translation belong to their region whether they are painted or not
    members = collections.defaultdict(dict)
    for bid, b in blocks.items():
        if bid in syn or b.get('role') not in SPEECH or not isinstance(b.get('translation'), str):
            continue
        want = len(''.join(display(b['translation']).split()))
        if want and match(bid)[0] is not None:
            members[match(bid)[0]][bid] = want
    edges = ts.art(pid, r['image'], list(g['regions'].values()) + list(g['ink'].values())) if entries else None
    R = rooms(pid) if entries and g['balloon'] else dict(room={}, centroid={}, alone={})
    got = collections.defaultdict(list)
    for k, (p, b, pt, rid, covered, at) in enumerate(entries):
        rects, box = pt['rects'], pt['box']
        area = _area(rects)
        em_p = p['fontPixels']
        src = g['ink'].get(rid, need[rid])
        px, lo, hi = g['size'].get(rid) or (None, None, None)
        short = min(src[2] - src[0], src[3] - src[1])
        if px is None and page_px:           # no size GT: at least the page's usual size or the source ink's short side
            px, lo, hi = min(page_px, short), INTERVAL[0] * min(page_px, short), float('inf')
        st = b.get('style')
        B = dict(p=p, b=b, pid=pid, rid=rid, g=g, rects=rects, box=box, src=src, stroke=pt['stroke'], al=pt['al'],
                 top=pt['top'], mid=pt['mid'],
                 em=px or short,      # no size GT on the page: the source ink's short side
                 gt_size=(px, lo, hi), painted=em_p * min(1.0, p.get('condense') or 1) ** CONDENSE_POWER,
                 bold=bool(st.get('bold')) if st else False, balloon=None, source_margin=0.0, room=None, centroid=None,
                 tilt=X['tilt'].get(rid, 0.0), words=())
        if pt['al'] is not None:
            shown = display(b['translation'])
            whole = pt['chars'][0] == pt['chars'][1] and len(pt['al'][0]) == pt['chars'][1]
            B['words'] = tuple(advance(w, B['bold']) for w in (shown if whole else ' '.join(p['lines'])).split())
        f = dict(region=rid, block=p['blockID'], chars=max(1, pt['chars'][1]), group=1 / max(1, len(covered)),
                 ratio=B['painted'] / px if px else None, place=at, balloon=1.0,
                 text=pt['seen'] * (pt['chars'][0] / pt['chars'][1] if pt['chars'][1] else 1.0))
        if rid in g['balloon']:
            idx, _, source_margin = g['balloon'][rid]
            x0, y0, x1, y1, dist = ts.balloons(pid)[idx]
            B.update(balloon=(x0, y0, dist), source_margin=source_margin, room=R['room'].get(rid),
                     centroid=R['centroid'][idx] if R['alone'][idx] else None)
            f['balloon'] = _inside(dist, x0, y0, rects)
        f['size'] = size(B, cfg['tau'], cfg['oracle'])
        f['margin'] = margin(B, cfg['margin'], cfg['tau'])
        others = [(e[2]['box'], e[2]['rects']) for j, e in enumerate(entries) if j != k]
        f['overlap'] = max(0.0, 1 - (_under(rects, box, others) + _under(rects, box, obstacles)) / area)
        f['inpage'] = min(1.0, sum(_inter(a, (0, 0, W, Hh)) for a in rects) / area)
        e, s = edges
        hit = cells = 0
        for a in rects:
            sub = e[max(0, int(a[1] * s)):max(0, int(a[3] * s) + 1), max(0, int(a[0] * s)):max(0, int(a[2] * s) + 1)]
            hit += int(np.count_nonzero(sub)); cells += sub.size
        f['art'] = 1 - hit / cells if cells else 1.0
        f['position'] = position(B, cfg['position'])
        f['breaks'] = breaks(B, cfg['tau'], cfg['shape'])
        f['style'], f['contrast'] = appearance(X['look'].get(rid), st, em_p, pt['stroke'], g['weight'].get(rid), cfg['fill'] == 'standout')
        if study:
            f.update(study(B))
        got[rid].append(f)
    rows, ratio = [], {}
    for rid, fs in got.items():
        chars = dict(members.get(rid) or {})
        chars.update({f['block']: f.pop('chars') for f in fs if f['block'] not in chars})
        entries_of = collections.Counter(f['block'] for f in fs)
        total = sum(chars.values())
        for f in fs:
            f.pop('chars', None)
            f['weight'] = chars[f['block']] / total / entries_of[f.pop('block')]
            f['group'] /= max(len(fs), len(members.get(rid) or ()))
            f['consistency'] = 1.0
        known = [(f['weight'], f['ratio']) for f in fs if f['ratio'] and f['ratio'] > 0]
        if known:
            ratio[rid] = sum(w * math.log(v) for w, v in known) / sum(w for w, _ in known)
        rows += fs
    for ids in g['classes']:
        mem = [i for i in ids if i in ratio]
        if len(mem) >= 2:
            med = float(np.median([ratio[i] for i in mem]))
            for f in rows:
                if f['region'] in mem:
                    f['consistency'] = math.exp(-abs(ratio[f['region']] - med))
    return rows, len(need), extra


# ---------- runs ----------

def quality(f, cfg=CONFIG, use=None):
    """q of a painted block from its aspects; `use` maps an aspect to another column (variant studies)."""
    v = lambda k: f[(use or {}).get(k, k)]
    q = math.prod(v(k) for k in LOST)
    q *= math.prod(v(k) for k in LOOK) if cfg['rule'] == 'product' else sum(v(k) for k in LOOK) / len(LOOK)
    return q if math.isfinite(q) and q > 0 else 0.0


def aspects(recs, cfg=CONFIG, study=None):
    """{pageID: (rows, GT regions, blocks without a region)} of a run's page records (see page())."""
    out = {r['pageID']: page(r, cfg, study) for r in recs}
    save()
    return out


def expected(pids):
    """Pages with GT regions of the manifest split(s) that `pids` come from."""
    split, G = _splits(), tg.gt()
    seen = {split[p] for p in pids if p in split} - {TEST_SPLIT}
    return [p for p, s in split.items() if s in seen and G.get(p) and G[p]['regions']]


# ---------- runs ----------

def records(path):
    return [json.load(open(f)) for f in sorted(Path(path, 'pages').glob('*.json'))]


def score_records(recs, expect=True, **over):
    """{pageID: dict(q, n, regions, painted, extra, weight, <aspect sums over painted blocks, by weight>)}.
    score = 100 * sum(q) / sum(n). expect: add the run's missing pages as not painted (see the module doc)."""
    cfg = dict(CONFIG, **over)
    res = {}
    for pid, (rows, regions, extra) in aspects(recs, cfg).items():
        if not (regions or extra):
            continue
        row = collections.Counter(q=sum(f['weight'] * quality(f, cfg) for f in rows), n=regions + extra, regions=regions, extra=extra,
                                  painted=len({f['region'] for f in rows}), weight=sum(f['weight'] for f in rows))
        for f in rows:
            for k in LOST + LOOK:
                row[k] += f['weight'] * f[k]
        res[pid] = dict(row)
    if expect and res:
        G = tg.gt()
        for pid in expected(res):
            res.setdefault(pid, dict(q=0.0, n=len(G[pid]['regions']), regions=len(G[pid]['regions']), extra=0, painted=0, weight=0.0))
    return res


def score_pages(recs, H=None, **over):
    """{pageID: (sum of q, GT regions + paint at no region's place)}: the research harness's candidate interface."""
    return {pid: (v['q'], v['n']) for pid, v in score_records(recs, **over).items()}


def run(path, **over):
    return score_records(records(str(path).rstrip('/')), **over)


def score(res, pages=None):
    v = [res[p] for p in (res if pages is None else pages)]
    return 100 * sum(x['q'] for x in v) / max(1e-12, sum(x['n'] for x in v))


def summary(res):
    regions, painted, extra, weight = (sum(v[k] for v in res.values()) for k in ('regions', 'painted', 'extra', 'weight'))
    return dict(score=round(score(res), 3), regions=regions, painted=round(100 * painted / max(1, regions), 2), extra=round(extra, 2),
                **{k: round(100 * sum(v.get(k, 0) for v in res.values()) / max(1e-9, weight), 2) for k in LOST + LOOK})


def compare(base, var, draws=4000, seed=0):
    """Paired score difference VAR - BASE over the pages of both (a page only one has counts 0 / 0 on the other side,
    which run() avoids by adding the split's missing pages) with a page-bootstrap 95% interval."""
    pages = sorted(set(base) | set(var))
    a = np.array([[base[p]['q'], base[p]['n']] if p in base else [0, 0] for p in pages], float)
    b = np.array([[var[p]['q'], var[p]['n']] if p in var else [0, 0] for p in pages], float)
    idx = np.random.default_rng(seed).integers(len(pages), size=(draws, len(pages)))
    d = 100 * (b[idx, 0].sum(1) / np.maximum(1e-12, b[idx, 1].sum(1)) - a[idx, 0].sum(1) / np.maximum(1e-12, a[idx, 1].sum(1)))
    sa, sb = summary(base), summary(var)
    return dict(pages=len(pages), base=sa['score'], var=sb['score'], diff=round(sb['score'] - sa['score'], 3),
                low=round(float(np.percentile(d, 2.5)), 3), high=round(float(np.percentile(d, 97.5)), 3),
                aspects={k: round(sb[k] - sa[k], 2) for k in ('painted', 'extra') + LOST + LOOK})


def selftest(path):
    """Synthetic damage on the run's records; each must lower the score."""
    recs = records(path)
    base = score(score_records(recs))

    def each(fn, style=False):
        out = copy.deepcopy(recs)
        for r in out:
            for k, x in enumerate(r['blocks'] if style else r['placed']):
                if not style or x.get('style'):
                    fn(x['style'] if style else x, k)
        return out

    def scale(c, every=1):
        def fn(p, k):
            if k % every == 0:
                (x, y), (w, h) = p['frame']
                p['fontPixels'] *= c
                p['frame'] = [[x + w * (1 - c) / 2, y + h * (1 - c) / 2], [w * c, h * c]]
        return fn

    def shift(em):
        def fn(p, k):
            p['frame'] = [[p['frame'][0][0] + em * p['fontPixels'], p['frame'][0][1]], p['frame'][1]]
        return fn

    def drop(n):
        out = copy.deepcopy(recs)
        for r in out:
            r['placed'] = [p for k, p in enumerate(r['placed']) if k % n]
        return out

    def invert(st, k):
        c = st['textColor']
        st['textColor'] = dict(c, r=255 - c['r'], g=255 - c['g'], b=255 - c['b'])

    def flip_outline(st, k):
        if st.get('strokeColor') is not None and (st.get('strokeWidth') or 0) > 0:
            st['strokeColor'] = None
        else:
            st['strokeColor'] = dict(st['textColor'], r=255 - st['textColor']['r'], g=255 - st['textColor']['g'], b=255 - st['textColor']['b'])
            st['strokeWidth'] = 0.1 * (st.get('fontPixels') or 20)

    def squash(p, k):
        p['condense'] = (p.get('condense') or 1) * 0.8

    def tilt(p, k):
        p['angle'] = (p.get('angle') or 0) + 0.2

    def lose(p, k):
        if len(p['lines']) > 1:
            p['lines'] = p['lines'][:-1]

    def frame_only(p, k):
        (x, y), (w, h) = p['frame']
        p['frame'] = [[x + w * 0.15, y + h * 0.15], [w * 0.7, h * 0.7]]

    cases = [('font x0.95', each(scale(0.95))), ('font x0.8', each(scale(0.8))), ('font x1.35', each(scale(1.35))),
             ('every other block x0.8', each(scale(0.8, 2))), ('shift 1 em', each(shift(1))), ('shift 3 em', each(shift(3))),
             ('drop every 5th block', drop(5)), ('last line not painted', each(lose)), ('frame x0.7, font kept', each(frame_only)),
             ('glyphs condensed x0.8', each(squash)), ('rotated 0.2 rad', each(tilt)),
             ('fill colour inverted', each(invert, style=True)), ('outline flipped', each(flip_outline, style=True))]
    print(f'base {base:.2f}')
    ok = True
    for name, damaged in cases:
        v = score(score_records(damaged))
        ok &= v < base
        print(f'  {name}: {v:.2f} ({v - base:+.2f}){"" if v < base else "  NOT LOWER"}')
    return ok


if __name__ == '__main__':
    a = sys.argv[1:]
    if a and a[0] == '--cmp':
        print(json.dumps(compare(run(a[1]), run(a[2]))))
    elif a and a[0] == '--selftest':
        sys.exit(0 if selftest(a[1]) else 1)
    else:
        for p in a:
            print(p.rstrip('/').split('/')[-1], json.dumps(summary(run(p))))
