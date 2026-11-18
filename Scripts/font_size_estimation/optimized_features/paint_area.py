"""Rotation independent font scale from predicted paint and source OCR glyph alpha area."""

from functools import lru_cache
import unicodedata
import numpy as np
import cv2
from font_metric_features import font_resource


@lru_cache(maxsize=32768)
def glyph_area(path, char):
    font, supported = font_resource(path)
    if ord(char) not in supported:
        return 0.0
    mask = font.getmask(char, mode="L")
    return float(np.asarray(mask, dtype=float).sum() / 255 / 256**2)


def paint_area(rgb, bbox, ownership, style, text, fonts, prior):
    own = np.asarray(ownership, bool)
    fill = np.asarray(style["fill"]["rgb"], float)
    outline = style.get("outline", {})
    palette = []
    for part in ["outline", "background", "shadow"]:
        item = style.get(part, {})
        if part != "background" and (not item.get("present")):
            continue
        if item.get("rgb") is not None:
            palette.append(item["rgb"])
        if part == "background":
            palette.extend(item.get("colors", []))
    candidates = [
        np.asarray(c, float) for c in palette if np.linalg.norm(fill - c) > 35
    ]
    if not candidates:
        return np.zeros(8 * 4 + 8)
    pixels = rgb.astype(float)
    best = np.full(own.shape, 1000000000.0)
    alpha = np.zeros(own.shape)
    for other in candidates:
        delta = fill - other
        t = np.clip(((pixels - other) * delta).sum(axis=2) / np.dot(delta, delta), 0, 1)
        res = np.linalg.norm(pixels - (other + t[:, :, None] * delta), axis=2)
        selected = res < best
        alpha[selected] = t[selected]
        best[selected] = res[selected]
    good = (best < 22) & own
    binary = ((alpha > 0.5) & good).astype(np.uint8)
    count, lab, stats, _ = cv2.connectedComponentsWithStats(binary, 8)
    x, y, w, h = bbox
    inside = np.zeros(own.shape, bool)
    inside[
        max(0, int(y)) : min(own.shape[0], int(np.ceil(y + h))),
        max(0, int(x)) : min(own.shape[1], int(np.ceil(x + w))),
    ] = True
    overlaps = np.bincount(lab[inside].ravel(), minlength=count)
    allowed = (overlaps / np.maximum(1, stats[:, cv2.CC_STAT_AREA]) >= 0.3) & (
        stats[:, cv2.CC_STAT_AREA] >= 2
    )
    allowed[0] = False
    selected = allowed[lab]
    nearby = cv2.dilate(selected.astype(np.uint8), np.ones((3, 3), np.uint8)) > 0
    alpha *= good & nearby
    areas = np.array(
        [
            alpha.sum(),
            (binary & selected).sum(),
            ((alpha > 0.2) & good & nearby).sum(),
            ((alpha > 0.8) & good & nearby).sum(),
        ]
    )
    chars = [c for c in unicodedata.normalize("NFC", text or "") if not c.isspace()]
    values = []
    coverage = []
    for path in fonts:
        glyphs = np.array([glyph_area(path, c) for c in chars])
        total = glyphs.sum()
        coverage.append(float((glyphs > 0).sum()) / max(1, len(chars)))
        values.extend(
            np.sqrt(areas / max(1e-08, total)) / prior if total > 0 else np.zeros(4)
        )
    details = np.r_[
        np.log1p(len(chars)),
        np.mean(coverage),
        min(coverage),
        own.mean(),
        np.mean(best[own] < 22) if own.any() else 0,
        np.mean(alpha[own]) if own.any() else 0,
        np.linalg.norm(fill - np.asarray(style["background"]["rgb"])) / 442,
        areas[1] / max(1, areas[0]),
    ]
    return np.r_[np.log(np.maximum(1e-05, values)), details]
