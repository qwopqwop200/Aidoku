"""Ordered glyph registration for lines with unequal punctuation/kana sizes.

Projection cuts preserve OCR order and whole glyphs; they never independently
search an entire word for the most convenient radical. All measurements stay
inside the caller's already bounded source crop.
"""
import unicodedata

import cv2
import numpy as np

from masked_word_pairs import correlation, pattern_pair
from reference_grid import masks
from registered_stroke_evidence import profile

SMALL_KANA = frozenset('ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ')


def advances(text):
    return [(.65 if c in SMALL_KANA else .5 if unicodedata.category(c) in ('Ps', 'Pe', 'Pi', 'Pf') else 1.)
            for c in text]


def partition(alpha, known, expected, vertical):
    alpha, known = np.asarray(alpha, np.float32), np.asarray(known, bool)
    if alpha.ndim != 2 or alpha.shape != known.shape or not np.isfinite(alpha).all():
        raise ValueError('Invalid ordered glyph source')
    if not expected or any(not np.isfinite(v) or v <= 0 for v in expected):
        return []
    ink = (alpha > .5) & known
    projection = ink.sum(axis=1 if vertical else 0).astype(float)
    occupied = np.flatnonzero(projection)
    if not len(occupied):
        return []
    start, stop = int(occupied[0]), int(occupied[-1]+1)
    projection = projection[start:stop]
    length, count = len(projection), len(expected)
    if length < 2*count:
        return []
    unit = length/sum(expected)
    cut = np.r_[0., (projection[:-1]+projection[1:])/(2*max(1., projection.max())), 0.]
    cost = np.full((count+1, length+1), np.inf)
    previous = np.full(cost.shape, -1, int)
    cost[0, 0] = 0
    for i, advance in enumerate(expected, 1):
        target = unit*advance
        lower, upper = max(2, int(.4*target)), max(3, int(1.8*target)+1)
        for end in range(2*i, length+1):
            origins = np.arange(max(0, end-upper), end-lower+1)
            if not len(origins):
                continue
            score = cost[i-1, origins]+.5*((end-origins-target)/max(1., target))**2+2*cut[end]
            best = int(score.argmin())
            if np.isfinite(score[best]):
                cost[i, end], previous[i, end] = score[best], origins[best]
    if not np.isfinite(cost[count, length]):
        return []
    cuts, end = [length], length
    for i in range(count, 0, -1):
        end = int(previous[i, end])
        cuts.append(end)
    cuts = cuts[::-1]
    return [(start+a, start+b) for a, b in zip(cuts[:-1], cuts[1:])]


def measure(alpha, known, text, vertical, family, unit, profile_fn=profile):
    text = ''.join(c for c in unicodedata.normalize('NFC', text) if not c.isspace())
    intervals = partition(alpha, known, advances(text), vertical)
    if len(intervals) != len(text):
        return dict(usable=False, glyphs=[], reason='No complete ordered partition')
    glyphs = []
    for char, (begin, end) in zip(text, intervals):
        # Punctuation still anchors the partition but is not evidence for the
        # ordinary body weight of the translated text.
        if unicodedata.category(char)[0] not in 'LN':
            continue
        sy, sx = (slice(begin, end), slice(None)) if vertical else (slice(None), slice(begin, end))
        src, valid = alpha[sy, sx], known[sy, sx]
        yy, xx = np.nonzero((src > .5) & valid)
        if len(xx) < 8:
            continue
        l, t, r, b = int(xx.min()), int(yy.min()), int(xx.max()+1), int(yy.max()+1)
        pad = max(3, round(.1*unit))
        height, width = src.shape
        bounds = max(0, t-pad), min(height, b+pad), max(0, l-pad), min(width, r+pad)
        top, bottom, left, right = bounds
        src, valid = src[top:bottom, left:right], valid[top:bottom, left:right]
        padding = ((max(0, pad-t), max(0, b+pad-height)),
                   (max(0, pad-l), max(0, r+pad-width)))
        src, valid = np.pad(src, padding), np.pad(valid, padding, constant_values=False)
        base = masks(family, char, vertical)
        if base is None:
            continue
        contours, _ = cv2.findContours((base[0] > .5).astype(np.uint8),
                                       cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
        information = sum(cv2.arcLength(c, True) for c in contours)/128
        # One pose is chosen by the mean score of both endpoints, preventing
        # either bold or normal from selecting a privileged glyph geometry.
        scale = max(b-t, r-l)/max(base[0].shape)
        best = None
        scales = {scale*.95, scale, scale*1.05, unit/128}
        for current_scale in sorted(scales):
            if not .5 <= current_scale*128/unit <= 1.6:
                continue
            for cross in (.9, 1., 1.1):
                images = pattern_pair(base, current_scale, cross, 0., vertical, src.shape)
                if images is None:
                    continue
                a, heavy = images
                ca, cb = correlation(src, valid, a), correlation(src, valid, heavy)
                if ca is None or cb is None:
                    continue
                _, score, _, (x, y) = cv2.minMaxLoc((ca+cb)/2)
                if best is None or score > best[0]:
                    best = score, float(ca[y, x]), float(cb[y, x]), x, y, a, heavy
        if best is None:
            continue
        score, normal_score, heavy_score, x, y, a, heavy = best
        sy, sx = slice(y, y+a.shape[0]), slice(x, x+a.shape[1])
        evidence = profile_fn(src[sy, sx], a, heavy, valid[sy, sx], unit)
        reference_ink = (a > .1) | (heavy > .1)
        known_support = float(valid[sy, sx][reference_ink].mean()) if reference_ink.any() else 0.
        glyphs.append(dict(evidence, templateFit=float(score), normalFit=normal_score,
                           heavyFit=heavy_score, heavyMargin=heavy_score-normal_score,
                           referencePerimeterEm=float(information),
                           referenceKnownSupport=known_support,
                           sourceInterval=[begin, end]))
    return dict(usable=bool(glyphs), glyphs=glyphs, orderedGlyphCount=len(intervals),
                noIndependentRadicalSearch=True, newModelCreated=False, modelTrainingPerformed=False)
