"""Individual glyph-component reference descriptors; no page/word recognition."""

import cv2, numpy as np, hashlib


def descriptor(patch, prior, color):
    h, w = patch.shape
    scale = 32 / max(h, w)
    small = cv2.resize(
        patch.astype(np.float32),
        (max(1, round(w * scale)), max(1, round(h * scale))),
        interpolation=cv2.INTER_AREA,
    )
    canvas = np.zeros((32, 32), np.float32)
    y = (32 - small.shape[0]) // 2
    x = (32 - small.shape[1]) // 2
    canvas[y : y + small.shape[0], x : x + small.shape[1]] = small
    dct = cv2.dct(canvas)[:8, :8].ravel()
    dct /= max(1e-08, np.linalg.norm(dct))
    gx = cv2.Sobel(canvas, cv2.CV_32F, 1, 0)
    gy = cv2.Sobel(canvas, cv2.CV_32F, 0, 1)
    mag, angle = cv2.cartToPolar(gx, gy)
    bins = (angle * 8 / (2 * np.pi)).astype(int) % 8
    hog = []
    for top in range(0, 32, 8):
        for left in range(0, 32, 8):
            hog.extend(
                np.bincount(
                    bins[top : top + 8, left : left + 8].ravel(),
                    weights=mag[top : top + 8, left : left + 8].ravel(),
                    minlength=8,
                )
            )
    hog = np.sqrt(np.asarray(hog))
    hog /= max(1e-08, np.linalg.norm(hog))
    size = np.sqrt(w * h)
    v = np.r_[
        0.6 * dct,
        0.8 * hog,
        0.15 * np.clip(np.log(w / h), -2, 2),
        0.25 * np.clip(np.log(size / prior), -2, 2),
        np.asarray(color) / 255 * 0.1,
        0.2 * patch.mean(),
    ]
    v /= max(1e-08, np.linalg.norm(v))
    return (v.astype(np.float32), float(size))


def extract(rgb, bbox, prior, ownership):
    x, y, w, h = bbox
    left = max(0, int(x))
    top = max(0, int(y))
    right = min(rgb.shape[1], int(np.ceil(x + w)))
    bottom = min(rgb.shape[0], int(np.ceil(y + h)))
    rgb = rgb[top:bottom, left:right]
    own = ownership[top:bottom, left:right] > 0
    lo = rgb.min(axis=2)
    hi = rgb.max(axis=2)
    chroma = hi.astype(float) - lo
    cores = [own & (hi < 120), own & (chroma > 65), own & (lo > 190) & (chroma < 45)]
    result = []
    seen = set()
    for core in cores:
        n, labels, stats, _ = cv2.connectedComponentsWithStats(core.astype(np.uint8), 8)
        for label, (sx, sy, sw, sh, area) in enumerate(stats[1:], 1):
            if (
                min(sw, sh) < max(7, 0.3 * prior)
                or max(sw, sh) > 1.4 * prior
                or area < 25
                or (area / (sw * sh) > 0.88)
            ):
                continue
            patch = labels[sy : sy + sh, sx : sx + sw] == label
            contours, _ = cv2.findContours(
                patch.astype(np.uint8), cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE
            )
            if not contours or sum((len(c) for c in contours)) < 14:
                continue
            key = hashlib.sha256(
                np.asarray([sw, sh], np.int32).tobytes() + np.packbits(patch).tobytes()
            ).hexdigest()
            if key in seen:
                continue
            seen.add(key)
            color = np.median(rgb[sy : sy + sh, sx : sx + sw][patch], axis=0)
            v, size = descriptor(patch, prior, color)
            result.append(
                (v, size, key, [left + int(sx), top + int(sy), int(sw), int(sh)])
            )
    return result
