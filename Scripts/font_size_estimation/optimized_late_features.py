"""Pure source feature pooling for the frozen late font graph."""

import numpy as np


def group_features(native, evidence, point, ids, page_size=None):
    n = np.asarray(native, float)[ids]
    e = np.asarray(evidence, float)[ids].copy()
    p = np.exp(n[:, 0])
    anchor = float(np.median(p))
    values = np.asarray(point)[ids]
    e[:, 233:245] /= anchor
    e[:, 247:259] /= anchor
    e[:, 261:273] /= anchor
    e[:, 275:287] /= anchor
    z = np.c_[n, e[:, :289]]
    z = np.sign(z) * np.log1p(abs(z))
    pooled = np.r_[np.quantile(z, [0.2, 0.5, 0.8], axis=0).ravel(), z.mean(axis=0), z.std(axis=0)]
    t = e[:, 146:164]
    count = np.maximum(1, np.expm1(t[:, 0]))
    weights = np.clip(count * (1 - t[:, 6]) * (0.25 + 0.75 * t[:, 16]), 0.1, 30)
    s = np.argsort(values)
    weighted = float(values[s][np.searchsorted(np.cumsum(weights[s]), weights.sum() / 2)])
    summary = np.r_[
        np.log(anchor),
        np.log(len(ids)),
        np.log1p(count.sum()),
        np.quantile(np.log(p / anchor), [0, 0.25, 0.5, 0.75, 1]),
        np.quantile(np.log(values / anchor), [0, 0.25, 0.5, 0.75, 1]),
        np.log(weighted / anchor),
        np.log(np.mean(values) / anchor),
        np.std(np.log(values)),
        np.log1p(page_size) if page_size is not None else np.zeros(2),
    ]
    return anchor, np.r_[summary, pooled]


def prepare_all(before, source_points, rows, groups, native, evidence, use_page_size=False):
    records = []
    features = []
    anchors = []
    old = []
    pages = []
    for group in sorted(set(groups)):
        ix = np.flatnonzero(groups == group)
        start = len(records)
        for value in sorted(set(before[ix])):
            ids = ix[before[ix] == value]
            a, f = group_features(
                native,
                evidence,
                source_points,
                ids,
                rows[ids[0]]['pageSize'] if use_page_size else None,
            )
            records.append(ids)
            anchors.append(a)
            features.append(f)
            old.append(value)
        pages.append(np.arange(start, len(records)))
    return dict(
        records=records,
        features=np.asarray(features),
        anchors=np.asarray(anchors),
        old=np.asarray(old),
        pages=pages,
    )


def apply_prepared(before, prepared, proposed, weight, clip, quantum):
    old = prepared['old']
    values = old * np.exp(np.clip(weight * np.log(proposed / old), -clip, clip))
    values = np.maximum(quantum, np.round(values / quantum) * quantum)
    for ids in prepared['pages']:
        if len(set(values[ids])) != len(ids):
            values[ids] = old[ids]
    out = before.copy()
    for ids, value in zip(prepared['records'], values):
        out[ids] = value
    return out


def fill_signature(ids, prior, templates, geometry, paint, point):
    p = prior[ids]
    t = templates[ids, :128].reshape(-1, 8, 16)
    dim = []
    other = []
    for j in range(8):
        factors = t[:, j, [0, 1, 2, 12]]
        quality = t[:, j, [3, 4, 5, 13]]
        dim.extend(np.quantile(factors * p[:, None], [0.2, 0.5, 0.8], axis=0).ravel())
        other.extend(np.quantile(quality, [0.2, 0.5, 0.8], axis=0).ravel())
        other.extend(
            np.quantile(t[:, j, [6, 7, 8, 9, 10, 11, 14, 15]], [0.2, 0.5, 0.8], axis=0).ravel()
        )
    dim.extend(np.quantile(geometry['physical'][ids], [0.2, 0.5, 0.8], axis=0).ravel())
    dim.extend(np.quantile(np.exp(paint[ids, :32]) * p[:, None], [0.2, 0.5, 0.8], axis=0).ravel())
    dim.extend(np.quantile(point[ids], [0.2, 0.5, 0.8]))
    dim.extend(np.quantile(p, [0.2, 0.5, 0.8]))
    other.extend(np.quantile(geometry['X'][ids], [0.2, 0.5, 0.8], axis=0).ravel())
    other.extend(np.quantile(paint[ids, 32:], [0.2, 0.5, 0.8], axis=0).ravel())
    other.extend([np.log1p(len(ids))])
    return np.asarray(dim), np.asarray(other)


