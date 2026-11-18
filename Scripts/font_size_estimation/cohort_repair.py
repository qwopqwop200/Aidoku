"""Repair split size cohorts using independent source glyph measurements.

Inputs are estimated sizes, source-font families/scales/quality and source pair
probabilities. No GT, page identifiers, image files or experiment imports.
Whole cohorts remain intact. An uncertain numerical size can be overridden only
when source family, physical scale and pair evidence jointly agree.
"""
import numpy as np


def _median(values, weights):
    order = np.argsort(values, kind='stable')
    return float(values[order][np.searchsorted(np.cumsum(weights[order]), weights.sum() / 2)])


def repair_cohorts(values, affinity, measured_em, family, quality, support, *,
                   minimum_affinity=.95, maximum_scale_ratio=1.25,
                   maximum_prediction_ratio=2., minimum_family_agreement=1.,
                   minimum_quality=.5, return_trace=False):
    values = np.asarray(values, float)
    affinity = np.asarray(affinity, float)
    em, family, quality, support = (np.asarray(v, float) for v in (measured_em, family, quality, support))
    if values.ndim != 1:
        raise ValueError('Estimated sizes must be a vector')
    n = len(values)
    if (values.shape != (n,) or affinity.shape != (n, n)
            or any(v.shape != (n,) for v in (em, family, quality, support))
            or any(not np.isfinite(v).all() for v in (values, affinity, em, family, quality, support))
            or (values <= 0).any() or (em < 0).any() or (support < 0).any()
            or ((family < 0) | (family > 3) | (family != np.floor(family))).any()
            or ((quality < 0) | (quality > 1)).any()
            or ((affinity < 0) | (affinity > 1)).any()
            or not np.allclose(affinity, affinity.T, rtol=0, atol=1e-12)):
        raise ValueError('Invalid source cohort evidence')
    policy = (minimum_affinity, maximum_scale_ratio, maximum_prediction_ratio,
              minimum_family_agreement, minimum_quality)
    if (not np.isfinite(policy).all() or not 0 <= minimum_affinity <= 1
            or maximum_scale_ratio < 1 or maximum_prediction_ratio < 1
            or not 0 < minimum_family_agreement <= 1 or not 0 <= minimum_quality <= 1):
        raise ValueError('Invalid cohort repair policy')
    cohorts = [np.flatnonzero(values == value).tolist() for value in sorted(set(values))]
    anchors = []
    families = []
    for ids in cohorts:
        ids = np.asarray(ids, int)
        good = ids[(em[ids] >= 2) & (quality[ids] >= minimum_quality) & (support[ids] > 0)]
        if not len(good):
            anchors.append(0.); families.append(-1)
            continue
        weights = quality[good]**4 * np.maximum(.25, support[good])
        mass = np.bincount(family[good].astype(int), weights=weights, minlength=4)
        dominant = int(mass.argmax())
        if mass[dominant] / mass.sum() + 1e-12 < minimum_family_agreement:
            anchors.append(0.); families.append(-1)
            continue
        select = family[good] == dominant
        anchors.append(_median(em[good][select], weights[select]))
        families.append(dominant)
    # Keep each original cohort's physical anchor for complete-span checks;
    # averaging after a merge must not admit an incompatible third cohort.
    physical = [[a] for a in anchors]
    trace = []
    while len(cohorts) > 1:
        choices = []
        for a in range(len(cohorts)):
            for b in range(a + 1, len(cohorts)):
                if families[a] < 0 or families[a] != families[b]:
                    continue
                scales = physical[a] + physical[b]
                scale_ratio = max(scales) / min(scales)
                if scale_ratio > maximum_scale_ratio + 1e-12:
                    continue
                ids = cohorts[a] + cohorts[b]
                prediction_ratio = values[ids].max() / values[ids].min()
                if prediction_ratio > maximum_prediction_ratio + 1e-12:
                    continue
                confidence = float(affinity[np.ix_(cohorts[a], cohorts[b])].mean())
                if confidence < minimum_affinity:
                    continue
                canonical = round(float(np.median(values[ids])))
                # Prevent incidental rounding from merging an unrelated cohort.
                if any(canonical == round(float(np.median(values[c])))
                       for k, c in enumerate(cohorts) if k not in (a, b)):
                    continue
                choices.append((confidence, -scale_ratio, -a, -b))
        if not choices:
            break
        confidence, neg_ratio, aa, bb = max(choices)
        a, b = -aa, -bb
        trace.append(dict(left=cohorts[a].copy(), right=cohorts[b].copy(),
                          sourceAffinity=confidence, physicalScaleRatio=-neg_ratio,
                          referenceFamily=families[a]))
        cohorts[a] += cohorts[b]
        physical[a] += physical[b]
        del cohorts[b], physical[b], families[b]
    result = values.copy()
    # Singletons/unmodified cohorts preserve their exact input (including
    # fractional sizes); only changed cohorts are canonicalized.
    for ids in cohorts:
        if len(set(values[ids])) > 1:
            result[ids] = round(float(np.median(values[ids])))
    return (result, trace) if return_trace else result
