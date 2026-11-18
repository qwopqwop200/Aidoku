"""Predicted-ownership dynamic color bodies, without GT color/font labels."""

import cv2, numpy as np


def color_bodies(rgb, bbox, prior, ownership):
    x, y, w, h = bbox
    left = max(0, int(x))
    top = max(0, int(y))
    right = min(rgb.shape[1], int(np.ceil(x + w)))
    bottom = min(rgb.shape[0], int(np.ceil(y + h)))
    rgb = rgb[top:bottom, left:right]
    own = ownership[top:bottom, left:right] > 0
    if own.sum() < 8:
        return np.zeros(128)
    scale = min(1.0, 1200 / max(rgb.shape[:2]))
    unit = prior * scale
    if scale < 1:
        rgb = cv2.resize(rgb, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        own = (
            cv2.resize(
                own.astype(np.uint8),
                (rgb.shape[1], rgb.shape[0]),
                interpolation=cv2.INTER_NEAREST,
            )
            > 0
        )
    lab = cv2.cvtColor(rgb, cv2.COLOR_RGB2LAB).astype(np.float32)
    pixels = lab[own]
    sample = pixels[np.linspace(0, len(pixels) - 1, min(4096, len(pixels))).astype(int)]
    unique = np.unique(np.round(sample / 8), axis=0)
    k = min(4, len(unique))
    cv2.setRNGSeed(100)
    _, _, centers = cv2.kmeans(
        sample,
        k,
        None,
        (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 50, 0.1),
        3,
        cv2.KMEANS_PP_CENTERS,
    )
    centers = centers[np.argsort(centers[:, 0])]
    distance = ((pixels[:, None, :] - centers[None, :, :]) ** 2).sum(axis=2)
    labels = distance.argmin(axis=1)
    features = []
    for j in range(4):
        if j >= k:
            features.extend([0.0] * 32)
            continue
        core = np.zeros_like(own)
        core[own] = labels == j
        binary = core.astype(np.uint8)
        n, cc, stats, _ = cv2.connectedComponentsWithStats(binary, 8)
        s = stats[1:]
        valid = (
            (s[:, 4] >= max(3, 0.002 * unit**2))
            & (s[:, 4] < binary.size * 0.6)
            & (np.maximum(s[:, 2], s[:, 3]) < 2.5 * unit)
        )
        s = s[valid]
        f = list(centers[j] / 255) + [core.sum() / max(1, own.sum())]
        if len(s):
            v = np.c_[s[:, 2] / unit, s[:, 3] / unit, np.sqrt(s[:, 4]) / unit]
            f.extend(np.quantile(v, [0.25, 0.5, 0.75, 0.95], axis=0).ravel())
            f.extend(np.quantile(s[:, 4] / (s[:, 2] * s[:, 3]), [0.25, 0.5, 0.75]))
            f.extend([np.log1p(len(s))])
        else:
            f.extend([0.0] * 16)
        depth = cv2.distanceTransform(binary, cv2.DIST_L2, 3)
        v = depth[depth > 0]
        f.extend(np.quantile(v, [0.25, 0.5, 0.9]) / unit if len(v) else [0.0] * 3)
        contours, _ = cv2.findContours(
            binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        rects = []
        for c in contours:
            area = cv2.contourArea(c)
            if area < max(3, 0.002 * unit**2) or area >= binary.size * 0.6:
                continue
            _, sides, _ = cv2.minAreaRect(c)
            a, b = sorted(sides)
            if a > 1 and b < 2.5 * unit:
                rects.append([a / unit, b / unit, area / (a * b)])
        f.extend(
            np.quantile(rects, [0.25, 0.5, 0.75], axis=0).ravel()
            if rects
            else [0.0] * 9
        )
        assert len(f) == 32
        features.extend(f)
    out = np.asarray(features, float)
    assert out.shape == (128,) and np.isfinite(out).all()
    return out