def compact(ids, prior, templates, geometry, paint, point):
    p = prior[ids]
    t = templates[ids, :128].reshape(-1, 8, 16)
    dim = []
    other = []
    for j in range(8):
        v = p * t[:, j, 12]
        q = np.maximum(0, t[:, j, 13])
        s = np.argsort(v)
        w = q**4 + 0.0001
        median = v[s][np.searchsorted(np.cumsum(w[s]), w.sum() / 2)]
        dim.extend([median, np.average(v, weights=w)])
        other.extend([np.mean(q), np.median(q), np.std(v) / max(1, median)])
    dim.extend(np.median(geometry['physical'][ids], axis=0)[[0, 3, 6, 7, 8, 9, 11, 12]])
    dim.extend(np.median(np.exp(paint[ids, :32]) * p[:, None], axis=0)[::4])
    dim.extend(np.quantile(point[ids], [0.2, 0.5, 0.8]))
    dim.extend(np.quantile(p, [0.2, 0.5, 0.8]))
    other.extend(np.median(geometry['X'][ids], axis=0)[14:])
    other.extend(np.median(paint[ids, 32:], axis=0))
    other.extend([np.log1p(len(ids))])
    return np.asarray(dim), np.asarray(other)


def append_joint_signature(ids, prior, joint, dim, appearance):
    z = joint[ids].reshape(-1, 4, 12)
    physical = z[:, :, [0, 1, 5, 6, 7]] * prior[ids, None, None]
    quality = z[:, :, [2, 3, 4, 8, 9, 10, 11]]
    return (
        np.r_[dim, np.quantile(physical, [0.2, 0.5, 0.8], axis=0).ravel()],
        np.r_[appearance, np.quantile(quality, [0.2, 0.5, 0.8], axis=0).ravel()],
    )


def candidate_features(dim, appearance, candidates):
    dim = np.asarray(dim)
    candidates = np.asarray(candidates)
    ratio = np.divide(
        dim[None, :],
        candidates[:, None],
        out=np.ones((len(candidates), len(dim))),
        where=dim[None, :] > 0,
    )
    return np.c_[
        np.log(np.maximum(1e-6, ratio)),
        np.broadcast_to(appearance, (len(candidates), len(appearance))),
    ].astype(np.float32)


def weighted_median(v, w):
    order = np.argsort(v)
    return float(v[order][np.searchsorted(np.cumsum(w[order]), w.sum() / 2)])


def group_physics(ids, prior, templates, areas, paint):
    t = templates[ids, :64].reshape(-1, 4, 16)
    p = prior[ids]
    estimates = []
    confidence = []
    area_estimates = []
    area_confidence = []
    for font in range(4):
        q = np.maximum(0, t[:, font, 13])
        v = t[:, font, 12] * p
        ok = (v > 0) & (q > 0.1)
        estimates.append(weighted_median(v[ok], q[ok] ** 4) if ok.any() else 0.0)
        confidence.append(float(np.mean(q[ok])) if ok.any() else 0.0)
        v = areas[ids, 4 * font] * p
        q = (
            areas[ids, 16 + font]
            * np.clip(paint[ids, 38] * 5, 0, 1)
            * np.clip(paint[ids, 36], 0, 1)
        )
        ok = (v > 0) & (q > 0.1)
        area_estimates.append(weighted_median(v[ok], q[ok] ** 2) if ok.any() else 0.0)
        area_confidence.append(float(np.mean(q[ok])) if ok.any() else 0.0)
    return (
        np.array(estimates),
        np.array(confidence),
        np.array(area_estimates),
        np.array(area_confidence),
    )


