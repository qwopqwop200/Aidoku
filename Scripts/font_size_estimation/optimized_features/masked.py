"""Mask-bound technical glyph style/pitch summaries; no glyph bitmap learner."""

import cv2, numpy as np


def masked_features(rgb, bbox, prior, owned):
    x, y, w, h = bbox
    x0 = max(0, int(x))
    y0 = max(0, int(y))
    x1 = min(rgb.shape[1], int(np.ceil(x + w)))
    y1 = min(rgb.shape[0], int(np.ceil(y + h)))
    rgb = rgb[y0:y1, x0:x1]
    owned = owned[y0:y1, x0:x1] > 0
    scale = min(1.0, 640 / max(rgb.shape[:2]))
    unit = prior * scale
    if scale < 1:
        rgb = cv2.resize(rgb, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
        owned = (
            cv2.resize(
                owned.astype(np.uint8),
                (rgb.shape[1], rgb.shape[0]),
                interpolation=cv2.INTER_NEAREST,
            )
            > 0
        )
    lo = rgb.min(axis=2)
    hi = rgb.max(axis=2)
    chroma = hi.astype(float) - lo
    gray = cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY)
    bg = (
        np.median(rgb[~owned], axis=0)
        if (~owned).any()
        else np.median(rgb.reshape(-1, 3), axis=0)
    )
    ink = rgb[owned]
    f = []
    f.extend(
        np.quantile(ink, [0.1, 0.5, 0.9], axis=0).ravel() / 255
        if len(ink)
        else np.zeros(9)
    )
    f.extend(bg / 255)
    f.extend(
        [
            owned.mean(),
            np.mean(chroma[owned]) / 255 if owned.any() else 0.0,
            np.std(gray[owned]) / 255 if owned.any() else 0.0,
        ]
    )
    distance = np.linalg.norm(rgb.astype(float) - bg, axis=2)
    masks = [
        owned & (hi < 100),
        owned & (hi < 180),
        owned & (lo > 180) & (chroma < 45),
        owned & (chroma > 70),
        owned & (distance > 50),
    ]
    for mask in masks:
        binary = mask.astype(np.uint8)
        count, labels, stats, centers = cv2.connectedComponentsWithStats(binary, 8)
        s = stats[1:]
        valid = (s[:, 4] >= max(3, unit**2 * 0.003)) & (s[:, 4] < binary.size * 0.75)
        s = s[valid]
        centers = centers[1:][valid]
        if len(s):
            f.extend(
                np.quantile(
                    np.c_[
                        s[:, 2] / unit,
                        s[:, 3] / unit,
                        np.sqrt(s[:, 4]) / unit,
                        s[:, 4] / (s[:, 2] * s[:, 3]),
                    ],
                    [0.25, 0.5, 0.75],
                    axis=0,
                ).ravel()
            )
            f.append(min(10.0, len(s) / max(1.0, mask.size / unit**2)))
        else:
            f.extend([0.0] * 13)
        depth = cv2.distanceTransform(binary, cv2.DIST_L2, 3)
        values = depth[depth > 0]
        f.extend(
            np.quantile(values, [0.25, 0.5, 0.9]) / unit if len(values) else [0.0] * 3
        )
        contours, _ = cv2.findContours(
            binary, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        rects = []
        for contour in contours:
            area = cv2.contourArea(contour)
            if area < max(3, unit**2 * 0.003) or area >= mask.size * 0.75:
                continue
            _, sides, angle = cv2.minAreaRect(contour)
            small, big = sorted(sides)
            if small > 1:
                rects.append((small / unit, big / unit, area / (small * big)))
        f.extend(
            np.quantile(rects, [0.25, 0.5, 0.75], axis=0).ravel()
            if rects
            else [0.0] * 9
        )
        for axis in [0, 1]:
            sig = binary.mean(axis=axis).astype(float)
            sig -= sig.mean()
            corr = np.correlate(sig, sig, "full")[len(sig) - 1 :]
            low = max(2, int(0.3 * unit))
            high = min(len(corr) - 2, int(1.8 * unit))
            peaks = []
            if corr[0] > 1e-08:
                peaks = sorted(
                    [
                        i
                        for i in range(low, high + 1)
                        if corr[i] >= corr[i - 1]
                        and corr[i] > corr[i + 1]
                        and (corr[i] > 0)
                    ],
                    key=lambda i: -corr[i],
                )[:2]
            for k in range(2):
                f.extend(
                    [peaks[k] / unit, corr[peaks[k]] / corr[0]]
                    if k < len(peaks)
                    else [0.0, 0.0]
                )
    return np.asarray(f, float)
