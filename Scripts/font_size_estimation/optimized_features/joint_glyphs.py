"""Shared em/aspect and non-reused source positions for multiple OCR glyphs."""

import cv2
import numpy as np
from template_features import transformed_glyph, glyph_bitmap


def local_matches(alpha, bitmap, unit, factor, aspect, limit=3):
    ink = transformed_glyph(bitmap, unit, factor, aspect)
    h, w = ink.shape
    pad = max(1, round(unit * factor * 0.04))
    pattern = np.pad(ink, pad)
    target = np.pad(alpha, pad)
    if (
        pattern.shape[0] > target.shape[0]
        or pattern.shape[1] > target.shape[1]
        or np.std(pattern) < 1e-05
    ):
        return []
    corr = cv2.matchTemplate(target, pattern, cv2.TM_CCOEFF_NORMED)
    corr = np.where(np.isfinite(corr), corr, -1.0)
    matches = []
    for _ in range(limit):
        _, score, _, (x, y) = cv2.minMaxLoc(corr)
        if score <= 0:
            break
        matches.append((float(score), (x, y, x + w, y + h)))
        rx = max(1, round(w * 0.6))
        ry = max(1, round(h * 0.6))
        corr[
            max(0, y - ry) : min(corr.shape[0], y + ry + 1),
            max(0, x - rx) : min(corr.shape[1], x + rx + 1),
        ] = -1
    return matches


def collides(a, b):
    inter = max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(
        0, min(a[3], b[3]) - max(a[1], b[1])
    )
    area = min((a[2] - a[0]) * (a[3] - a[1]), (b[2] - b[0]) * (b[3] - b[1]))
    return inter / max(1, area) > 0.2


def assignment(matches):
    beam = [([], [])]
    for options in matches:
        candidates = []
        for scores, boxes in beam:
            candidates.append((scores + [0.0], boxes))
            for score, box in options:
                if not any((collides(box, other) for other in boxes)):
                    candidates.append((scores + [score], boxes + [box]))
        candidates.sort(key=lambda state: sum(state[0]), reverse=True)
        beam = candidates[:12]
    scores = sorted(beam[0][0])
    strict = float(np.mean(scores))
    trimmed = float(np.mean(scores[1:])) if len(scores) >= 3 else strict
    independent = float(np.mean([o[0][0] if o else 0 for o in matches]))
    return (
        strict,
        trimmed,
        independent - strict,
        float(np.count_nonzero(scores) / max(1, len(scores))),
    )


def joint_glyphs(alpha, chars, font_paths, font_indices, unit, old_factors):
    values = []
    for j in font_indices:
        bitmaps = [glyph_bitmap(font_paths[j], c) for c in chars]
        bitmaps = [b for b in bitmaps if b is not None]
        if not bitmaps:
            values.extend([0.0] * 24)
            continue
        centre = float(np.clip(old_factors[j], 0.5, 1.6))
        scales = np.unique(np.r_[np.arange(0.5, 1.601, 0.08), centre])
        observations = []

        def observe(factor, aspect):
            matches = [local_matches(alpha, b, unit, factor, aspect) for b in bitmaps]
            strict, trim, gap, coverage = assignment(matches)
            return (factor, aspect, strict, trim, gap, coverage)

        for aspect in [0.85, 1.0, 1.15]:
            for factor in scales:
                observations.append(observe(float(factor), aspect))
        initial = np.asarray(observations)
        for kind in [2, 3]:
            best = initial[np.argmax(initial[:, kind])]
            for factor in np.arange(
                max(0.4, best[0] - 0.08), min(1.8, best[0] + 0.08) + 0.001, 0.02
            ):
                observations.append(observe(float(factor), float(best[1])))
        obs = np.asarray(observations)
        for kind in [2, 3]:
            peak = obs[:, kind].max()
            ties = obs[obs[:, kind] >= peak - 1e-07]
            top = ties[np.argmin(abs(ties[:, 1] - 1))]
            close = obs[obs[:, kind] >= peak - 0.02]
            near = obs[abs(obs[:, 0] - top[0]) > 0.06, kind]
            margin = float(peak - near.max()) if len(near) else 0.0
            weight = np.exp((obs[:, kind] - peak) / 0.03)
            mean = float(np.average(obs[:, 0], weights=weight))
            std = float(np.sqrt(np.average((obs[:, 0] - mean) ** 2, weights=weight)))
            values.extend(
                [
                    top[0],
                    mean,
                    top[1],
                    peak,
                    margin,
                    std,
                    close[:, 0].min(),
                    close[:, 0].max(),
                    top[4],
                    top[5],
                    len(bitmaps) / 4,
                    float(top[0] < 0.52 or top[0] > 1.55),
                ]
            )
    return np.asarray(values, float)