def optical_features(shape, shape_q, area, area_q, geometry, ids, page_size):
    valid = (shape > 0) & (area > 0)
    ratio = np.divide(area, shape, out=np.ones_like(area), where=valid)
    logratio = np.log(np.clip(ratio, 0.05, 20))
    positive = shape[shape > 0]
    anchor = float(np.median(positive)) if len(positive) else 1.0
    g = np.median(geometry[ids], axis=0)
    width, height = page_size
    common = np.r_[logratio, shape_q, area_q, g[14:], np.log1p(len(ids)), np.log(width / height)]
    features = []
    for j in range(len(shape)):
        # Inverse measured pixel-em models finite-raster optical bias, not a GT size
        # catalogue. Relative frame units retain independent resolution evidence.
        s = max(1.0, float(shape[j]))
        features.append(
            np.r_[
                common,
                logratio[j],
                shape_q[j],
                area_q[j],
                np.log(s / anchor),
                1 / s,
                1 / s**2,
                np.log(s / width),
                np.log(s / height),
            ]
        )
    return np.asarray(features, float)


def wm(v, w):
    order = np.argsort(v)
    return v[order][np.searchsorted(np.cumsum(w[order]), w.sum() / 2)]


def append_advance(base, ids, prior, cadence, technical, shape):
    c = cadence[ids]
    p = prior[ids]
    t = technical[ids]
    count = np.maximum(1, np.expm1(t[:, 0]))
    dim = []
    confidence = []
    for channel in range(5):
        start = 2 + 24 * channel
        for offset, qoffset in [(1, None), (2, None), (4, None), (10, 13), (16, 19)]:
            v = c[:, start + offset] * p
            w = (
                np.clip(count, 1, 50) * np.maximum(0.01, c[:, start + 21])
                if qoffset is None
                else np.maximum(0, c[:, start + qoffset])
            )
            valid = (v > 0) & (w > 0.01)
            if valid.any():
                dim.append(float(wm(v[valid], w[valid])))
                confidence.extend([float(valid.mean()), float(np.mean(w[valid]))])
            else:
                dim.append(0.0)
                confidence.extend([0.0, 0.0])
    for offset in [11, 12, 13]:
        dim.append(float(np.median(t[:, offset] * p)))
    dim = np.array(dim)
    extra = np.r_[confidence, np.median(t, axis=0), np.median(c[:, :2], axis=0)]
    result = []
    for j in range(len(shape)):
        ratio = np.divide(dim, max(1, shape[j]), out=np.ones_like(dim), where=dim > 0)
        result.append(
            np.r_[base[j], np.log(np.maximum(0.01, ratio)), (dim > 0).astype(float), extra]
        )
    return np.asarray(result)


def stack_features(points, physics, optical, anchor):
    valid = (points > 0) & (physics[:, 1, :] > 0.3)
    safe = np.where(valid, points, anchor[:, None])
    relative = np.log(np.maximum(0.01, safe / anchor[:, None]))
    source_shape = np.divide(physics[:, 0, :], anchor[:, None])
    source_area = np.divide(physics[:, 2, :], anchor[:, None])
    context = np.median(optical, axis=1)
    feature = np.c_[
        relative,
        valid,
        source_shape,
        source_area,
        physics[:, 1, :],
        physics[:, 3, :],
        relative.std(axis=1),
        np.ptp(relative, axis=1),
        context,
    ]
    spread = []
    for p, ok in zip(relative, valid):
        spread.append(float(np.std(p[ok])) if ok.sum() >= 2 else 10.0)
    assert np.isfinite(feature).all()
    return feature.astype(np.float32), np.asarray(spread), physics[:, 1, :].max(axis=1)
