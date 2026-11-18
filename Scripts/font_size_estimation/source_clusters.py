"""Page-local scale communities from source glyph evidence, never GT cohorts.

Pair affinity is aggregated over communities; one weak individual pair cannot
split a coherent community. Existing erroneous memberships can be corrected.
"""
import numpy as np


EVIDENCE_COUNT = 291
ROLES = ('dialogue', 'narration', 'story_text')


def measure_cluster_evidence(bundle, rgb, bbox, prior, source_text, ownership,
                             native, confidence=None, role=None, center=None, template=None):
    """Measure bound original OCR/mask evidence in the authorized crop only."""
    if (not bundle.get('sourceClustering') or not source_text or ownership is None
            or role not in ROLES or center is None or confidence is None):
        return np.zeros(EVIDENCE_COUNT)
    from source_evidence import verified_fonts, measure_evidence
    paths = verified_fonts(tuple((r['path'], r['SHA256']) for r in bundle['physicalReferenceFonts']))
    if paths is None:
        return np.zeros(EVIDENCE_COUNT)
    from glyph_body_features import glyph_body_features
    from font_metric_features import font_metric_features
    from technical_ocr_metrics import technical_metrics
    if template is None:
        template = measure_evidence(bundle, rgb, bbox, prior, source_text, ownership)
    if template is None:
        return np.zeros(EVIDENCE_COUNT)
    return np.r_[font_metric_features(source_text, native, paths),
                 technical_metrics(source_text, confidence, bbox[2:], prior), template,
                 [float(role == value) for value in ROLES],
                 glyph_body_features(rgb, bbox, prior, ownership), center]


def pair_features(native, evidence, left, right):
    native = np.asarray(native, float)
    evidence = np.asarray(evidence, float)
    if native.ndim != 2 or native.shape[1] != 156 or evidence.shape != (len(native), EVIDENCE_COUNT):
        raise ValueError('Invalid source cluster feature dimensions')
    if not np.isfinite(native).all() or not np.isfinite(evidence).all():
        raise ValueError('Invalid source cluster measurements')
    signals = np.c_[native[:, 1:], evidence[:, :233]]
    a, b = signals[left], signals[right]
    body = evidence[:, 233:289]
    both = (body[left] > 0) & (body[right] > 0)
    ratios = np.zeros_like(body[left])
    np.log(np.divide(body[left], body[right], out=np.ones_like(ratios), where=both), out=ratios)
    distance = np.linalg.norm(evidence[left, -2:] - evidence[right, -2:], axis=1)
    return np.c_[distance, abs(a - b), (a + b) / 2, abs(ratios), both.astype(float)]


def merge_glyphs(values, affinity, threshold, span, source_affinity=None, min_source_affinity=0., source_gap_slope=0.):
    """Average-link source glyphs with a complete size-span guard."""
    values = np.asarray(values, float)
    affinity = np.asarray(affinity, float)
    if (values.ndim != 1 or not np.isfinite(values).all() or (values <= 0).any()
            or affinity.shape != (len(values), len(values)) or not np.isfinite(affinity).all()
            or not 0 <= threshold <= 1 or not np.isfinite(span) or span < 1):
        raise ValueError('Invalid source cluster policy or affinity')
    source = affinity if source_affinity is None else np.asarray(source_affinity, float)
    if (source.shape != affinity.shape or not np.isfinite(source).all()
            or not 0 <= min_source_affinity <= 1 or not np.isfinite(source_gap_slope) or source_gap_slope < 0):
        raise ValueError('Invalid independent source affinity policy')
    cohorts = [[i] for i in range(len(values))]
    weights = affinity - threshold
    np.fill_diagonal(weights, 0.)
    while True:
        best = None
        for a in range(len(cohorts)):
            for b in range(a + 1, len(cohorts)):
                ids = cohorts[a] + cohorts[b]
                ratio = values[ids].max() / values[ids].min()
                if ratio > span:
                    continue
                required = min(max(.95, min_source_affinity), min_source_affinity + source_gap_slope * max(0., ratio - 1.) / .4)
                if float(source[np.ix_(cohorts[a], cohorts[b])].mean()) < required:
                    continue
                score = float(weights[np.ix_(cohorts[a], cohorts[b])].sum()) / (len(cohorts[a]) * len(cohorts[b]))
                if score > 1e-9 and (best is None or score > best[0]):
                    best = (score, a, b)
        if best is None:
            break
        _, a, b = best
        cohorts[a] += cohorts[b]
        del cohorts[b]
    result = values.copy()
    for ids in cohorts:
        canonical = round(float(np.median(values[ids])))
        result[ids] = canonical
    return result


def apply_source_clustering(bundle, values, groups, native, evidence):
    policy = bundle.get('sourceClustering')
    if not policy or native is None or evidence is None:
        return values
    values = np.asarray(values, float)
    native = np.asarray(native, float)
    groups = np.asarray(groups)
    evidence = np.asarray(evidence, float)
    # An entire existing cohort must have source support before being joined.
    # Missing OCR/mask data preserves the round37 result for that cohort.
    if evidence.shape != (len(values), EVIDENCE_COUNT) or groups.shape != values.shape:
        raise ValueError('Invalid source cluster evidence batch')
    supported = evidence[:, 230:233].sum(axis=1) == 1
    if policy.get('allowEmptyBodyWithBoundOCR', False):
        supported &= (evidence[:, 144] > 0) & (evidence[:, 161] > 0)
    else:
        supported &= evidence[:, 233:289].sum(axis=1) > 0
    out = values.copy()
    for group in sorted(set(groups)):
        ix = np.flatnonzero(groups == group)
        ix = np.array([i for i in ix if supported[ix[values[ix] == values[i]]].all()], int)
        if len(ix) < 2:
            continue
        ix = np.array(sorted(ix, key=lambda i: tuple(np.r_[values[i], native[i, 0], native[i]])))
        a, b = np.triu_indices(len(ix), 1)
        features = pair_features(native, evidence, ix[a], ix[b])
        probability = policy['model'].predict_proba(features)[:, 1]
        affinity = np.eye(len(ix))
        affinity[a, b] = probability
        affinity[b, a] = probability
        source_affinity = affinity.copy()
        weight = policy.get('numericAffinityWeight', 0.)
        if not np.isfinite(weight) or not 0 <= weight <= 1:
            raise ValueError('Invalid numeric font affinity weight')
        if weight:
            affinity = (1. - weight) * affinity + weight * np.exp(-abs(np.log(values[ix, None] / values[ix][None, :])) / .15)
        out[ix] = merge_glyphs(values[ix], affinity, policy['threshold'], policy['span'],
            source_affinity=source_affinity, min_source_affinity=policy.get('minSourceAffinity', 0.),
            source_gap_slope=policy.get('sourceGapSlope', 0.))
    return out
