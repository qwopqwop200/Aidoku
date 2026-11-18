"""Font-style residuals against the same OCR glyph, not glyph/token identity."""

import cv2
import numpy as np
from template_features import glyph_bitmap, transformed_glyph, best_template_match


def moments(a, unit):
    a = np.asarray(a, float)
    h, w = a.shape
    mass = max(1e-07, a.sum())
    yy, xx = np.indices(a.shape)
    xx = xx - (w - 1) / 2
    yy = yy - (h - 1) / 2
    cx = (a * xx).sum() / mass
    cy = (a * yy).sum() / mass
    dx = xx - cx
    dy = yy - cy
    binary = (a > 0.5).astype(np.uint8)
    positions = np.argwhere(binary)
    bh, bw = np.ptp(positions, axis=0) + 1 if len(positions) else (0, 0)
    n, _ = cv2.connectedComponents(binary, 8)
    contours, hierarchy = cv2.findContours(
        binary, cv2.RETR_CCOMP, cv2.CHAIN_APPROX_SIMPLE
    )
    perimeter = sum((cv2.arcLength(c, True) for c in contours))
    holes = int((hierarchy[0, :, 3] >= 0).sum()) if hierarchy is not None else 0
    hull_area = (
        cv2.contourArea(cv2.convexHull(np.concatenate(contours))) if contours else 0.0
    )
    depth = cv2.distanceTransform(binary, cv2.DIST_L2, 3)
    positive = depth[depth > 0]
    stroke = (
        np.quantile(positive, [0.25, 0.5, 0.75, 0.9]) / unit
        if len(positive)
        else np.zeros(4)
    )
    edge = max(1, round(unit * 0.025))
    rim = np.ones(a.shape, bool)
    rim[edge : max(edge, h - edge), edge : max(edge, w - edge)] = False
    grid = []
    for ys in np.array_split(np.arange(h), 3):
        for xs in np.array_split(np.arange(w), 3):
            grid.append(float(a[np.ix_(ys, xs)].sum() / mass))
    value = np.r_[
        mass / unit**2,
        bw / unit,
        bh / unit,
        cx / unit,
        cy / unit,
        (a * dx**2).sum() / mass / unit**2,
        (a * dy**2).sum() / mass / unit**2,
        (a * dx * dy).sum() / mass / unit**2,
        (a * dx**3).sum() / mass / unit**3,
        (a * dy**3).sum() / mass / unit**3,
        binary.sum() / unit**2,
        perimeter / unit,
        np.log1p(max(0, n - 1)),
        np.log1p(holes),
        mass / max(1, bw * bh),
        np.abs(np.diff(a, axis=1)).sum() / unit,
        np.abs(np.diff(a, axis=0)).sum() / unit,
        hull_area / unit**2,
        stroke,
        a[rim].sum() / mass,
        grid,
    ]
    assert len(value) == 32 and np.isfinite(value).all()
    return value


def glyph_style(alpha, observed, chars, font, em):
    vectors = []
    weights = []
    ratios = [0, 1, 2, 10, 11, 14, 15, 16, 17, 18, 19, 20, 21]
    for char in chars:
        bitmap = glyph_bitmap(font, char)
        if bitmap is None:
            continue
        matches = []
        for aspect in [0.9, 1.0, 1.1]:
            result = best_template_match(alpha, bitmap, em, 1.0, aspect)
            if result is not None:
                matches.append((result[0], aspect, result[1]))
        if not matches:
            continue
        score, aspect, (x, y) = max(matches, key=lambda m: (m[0], -abs(m[1] - 1)))
        if score < 0.2:
            continue
        ink = transformed_glyph(bitmap, em, 1.0, aspect)
        pad = max(1, round(em * 0.12))
        reference = np.pad(ink, pad)
        h, w = reference.shape
        source = np.zeros((h, w), np.float32)
        valid = np.zeros((h, w), bool)
        left = x - pad
        top = y - pad
        l = max(0, left)
        t = max(0, top)
        r = min(alpha.shape[1], left + w)
        b = min(alpha.shape[0], top + h)
        if l >= r or t >= b:
            continue
        source[t - top : b - top, l - left : r - left] = alpha[t:b, l:r]
        valid[t - top : b - top, l - left : r - left] = observed[t:b, l:r]
        if valid.mean() < 0.9:
            continue
        binary = (source > 0.5).astype(np.uint8)
        n, lab, stats, _ = cv2.connectedComponentsWithStats(binary, 8)
        inside = np.zeros(source.shape, bool)
        inside[pad : pad + ink.shape[0], pad : pad + ink.shape[1]] = True
        overlap = np.bincount(lab[inside].ravel(), minlength=n)
        keep = overlap / np.maximum(1, stats[:, 4]) >= 0.3
        keep[0] = False
        support = cv2.dilate(keep[lab].astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
        source *= support & valid
        if source.sum() < 1:
            continue
        a = moments(source, em)
        b = moments(reference, em)
        positive = np.maximum(0, source - reference).sum() / max(1.0, reference.sum())
        negative = np.maximum(0, reference - source).sum() / max(1.0, reference.sum())
        relative = np.log(np.maximum(0.0001, a[ratios]) / np.maximum(0.0001, b[ratios]))
        residual = source - reference
        v = np.r_[
            a - b,
            relative,
            score,
            np.log(aspect),
            positive,
            negative,
            np.sqrt(np.mean(residual**2)),
            valid.mean(),
        ]
        assert len(v) == 51 and np.isfinite(v).all()
        vectors.append(v)
        weights.append(score**4)
    if not vectors:
        return np.zeros(258)
    v = np.asarray(vectors)
    weights = np.asarray(weights)
    return np.r_[
        np.quantile(v, [0.2, 0.5, 0.8], axis=0).ravel(),
        np.average(v, weights=weights, axis=0),
        v.std(axis=0),
        len(v) / 4,
        float(np.mean(weights) ** 0.25),
        np.log1p(len(chars)),
    ]
