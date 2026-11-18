"""Pure measured-source features for the accepted early inference graph."""

import numpy as np

def prepare_all(before, native, groups):
    """Current prediction cohorts and physical anchors, in research tie order.

    The research round64 pooled feature matrix was never consumed by any
    accepted early stage; avoid constructing it during production inference.
    """
    records, anchors, old, pages = [], [], [], []
    prior = np.exp(native[:, 0])
    for group in sorted(set(groups)):
        ix = np.flatnonzero(groups == group)
        start = len(records)
        for value in sorted(set(before[ix])):
            ids = ix[before[ix] == value]
            records.append(ids)
            anchors.append(float(np.median(prior[ids])))
            old.append(value)
        pages.append(np.arange(start, len(records)))
    return dict(records=records, anchors=np.asarray(anchors), old=np.asarray(old), pages=pages)


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

def source_experts(native, evidence, masked):
    prior = np.exp(native[:, 0])
    F = evidence[:, :146]
    T = evidence[:, 146:164]
    E = evidence[:, 164:228].reshape(-1, 4, 16)
    B = evidence[:, 233:289]
    candidates = [prior]
    qualities = [np.ones(len(prior))]
    for font in range(4):
        for factor, score in [(1, 3), (12, 13)]:
            candidates.append(prior * E[:, font, factor])
            qualities.append(np.maximum(0, E[:, font, score]))
    for channel in range(5):
        start = 15 + 33 * channel
        vertical = native[:, 2] >= native[:, 1]
        offset = np.where(vertical, 4, 0)
        for peak in range(2):
            index = start + 25 + offset + peak * 2
            candidates.append(prior * masked[np.arange(len(prior)), index])
            qualities.append(np.maximum(0, masked[np.arange(len(prior)), index + 1]))
    for channel in range(4):
        for font in [0, 2]:
            for dim, expected in [(2, 5), (6, 2)]:
                denominator = F[:, font * 36 + expected]
                candidates.append(np.divide(B[:, channel * 14 + dim], denominator, out=np.zeros(len(prior)), where=denominator > 0.05))
                qualities.append((B[:, channel * 14 + 13] > 0).astype(float))
    candidates.extend([prior * T[:, 13], prior * np.maximum(T[:, 11], T[:, 12])])
    qualities.extend([np.ones(len(prior)), np.ones(len(prior))])
    values = np.asarray(candidates).T
    weights = np.asarray(qualities).T
    valid = (values > prior[:, None] * 0.1) & (values < prior[:, None] * 4) & (weights > 0.08)
    return (values, weights, valid)

def group_experts(native, evidence, masked, point, ids, values, weights, valid):
    prior = np.exp(native[ids, 0])
    anchor = float(np.median(prior))
    v = values[ids]
    w = weights[ids]
    ok = valid[ids]
    features = [np.log(anchor), np.log(len(ids)), np.log1p(np.expm1(evidence[ids, 146]).sum())]
    features.extend(np.quantile(np.log(point[ids] / anchor), [0.1, 0.5, 0.9]))
    features.extend(np.quantile(np.log(prior / anchor), [0.1, 0.5, 0.9]))
    for j in range(values.shape[1]):
        x = v[ok[:, j], j] / anchor
        q = w[ok[:, j], j]
        features.extend(np.quantile(x, [0.2, 0.5, 0.8]) if len(x) else [0.0, 0.0, 0.0])
        features.extend([len(x) / len(ids), float(q.mean()) if len(x) else 0.0])
    features.extend(np.quantile(masked[ids, :15], [0.2, 0.5, 0.8], axis=0).ravel())
    features.extend(np.quantile(evidence[ids, 146:164], [0.2, 0.5, 0.8], axis=0).ravel())
    return (anchor, np.asarray(features, float))

def signature(ids, native, evidence, masked, cadence, colors, point, prior, experts, quality, valid):
    p = prior[ids]
    v = experts[ids]
    q = quality[ids]
    ok = valid[ids]
    dim = []
    app = []
    for j in range(v.shape[1]):
        values = v[ok[:, j], j]
        weights = q[ok[:, j], j]
        dim.extend(np.quantile(values, [0.2, 0.5, 0.8]) if len(values) else [0.0, 0.0, 0.0])
        app.extend([float(ok[:, j].mean()), float(weights.mean()) if len(weights) else 0.0])
    dim.extend(np.quantile(p, [0.2, 0.5, 0.8]))
    dim.extend(np.quantile(point[ids], [0.2, 0.5, 0.8]))
    cdim = []
    capp = []
    for channel in range(4):
        start = 32 * channel
        cdim.extend(start + np.r_[np.arange(4, 16), np.arange(20, 23), [23, 24, 26, 27, 29, 30]])
        capp.extend(start + np.r_[np.arange(4), np.arange(16, 20), [25, 28, 31]])
    dim.extend(np.quantile(colors[ids][:, cdim] * p[:, None], [0.2, 0.5, 0.8], axis=0).ravel())
    app.extend(np.quantile(colors[ids][:, capp], [0.2, 0.5, 0.8], axis=0).ravel())
    physical = []
    other = [0, 1]
    for channel in range(5):
        start = 2 + 24 * channel
        physical.extend(start + np.r_[np.arange(3, 12), np.arange(15, 18)])
        other.extend(start + np.r_[0, np.arange(12, 15), np.arange(18, 24)])
    dim.extend(np.quantile(cadence[ids][:, physical] * p[:, None], [0.2, 0.5, 0.8], axis=0).ravel())
    app.extend(np.quantile(cadence[ids][:, other], [0.2, 0.5, 0.8], axis=0).ravel())
    body = np.r_[tuple((np.arange(233 + 14 * j, 245 + 14 * j) for j in range(4)))].ravel().astype(int)
    dim.extend(np.quantile(evidence[ids][:, body], [0.2, 0.5, 0.8], axis=0).ravel())
    expected = np.concatenate([np.arange(36 * j, 36 * j + 18) for j in range(4)])
    app.extend(np.mean(evidence[ids][:, expected], axis=0))
    app.extend(np.mean(evidence[ids, 146:164], axis=0))
    app.extend(evidence[ids, 230:233].mean(axis=0))
    app.extend(np.mean(native[ids, 1:], axis=0))
    app.extend(np.quantile(masked[ids, :15], [0.2, 0.5, 0.8], axis=0).ravel())
    app.append(np.log1p(len(ids)))
    dim = np.asarray(dim)
    app = np.asarray(app)
    assert np.isfinite(dim).all() and np.isfinite(app).all()
    return (dim, np.r_[app, (dim > 0).astype(float)])

def candidate_features(dim, appearance, candidates):
    dim = np.asarray(dim)
    candidates = np.asarray(candidates)
    ratio = np.divide(dim[None, :], candidates[:, None], out=np.ones((len(candidates), len(dim))), where=dim[None, :] > 0)
    return np.c_[np.log(np.maximum(1e-06, ratio)), np.broadcast_to(appearance, (len(candidates), len(appearance)))].astype(np.float32)
