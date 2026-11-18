"""Owned text-column pitch and OCR-count witnesses in source pixel units."""

import cv2, numpy as np


def runs(active):
    padded = np.r_[False, active, False].astype(int)
    return list(
        zip(np.flatnonzero(np.diff(padded) == 1), np.flatnonzero(np.diff(padded) == -1))
    )


def cadence_features(rgb, bbox, prior, ownership, character_count):
    x, y, w, h = bbox
    left = max(0, int(x))
    top = max(0, int(y))
    right = min(rgb.shape[1], int(np.ceil(x + w)))
    bottom = min(rgb.shape[0], int(np.ceil(y + h)))
    rgb = rgb[top:bottom, left:right]
    own = ownership[top:bottom, left:right] > 0
    vertical = h >= w
    if not vertical:
        rgb = np.transpose(rgb, (1, 0, 2))
        own = own.T
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
    lo = rgb.min(axis=2)
    hi = rgb.max(axis=2)
    chroma = hi.astype(float) - lo
    masks = [
        own,
        own & (hi < 100),
        own & (hi < 180),
        own & (chroma > 65),
        own & (lo > 180) & (chroma < 45),
    ]
    features = [float(vertical), np.log1p(character_count)]
    for mask in masks:
        cross = mask.mean(axis=0).astype(float)
        cross = cv2.GaussianBlur(
            cross.reshape(1, -1), (0, 0), max(0.5, unit * 0.04)
        ).ravel()
        active = cross > max(0.01, float(cross.max()) * 0.07)
        active = (
            cv2.morphologyEx(
                active.astype(np.uint8).reshape(1, -1),
                cv2.MORPH_CLOSE,
                np.ones((1, max(1, int(unit * 0.08))), np.uint8),
            ).ravel()
            > 0
        )
        columns = [(a, b) for a, b in runs(active) if b - a >= unit * 0.18]
        widths = []
        spans = []
        periods = []
        strengths = []
        allpeaks = []
        peakstrength = []
        density = []
        for a, b in columns:
            core = mask[:, a:b]
            long = core.mean(axis=1).astype(float)
            occupied = np.flatnonzero(long > 0.02)
            if len(occupied) < 2:
                continue
            widths.append((b - a) / unit)
            spans.append((occupied[-1] - occupied[0] + 1) / unit)
            density.append(float(core.mean()))
            signal = long - long.mean()
            corr = np.correlate(signal, signal, "full")[len(signal) - 1 :]
            if corr[0] < 1e-08:
                continue
            corr = corr / corr[0]
            low = max(2, int(unit * 0.55))
            high = min(len(corr) - 2, int(unit * 1.7))
            peaks = [
                j
                for j in range(low, high + 1)
                if corr[j] > 0 and corr[j] >= corr[j - 1] and (corr[j] > corr[j + 1])
            ]
            candidates = []
            for j in peaks:
                score = float(corr[j])
                denom = 1.0
                for multiple, weight in [(2, 0.5), (3, 0.25)]:
                    if j * multiple < len(corr):
                        score += weight * float(corr[j * multiple])
                        denom += weight
                candidates.append((score / denom, j))
            for score, j in sorted(candidates, reverse=True)[:3]:
                allpeaks.append(j / unit)
                peakstrength.append(score)
            near = [(s, j) for s, j in candidates if 0.7 <= j / unit <= 1.35]
            if near:
                score, j = max(near)
                periods.append(j / unit)
                strengths.append(score)
        features.extend(
            [
                float(len(columns)),
                sum(spans) / max(1, character_count),
                sum(spans) / max(1, character_count)
                + 0.1 * len(spans) / max(1, character_count),
            ]
        )
        for values in [
            widths,
            spans,
            periods,
            strengths,
            allpeaks,
            peakstrength,
            density,
        ]:
            features.extend(
                np.quantile(values, [0.1, 0.5, 0.9]) if len(values) else [0.0, 0.0, 0.0]
            )
    return np.asarray(features, float)
