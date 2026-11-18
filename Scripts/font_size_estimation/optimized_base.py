"""Frozen base56 + source61 clustering, shared by operational entry points.

The graph processes source packets without GT labels or cached predictions.
The matrix decoder retains the selected study's arithmetic and tie ordering.
"""
import numpy as np
from estimator import predict_matrix
from source_clusters import pair_features


def _decode(values, affinity, source, policy):
    cohorts = [[i] for i in range(len(values))]
    counts = np.ones(len(values), float)
    low = values.copy(); high = values.copy()
    A = affinity.copy(); S = source.copy()
    while len(cohorts) > 1:
        ratio = np.maximum(high[:, None], high[None, :]) / np.minimum(low[:, None], low[None, :])
        required = np.minimum(.95, policy['minSourceAffinity'] + policy['sourceGapSlope'] * np.maximum(0, ratio-1)/.4)
        valid = np.triu((ratio <= policy['span']) & (S >= required), 1)
        score = np.where(valid, A, -np.inf)
        a, b = np.unravel_index(int(score.argmax()), score.shape)
        if score[a, b] <= policy['threshold'] + 1e-9:
            break
        merged = (A[a]*counts[a] + A[b]*counts[b])/(counts[a]+counts[b])
        source_merged = (S[a]*counts[a] + S[b]*counts[b])/(counts[a]+counts[b])
        A[a] = merged; A[:, a] = merged; S[a] = source_merged; S[:, a] = source_merged
        counts[a] += counts[b]; low[a] = min(low[a],low[b]); high[a] = max(high[a],high[b])
        cohorts[a] += cohorts[b]; del cohorts[b]
        A = np.delete(np.delete(A,b,0),b,1); S = np.delete(np.delete(S,b,0),b,1)
        counts = np.delete(counts,b); low = np.delete(low,b); high = np.delete(high,b)
    result = values.copy()
    for ids in cohorts:
        result[ids] = round(float(np.median(values[ids])))
    return result


def predict_base(base_model, pair_model, policy, native, evidence, priors, groups):
    """Return (point56, clustered61, page pair matrices) from measured inputs."""
    native = np.asarray(native,float); evidence = np.asarray(evidence,float)
    priors = np.asarray(priors,float); groups = np.asarray(groups)
    n = len(priors)
    if (native.shape != (n,156) or evidence.shape != (n,291) or groups.shape != (n,)
            or not np.isfinite(native).all() or not np.isfinite(evidence).all()
            or not np.isfinite(priors).all() or (priors<=0).any()):
        raise ValueError('Invalid optimized font source matrix')
    point = predict_matrix(dict(base_model,contextFinalRatio=1.),native,priors,groups)
    values = point.copy(); affinities = []
    for group in sorted(set(groups)):
        ids = np.flatnonzero(groups==group)
        a,b = np.triu_indices(len(ids),1)
        source = np.eye(len(ids))
        if len(a):
            feature = pair_features(native,evidence,ids[a],ids[b])
            proba = pair_model.predict_proba(feature)[:,1]
            if not np.isfinite(proba).all() or ((proba<0)|(proba>1)).any():
                raise ValueError('Invalid optimized font pair probability')
            source[a,b] = proba; source[b,a] = proba
        weight = policy['numericAffinityWeight']
        affinity = ((1-weight)*source + weight*np.exp(-abs(np.log(point[ids,None]/point[ids][None,:]))/.15)) if weight else source.copy()
        order = np.asarray(sorted(range(len(ids)),key=lambda j:tuple(np.r_[point[ids[j]],native[ids[j],0],native[ids[j]]])),int)
        if len(ids):
            values[ids[order]] = _decode(point[ids[order]],affinity[np.ix_(order,order)],source[np.ix_(order,order)],policy)
        affinities.append((ids,source))
    return point,values,affinities
