"""Source member geometry and predicted paint cues. No labels or identifiers accepted."""

import cv2
import numpy as np


def geometry_style_features(member_polygons, style, prior):
    widths = []
    lengths = []
    aabbs = []
    tilts = []
    for polygon in member_polygons:
        p = np.asarray(polygon, np.float32)
        if p.ndim != 2 or p.shape[0] < 3:
            continue
        rect = cv2.minAreaRect(p)
        a, b = sorted(rect[1])
        if a < 0.01:
            continue
        vertices = cv2.boxPoints(rect)
        edges = np.roll(vertices, -1, axis=0) - vertices
        edge = edges[np.argmax(np.linalg.norm(edges, axis=1))]
        theta = np.arctan2(edge[1], edge[0])
        tilts.append(abs(np.sin(2 * theta)))
        widths.append(a)
        lengths.append(b)
        aabbs.append(max(0.01, min(np.ptp(p, axis=0))))
    if not widths:
        widths = [prior]
        lengths = [prior]
        aabbs = [prior]
        tilts = [0.0]
    widths = np.asarray(widths)
    lengths = np.asarray(lengths)
    aabbs = np.asarray(aabbs)
    weights = np.clip(lengths / widths, 1, 30)
    ix = np.argsort(widths)
    weighted = widths[ix][np.searchsorted(np.cumsum(weights[ix]), weights.sum() / 2)]
    outline = style.get("outline", {})
    ow = float(outline.get("widthPx") or 0)
    prob = float(outline.get("probability") or 0)
    present = float(bool(outline.get("present")))
    ow *= present
    q = np.quantile(widths, [0, 0.1, 0.25, 0.5, 0.75, 0.9, 1])
    physical = np.r_[
        q,
        weighted,
        *[max(1, weighted - k * ow) for k in [1, 2, 3]],
        *[max(1, np.median(widths) - k * ow) for k in [1, 2, 3]],
    ]
    f = np.r_[
        np.log(np.maximum(1, physical) / prior),
        np.quantile(aabbs / widths, [0, 0.25, 0.5, 0.75, 1]),
        np.quantile(lengths / widths, [0.1, 0.5, 0.9]),
        np.quantile(tilts, [0, 0.5, 1]),
        np.std(widths) / max(1, np.mean(widths)),
        np.log1p(len(widths)),
        ow / prior,
        prob,
        present,
    ]
    for key in ["fill", "outline", "background"]:
        rgb = np.asarray(style.get(key, {}).get("rgb") or [0, 0, 0]) / 255
        f = np.r_[f, rgb]
    fill = np.asarray(style.get("fill", {}).get("rgb") or [0, 0, 0])
    border = np.asarray(outline.get("rgb") or [0, 0, 0])
    background = np.asarray(style.get("background", {}).get("rgb") or [0, 0, 0])
    f = np.r_[
        f, np.linalg.norm(fill - border) / 442, np.linalg.norm(fill - background) / 442
    ]
    roles = style.get("pixelRoleEvidence", {}).get("roles", {})
    f = np.r_[
        f,
        *[
            float(roles.get(k, {}).get("meanProbability") or 0)
            for k in ["fill", "outline", "background", "shadowComposite"]
        ],
    ]
    return (np.asarray(f, float), physical)
