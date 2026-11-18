"""Predicted source fill alpha; no source labels or identifiers."""

import numpy as np
import cv2


def predicted_fill_alpha(rgb, bbox, ownership, style):
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
        return np.zeros(own.shape, dtype=np.float32)
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
    return alpha.astype(np.float32)
