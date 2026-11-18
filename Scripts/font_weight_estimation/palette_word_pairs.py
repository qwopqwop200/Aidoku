"""Whole-word evidence using the source predictor's observed fill palette.

No annotation colours are read. Palette entries nearly identical to predicted
fill cannot simultaneously serve as negative background evidence.
"""
import math

import cv2
import numpy as np

from masked_word_pairs import prepare, fit
from word_pairs import PAIR_FIELDS
from optimized_features.templates import rotate, pose_angle


def observe_palette(rgb, ownership, style):
    pixels = np.asarray(rgb, float)
    own = np.asarray(ownership, bool)
    if pixels.ndim != 3 or pixels.shape[2] != 3 or own.shape != pixels.shape[:2]:
        raise ValueError('Source palette geometry differs')
    fills = np.unique(np.asarray([style['fill']['rgb'], *style['fill'].get('colors', [])], float), axis=0)
    colors = []
    for part in ('background', 'outline', 'shadow'):
        value = style.get(part, {})
        if part != 'background' and not value.get('present'):
            continue
        if value.get('rgb') is not None:
            colors.append(value['rgb'])
        if part == 'background':
            colors.extend(value.get('colors', []))
    backgrounds = [color for color in np.unique(np.asarray(colors, float), axis=0)
                   if np.linalg.norm(fills-color, axis=1).min() > 35] if colors else []
    best = np.full(own.shape, np.inf)
    alpha = np.zeros(own.shape)
    for fill in fills:
        for other in backgrounds:
            delta = fill-other
            t = np.clip(((pixels-other)*delta).sum(2)/np.dot(delta, delta), 0, 1)
            residual = np.linalg.norm(pixels-(other+t[:, :, None]*delta), axis=2)
            better = residual < best-1e-6
            alpha[better] = t[better]
            best[better] = residual[better]
    observed = (best < 22) & (own | (alpha < .25))
    return alpha.astype(np.float32), observed


def prepare_palette(rgb, bbox, source_em, text, ownership, style, angle):
    p = prepare(rgb, bbox, source_em, text, ownership, style, angle)
    if p is None:
        for color in style['fill'].get('colors', []):
            alternate = dict(style, fill=dict(style['fill'], rgb=color))
            p = prepare(rgb, bbox, source_em, text, ownership, alternate, angle)
            if p is not None:
                break
    if p is None:
        return None
    alpha, observed = observe_palette(rgb, ownership, style)
    if abs(angle) > .1:
        alpha, _ = rotate(alpha, bbox, angle)
        observed, _ = rotate(observed.astype(np.uint8), bbox, angle, nearest=True)
    scale = min(1., 640/max(alpha.shape))
    if scale < 1:
        alpha = cv2.resize(alpha, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        observed = cv2.resize(observed.astype(np.float32), (alpha.shape[1], alpha.shape[0]),
                              interpolation=cv2.INTER_AREA) > .99
    p['alpha'] = alpha
    p['observed'] = observed
    ys, xs = np.nonzero((alpha > .4) & observed)
    if len(xs) >= 5:
        spans = (ys.max()-ys.min()+1, xs.max()-xs.min()+1)
        p['long'], p['cross'] = spans if p['vertical'] else spans[::-1]
    return p


def measure(rgb, bbox, source_em, text, ownership, style, pairs, members=None):
    members = members or [dict(bbox=bbox, text=text)]
    members = sorted(members, key=lambda m: (-m['bbox'][0], m['bbox'][1])
                     if bbox[3] >= bbox[2] else (m['bbox'][1], m['bbox'][0]))
    if len(members) > 6:
        members = [members[i] for i in np.linspace(0, len(members)-1, 6).astype(int)]
    collected = [[] for _ in pairs]
    for member in members:
        x, y, w, h = member['bbox']
        l, t = max(0, math.floor(x-.1*w)), max(0, math.floor(y-.1*h))
        r, b = min(rgb.shape[1], math.ceil(x+1.1*w)), min(rgb.shape[0], math.ceil(y+1.1*h))
        if l >= r or t >= b or x < 0 or y < 0 or x+w > rgb.shape[1]+1 or y+h > rgb.shape[0]+1:
            continue
        angle = pose_angle(member['polygon']) if member.get('polygon') else 0.
        p = prepare_palette(rgb[t:b, l:r], [x-l, y-t, w, h], source_em, member['text'],
                            ownership[t:b, l:r], style, angle)
        if p is None:
            continue
        coarse = [fit(p, pair) for pair in pairs]
        families = {}
        for pair, value in zip(pairs, coarse):
            families[pair['name']] = max(families.get(pair['name'], 0), value[18])
        selected = set(sorted(families, key=lambda name: -families[name])[:2])
        for i, (pair, value) in enumerate(zip(pairs, coarse)):
            if pair['name'] in selected and value[-1] > 0:
                value = fit(p, pair, True)
            if value[-1] > 0:
                collected[i].append(value)
    out = []
    for rows in collected:
        if not rows:
            out.extend(np.zeros(PAIR_FIELDS))
            continue
        rows = np.asarray(rows)
        weights = np.maximum(.01, rows[:, 18])**4
        out.extend(np.r_[np.average(rows, axis=0, weights=weights), rows[rows[:, 18].argmax()]])
    result = np.asarray(out, float)
    if result.shape != (len(pairs)*PAIR_FIELDS,) or not np.isfinite(result).all():
        raise ValueError('Invalid palette word evidence')
    return result
