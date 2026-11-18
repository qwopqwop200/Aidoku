"""Same-family regular/heavy fits of source-owned fill alpha.

Unlike intensity threshold matches, this separates outline and background and
compares actual regular/heavy outlines for rounded, gothic and serif families.
Only pooled fit/stroke measurements leave this module, never glyph identities.
"""
from functools import lru_cache
import hashlib
from pathlib import Path
import unicodedata

import cv2
import numpy as np
from PIL import ImageFont

from features import stroke_summary
from physical_templates import paired_patterns
from optimized_features.fill_alpha import predicted_fill_alpha
from optimized_features.templates import rotate

FEATURE_COUNT = 128
EM = 128
SCALES = (.85, .95, 1., 1.05, 1.15)


@lru_cache(maxsize=16)
def reference_font(path, digest, weight):
    if hashlib.sha256(Path(path).read_bytes()).hexdigest() != digest:
        raise ValueError('Reference font identity differs')
    font = ImageFont.truetype(path, EM)
    if weight is not None:
        axes = font.get_variation_axes()
        values = [float(axis['default']) for axis in axes]
        indices = [i for i, axis in enumerate(axes) if axis['name'] == b'Weight']
        if len(indices) != 1:
            raise ValueError('Expected one weight axis')
        values[indices[0]] = float(weight)
        font.set_variation_by_axes(values)
    return font


@lru_cache(maxsize=1024)
def bitmap(path, digest, weight, char):
    mask = reference_font(path, digest, weight).getmask(char, mode='L')
    if not min(mask.size):
        return None
    image = np.asarray(mask, np.uint8).reshape(mask.size[1], mask.size[0])
    ys, xs = np.nonzero(image > 40)
    if not len(xs):
        return None
    return image[ys.min():ys.max()+1, xs.min():xs.max()+1].copy()


def glyph(record, char):
    return bitmap(record['path'], record['SHA256'], record.get('weight'), char)


def fit_pair(alpha, regular, heavy, unit):
    best = None
    for factor in SCALES:
        a, b = paired_patterns(regular, heavy, unit*factor)
        if a.shape[0] > alpha.shape[0] or a.shape[1] > alpha.shape[1]:
            continue
        ca = cv2.matchTemplate(alpha, a, cv2.TM_CCOEFF_NORMED)
        cb = cv2.matchTemplate(alpha, b, cv2.TM_CCOEFF_NORMED)
        joint = np.where(np.isfinite(ca+cb), (ca+cb)/2, -1.)
        _, score, _, (x, y) = cv2.minMaxLoc(joint)
        if best is None or score > best[0]:
            best = score, float(ca[y, x]), float(cb[y, x]), factor, x, y, a, b
    if best is None:
        return np.zeros(16)
    score, ra, rb, factor, x, y, a, b = best
    source = alpha[y:y+a.shape[0], x:x+a.shape[1]]
    mass = float(source.sum())
    areas = [float(a.sum()), float(b.sum())]
    dice = [2*float(np.minimum(source, v).sum())/max(1e-6, mass+area)
            for v, area in zip((a, b), areas)]
    strokes = [stroke_summary(v > .5, unit, allow_boundary=True)[2]
               for v in (source, a, b)]
    return np.r_[score, ra, rb, rb-ra, factor, dice, dice[1]-dice[0],
                 [np.log(max(1e-6, mass)/max(1e-6, area)) for area in areas],
                 strokes, float((source > .5).mean()), float(score > .5), 1.]


def measure(rgb, bbox, source_em, text, ownership, style, pairs, angle=0.):
    if not 1 <= len(pairs) <= 8 or not np.isfinite(source_em) or source_em <= 0:
        raise ValueError('Invalid source-em/reference-family contract')
    alpha = predicted_fill_alpha(rgb, bbox, ownership, style)
    if abs(angle) > .1:
        alpha, _ = rotate(alpha, bbox, angle)
    scale = min(1., 480/max(alpha.shape))
    if scale < 1:
        alpha = cv2.resize(alpha, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    alpha = np.asarray(alpha, np.float32)
    unit = source_em*scale
    groups = [[], []]
    for char in sorted(set(unicodedata.normalize('NFC', text or ''))):
        if char.isspace() or unicodedata.category(char)[0] in 'MCPZS':
            continue
        if char in 'ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ':
            continue
        raster = glyph(pairs[0]['regular'], char)
        if raster is not None:
            groups[0 if 0x3040 <= ord(char) <= 0x30ff else 1].append((int((raster > 40).sum()), char))
    witnesses = [[c for _, c in sorted(group, reverse=True)[:1]] for group in groups]
    output = []
    for pair in pairs:
        for chars in witnesses:
            values = []
            for char in chars:
                a, b = glyph(pair['regular'], char), glyph(pair['heavy'], char)
                if a is not None and b is not None:
                    values.append(fit_pair(alpha, a, b, unit))
            output.extend(np.median(values, axis=0) if values else np.zeros(16))
    result = np.asarray(output)
    if result.shape != (32*len(pairs),) or not np.isfinite(result).all():
        raise ValueError('Invalid paired-family source metrics')
    return result
