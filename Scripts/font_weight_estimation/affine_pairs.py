"""Shared-pose weight fits with visibility-aware glyph witnesses.

Pose is selected by the stronger regular OR heavy fit, not their mean. A clear
heavy glyph must not lose to an ambiguous regular/heavy compromise. Both faces
are still scored at exactly the same source location, scale, aspect and angle.
Only source measurements are returned, never glyph IDs or transcripts.
"""
import cv2
import numpy as np

from features import stroke_summary
from native_pairs import glyph, SCALES
from physical_templates import paired_patterns
from optimized_features.fill_alpha import predicted_fill_alpha
from optimized_features.templates import rotate, anchor_chars


def transformed_pair(regular, heavy, unit, aspect=1., angle=0.):
    a, b = paired_patterns(regular, heavy, unit)
    if aspect != 1.:
        width = max(2, round(a.shape[1]*aspect))
        a = cv2.resize(a, (width, a.shape[0]), interpolation=cv2.INTER_LINEAR)
        b = cv2.resize(b, (width, b.shape[0]), interpolation=cv2.INTER_LINEAR)
    if angle:
        frame = [0, 0, a.shape[1], a.shape[0]]
        a, _ = rotate(a, frame, angle)
        b, _ = rotate(b, frame, angle)
    return np.asarray(a, np.float32), np.asarray(b, np.float32)


def locate(alpha, a, b):
    if a.shape[0] > alpha.shape[0] or a.shape[1] > alpha.shape[1]:
        return None
    ca = cv2.matchTemplate(alpha, a, cv2.TM_CCOEFF_NORMED)
    cb = cv2.matchTemplate(alpha, b, cv2.TM_CCOEFF_NORMED)
    objective = np.where(np.isfinite(ca+cb), np.maximum(ca, cb), -1.)
    _, score, _, (x, y) = cv2.minMaxLoc(objective)
    return score, float(ca[y, x]), float(cb[y, x]), x, y


def fit(alpha, regular, heavy, unit):
    best = None
    for factor in SCALES:
        a, b = transformed_pair(regular, heavy, unit*factor)
        match = locate(alpha, a, b)
        if match is not None and (best is None or match[0] > best[0][0]):
            best = match, factor, 1., 0., a, b
    if best is None:
        return np.zeros(24)
    coarse_score = best[0][0]
    factor = best[1]
    # Exact good matches do not need extra shape freedom. Refine uncertain
    # pairs identically for either weight, without observing any target label.
    if coarse_score < .85:
        for aspect in (.9, 1., 1.1):
            for angle in (-4., 0., 4.):
                if aspect == 1. and angle == 0.:
                    continue
                a, b = transformed_pair(regular, heavy, unit*factor, aspect, angle)
                match = locate(alpha, a, b)
                if match is not None and match[0] > best[0][0]:
                    best = match, factor, aspect, angle, a, b
    (score, ra, rb, x, y), factor, aspect, angle, a, b = best
    source = alpha[y:y+a.shape[0], x:x+a.shape[1]]
    mass = float(source.sum())
    areas = [float(a.sum()), float(b.sum())]
    dice = [2*float(np.minimum(source, v).sum())/max(1e-6, mass+area)
            for v, area in zip((a, b), areas)]
    strokes = [stroke_summary(v > .5, unit, allow_boundary=True)[2] for v in (source, a, b)]
    return np.r_[score, ra, rb, rb-ra, factor, dice, dice[1]-dice[0],
                 [np.log(max(1e-6, mass)/max(1e-6, area)) for area in areas],
                 strokes, float((source > .5).mean()), float(score > .5), 1.,
                 aspect, angle/4., score-coarse_score, coarse_score, 0., 0., 0., 0.]


def measure(rgb, bbox, source_em, text, ownership, style, pairs, angle=0.):
    if not 1 <= len(pairs) <= 8 or not np.isfinite(source_em) or source_em <= 0:
        raise ValueError('Invalid source font family contract')
    alpha = predicted_fill_alpha(rgb, bbox, ownership, style)
    if abs(angle) > .1:
        alpha, _ = rotate(alpha, bbox, angle)
    scale = min(1., 480/max(alpha.shape))
    if scale < 1:
        alpha = cv2.resize(alpha, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    alpha = np.asarray(alpha, np.float32)
    if alpha.sum() < 1:
        return np.zeros(48*len(pairs))
    unit = source_em*scale
    # Use two independent glyph witnesses. Dense characters may be occluded;
    # requiring that single character to explain a whole region loses evidence.
    from font_metric_features import default_font_paths
    chars = anchor_chars(text, default_font_paths()[0], 256, exclude_small=True)
    groups = [[c for c in chars if 0x3040 <= ord(c) <= 0x30ff][:2],
              [c for c in chars if not 0x3040 <= ord(c) <= 0x30ff][:2]]
    output = []
    for pair in pairs:
        for witnesses in groups:
            values = []
            for char in witnesses:
                a, b = glyph(pair['regular'], char), glyph(pair['heavy'], char)
                if a is not None and b is not None:
                    values.append(fit(alpha, a, b, unit))
            if not values:
                output.extend(np.zeros(24))
                continue
            value = max(values, key=lambda v: v[0]).copy()
            array = np.asarray(values)
            value[20:] = [float((array[:, 0] >= .5).mean()),
                          float(np.median(array[:, 3])), float(np.median(array[:, 7])),
                          float(np.mean(array[:, 0]))]
            output.extend(value)
    result = np.asarray(output)
    if result.shape != (48*len(pairs),) or not np.isfinite(result).all():
        raise ValueError('Invalid affine shared-weight features')
    return result
