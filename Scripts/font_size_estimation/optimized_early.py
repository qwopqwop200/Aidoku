"""Accepted 61 -> 112 font inference, using only live source measurements.

The caller supplies runtime round56 points (contextFinalRatio=1), round61 fonts,
source arrays and already loaded bundle assets. No cohort or prediction assets
are consulted, and no model is fitted. ``return_stages`` returns (fonts, stages),
with roundNN stage keys. Bundle loaders are packaging helpers, never called by
``predict_early``; their root is the directory containing roundNN directories.
"""
from pathlib import Path
import json
import pickle

import numpy as np

try:
    from .optimized_early_helpers import (
        prepare_all, apply_prepared, source_experts, group_experts,
        signature, candidate_features,
    )
except ImportError:
    from optimized_early_helpers import (
        prepare_all, apply_prepared, source_experts, group_experts,
        signature, candidate_features,
    )

STAGES = (68, 71, 72, 77, 79, 83, 86, 88, 90, 92, 93, 96, 98, 102, 105, 108, 112)
MODEL_STAGES = (68, 71, 72, 79, 83, 88, 90, 92, 96, 102, 105, 108, 112)
SOURCE_SIGNALS = {
    'masked65': 'round65/features.npz:X',
    'cadence69': 'round69/features.npz:X',
    'components75': 'round75/components.npz:indices,features,sizes',
    'neighbors76': 'round76/neighbors.npz:indices,sizes,ratios,distances,support',
    'neighbors84': 'round84/neighbors.npz:indices,sizes,ratios,distances,support',
    'colors100': 'round100/features.npz:X',
    'templates103': 'round103/features.npz:X',
}
# These are model/config dependencies only. SOURCE_SIGNALS describes measurement
# provenance, not files to ship or read during production inference.
DEPENDENCY_SPEC = {
    'models': {f'round{n}': f'round{n}/model.pkl' for n in MODEL_STAGES},
    'policies': {f'round{n}': f'round{n}/REPORT.json' for n in STAGES},
    'signals': SOURCE_SIGNALS,
    'zero_native_template_branches': (83, 90, 92, 93, 96, 98, 102),
    'actual103_branches': (105, 108, 112),
}


def dependency_paths(root):
    """Explicit accepted packaging inputs; excludes prediction/cohort archives."""
    root = Path(root)
    return {kind: {key: root / rel for key, rel in DEPENDENCY_SPEC[kind].items()}
            for kind in ('models', 'policies')}


def bundle_models(root):
    """Load trusted accepted model files for packaging by the parent bundle."""
    result = {}
    for key, path in dependency_paths(root)['models'].items():
        with path.open('rb') as stream:
            result[key] = pickle.load(stream)
    return result


def bundle_policies(root):
    """Extract only selected inference settings; discard research metrics."""
    return {key: {k: v for k, v in json.loads(path.read_text())['selected'].items()
                  if k not in ('DEV', 'availableGroups')}
            for key, path in dependency_paths(root)['policies'].items()}


def _asset(mapping, stage):
    return mapping[f'round{stage}'] if f'round{stage}' in mapping else mapping[stage]


def _summary(z):
    return np.r_[np.quantile(z, [.2, .5, .8], axis=0).ravel(),
                 z.mean(axis=0), z.std(axis=0)]


def _regress(model, features, policy):
    if policy.get('aggregation', 'mean') == 'mean':
        return model.predict(features)
    return np.quantile(np.array([tree.predict(features) for tree in model.estimators_]),
                       policy['aggregation'], axis=0)


def _scaled_features(ids, kind, native, evidence, masked, cadence, point, prior,
                     page_sizes, experts):
    a, f = group_experts(native, evidence, masked, point, ids, *experts)
    width, height = page_sizes[ids[0]]
    unit = {'width': width, 'height': height, 'area': np.sqrt(width * height), 'prior': a}[kind]
    ratio = a / unit
    f[0] = np.log(ratio)
    f[3:9] += np.log(ratio)
    for j in range(experts[0].shape[1]):
        f[9 + 5*j:12 + 5*j] *= ratio
    z = cadence[ids].copy()
    for k in range(5):
        start = 2 + 24*k
        for offsets in [np.arange(1, 3), np.arange(3, 12), np.arange(15, 18)]:
            z[:, start + offsets] *= prior[ids, None] / unit
    return unit, np.r_[f, _summary(z), np.log(width / height)]


def _row_features(native, evidence, masked, cadence, components, neighbors,
                  point, prior, groups):
    """Round87 contract: ZERO native template columns, including two summaries."""
    base_evidence = evidence.copy()
    base_evidence[:, 164:230] = 0
    index = components['indices'].astype(int)
    ratios = neighbors['sizes'][:, None] * neighbors['ratios'] / prior[index, None]
    glyph = []
    for i in range(len(prior)):
        ids = np.flatnonzero(index == i)
        if not len(ids):
            glyph.append(np.zeros(622))
            continue
        z = np.c_[components['features'][ids], ratios[ids, :3], neighbors['distances'][ids, :3]]
        glyph.append(np.r_[np.quantile(z, [.2, .5, .8], axis=0).ravel(), np.log1p(len(ids)),
                           np.quantile(components['sizes'][ids] / prior[i], [.1, .5, .9]),
                           np.median(neighbors['support'][ids, :3], axis=0),
                           np.std(ratios[ids, :3], axis=0)])
    base = np.c_[native, base_evidence, masked, cadence, np.asarray(glyph), np.log(point / prior)]
    context = np.zeros((len(prior), 26))
    for group in set(groups):
        ids = np.flatnonzero(groups == group)
        v = np.c_[np.log(prior[ids]), np.log(point[ids]), native[ids, 1:3],
                  base_evidence[ids, 230:233], masked[ids, 10:11]]
        context[ids] = np.r_[np.quantile(v, [.2, .5, .8], axis=0).ravel(),
                            np.log1p(len(ids)), np.std(np.log(point[ids]))]
    return np.c_[base, context]


def _pool(probability, records, kind):
    values = []
    for ids in records:
        p = probability[ids].mean(axis=0) if kind == 'mean' else np.exp(
            np.log(np.maximum(1e-5, probability[ids])).mean(axis=0))
        values.append(p / p.sum())
    return np.asarray(values)


def _class_proposals(probability, model, prepared, policy, page_sizes):
    p = _pool(probability, prepared['records'], policy['pooling'])
    classes = model.classes_.astype(float)
    unit = np.ones(len(page_sizes)) if policy['unit'] == 'pixels' else page_sizes[:, 0] / 2048
    units = np.array([np.median(unit[ids]) for ids in prepared['records']])
    if policy['decoding'] == 'mode':
        values = classes[p.argmax(axis=1)]
    elif policy['decoding'] == 'mean':
        values = p @ classes
    else:
        cumulative = np.cumsum(p / classes[None, :], axis=1)
        cumulative /= cumulative[:, -1, None]
        values = classes[(cumulative >= .5).argmax(axis=1)]
    return np.where(p.max(axis=1) >= policy['minConfidence'], units * values, prepared['old'])


def _weighted_median(values, weights):
    keep = (values > 0) & (weights > 0)
    values, weights = values[keep], weights[keep]
    if not len(values):
        return 0.
    order = np.argsort(values)
    return values[order][np.searchsorted(np.cumsum(weights[order]), weights.sum() / 2)]


def _physical(ids, templates, prior, policy):
    q = np.maximum(0, templates[ids, :, policy['qualityColumn']])
    w = np.exp((q - q.max(axis=1, keepdims=True)) / policy['temperature']) * (q >= .4)
    values = prior[ids, None] * templates[ids, :, policy['factorColumn']]
    v = np.array([_weighted_median(a, b) for a, b in zip(values, w)])
    confidence = (q * w).sum(axis=1) / np.maximum(1e-8, w.sum(axis=1))
    value = _weighted_median(v, confidence)
    positive = v > 0
    variation = float(np.median(abs(np.log(v[positive] / value)))) if positive.any() and value > 0 else 1.
    summary = np.r_[np.quantile(q, [.2, .5, .8], axis=0).ravel(),
                    np.median(confidence), variation, np.mean(positive)]
    return value, summary


def _validate_signals(n, masked, cadence, colors, templates, components, banks):
    for name, values, width in [('masked65', masked, 180), ('cadence69', cadence, 122),
                                ('colors100', colors, 128), ('templates103', templates, 66)]:
        if values.shape != (n, width) or not np.isfinite(values).all():
            raise ValueError(f'{name} must be a finite ({n},{width}) source matrix')
    index = np.asarray(components['indices'])
    count = len(index)
    if (index.shape != (count,) or not np.isfinite(index).all()
            or np.any(index != np.floor(index)) or np.any(index < 0) or np.any(index >= n)):
        raise ValueError('components75 indices must refer to current source rows')
    for key, shape in [('features', (count, 198)), ('sizes', (count,))]:
        values = np.asarray(components[key])
        if values.shape != shape or not np.isfinite(values).all():
            raise ValueError(f'components75 {key} has invalid shape or values')
    if np.any(np.asarray(components['sizes']) <= 0):
        raise ValueError('Component sizes must be positive')
    for bank in banks:
        if not np.array_equal(bank['indices'], index):
            raise ValueError('Neighbor measurements must align with components75')
        for key, shape in [('sizes', (count,)), ('ratios', (count, 8)),
                           ('distances', (count, 8)), ('support', (count, 8))]:
            values = np.asarray(bank[key])
            if values.shape != shape or not np.isfinite(values).all() or np.any(values < 0):
                raise ValueError(f'Neighbor {key} has invalid shape or values')


def predict_early(before, point, native, evidence, priors, groups, page_sizes,
                  signals, models, policies, return_stages=False):
    """Run accepted ancestry with memberships rebuilt from current predictions.

    Arrays are aligned to runtime source rows. Components/neighbors use local row
    indices in that same ordering; each neighbors bank aligns with components75.
    Input arrays and asset mappings are never mutated. No TRAIN OOF substitution.
    """
    before = np.asarray(before, float).copy()
    point, native, evidence, priors, page_sizes = [np.asarray(a, float) for a in
                                                 (point, native, evidence, priors, page_sizes)]
    groups = np.asarray(groups)
    n = len(before)
    if native.shape != (n, 156) or evidence.shape != (n, 291) or page_sizes.shape != (n, 2):
        raise ValueError('Expected native (N,156), evidence (N,291), page_sizes (N,2)')
    if point.shape != (n,) or priors.shape != (n,) or groups.shape != (n,):
        raise ValueError('Point, priors and groups must align with current source rows')
    if any(not np.isfinite(a).all() for a in (before, point, native, evidence, priors, page_sizes)):
        raise ValueError('Early inference inputs must be finite')
    if any(np.any(a <= 0) for a in (before, point, priors, page_sizes)):
        raise ValueError('Font sizes, priors and page dimensions must be positive')
    if not n:
        return (before, {f'round{stage}': before.copy() for stage in STAGES}) if return_stages else before
    masked = np.asarray(signals['masked65'], float)
    cadence = np.asarray(signals['cadence69'], float)
    colors = np.asarray(signals['colors100'], float)
    templates = np.asarray(signals['templates103'], float)
    components = signals['components75']
    neighbors76, neighbors84 = signals['neighbors76'], signals['neighbors84']
    _validate_signals(n, masked, cadence, colors, templates, components, (neighbors76, neighbors84))
    zero = evidence.copy()
    zero[:, 164:230] = 0
    actual = evidence.copy()
    actual[:, 164:230] = templates
    experts = source_experts(native, evidence, masked)
    zero_experts = source_experts(native, zero, masked)
    actual_experts = source_experts(native, actual, masked)
    row_features = None
    probabilities = {}
    stages = {}
    for stage in STAGES:
        policy = _asset(policies, stage)
        prepared = prepare_all(before, native, groups)
        records, old = prepared['records'], prepared['old']
        model = _asset(models, stage) if stage in MODEL_STAGES else None
        weight = policy.get('strength', 1.)
        if stage in (68, 71):
            features = []
            for ids in records:
                _, f = group_experts(native, evidence, masked, point, ids, *experts)
                if stage == 71:
                    f = np.r_[f if policy['variant'] == 'all' else f[:9], _summary(cadence[ids])]
                features.append(f)
            value = _regress(model, np.asarray(features), policy)
            factor = np.exp(np.clip(value, -2, 2)) if policy.get('space', 'log') == 'log' else np.clip(value, .1, 5)
            proposed = prepared['anchors'] * factor
        elif stage in (72, 83, 88, 105):
            ce, ex = (zero, zero_experts) if stage == 83 else ((actual, actual_experts) if stage == 105 else (evidence, experts))
            pairs = [_scaled_features(ids, policy['unit'], native, ce, masked, cadence,
                                      point, priors, page_sizes, ex) for ids in records]
            value = _regress(model, np.asarray([f for _, f in pairs]), policy)
            factor = np.maximum(.0001, value) if stage == 88 else np.exp(value)
            proposed = np.asarray([a for a, _ in pairs]) * factor
        elif stage == 77:
            bank = neighbors76
            k = policy['neighbors']
            d, r, support = [bank[key][:, :k] for key in ('distances', 'ratios', 'support')]
            weights = np.exp(-d / .02) * (d <= policy['maxDistance']) * np.power(support, .25)
            order = np.argsort(r, axis=1)
            r, w = np.take_along_axis(r, order, axis=1), np.take_along_axis(weights, order, axis=1)
            valid = w.sum(axis=1) > 0
            selected = (np.cumsum(w, axis=1) >= w.sum(axis=1)[:, None] / 2).argmax(axis=1)
            estimates = bank['sizes'] * r[np.arange(len(r)), selected]
            quality = np.exp(-bank['distances'][:, 0] / .02)
            index = bank['indices']
            proposed = []
            for g, members in enumerate(records):
                ids = np.flatnonzero(np.isin(index, members) & valid)
                values = estimates[ids]
                if len(values) < 3:
                    proposed.append(old[g])
                elif policy['pooling'] == 'row-median':
                    proposed.append(np.median([np.median(estimates[ids[index[ids] == i]]) for i in sorted(set(index[ids]))]))
                elif policy['pooling'] == 'trimmed-mean':
                    proposed.append(np.exp(np.average(np.log(np.clip(values, *np.quantile(values, [.1, .9]))), weights=quality[ids])))
                else:
                    proposed.append(np.median(values))
        elif stage == 79:
            index, desc, size = (components[k] for k in ('indices', 'features', 'sizes'))
            index = index.astype(int)
            bank = neighbors76
            f = np.c_[desc, np.log(size / priors[index]), np.log(priors[index]), np.log(point[index] / priors[index]),
                      native[index, :6], evidence[index, 146:164], evidence[index, 230:233],
                      np.log(np.maximum(.1, size[:, None] * bank['ratios'][:, :3] / priors[index, None])),
                      bank['distances'][:, :3], np.log1p(bank['support'][:, :3])]
            anchor = priors[index] if policy['target'] == 'prior' else point[index]
            fonts = anchor * np.exp(np.clip(model.predict(f), -1, 1)) if len(index) else np.empty(0)
            proposed = []
            for g, members in enumerate(records):
                ids = np.flatnonzero(np.isin(index, members))
                values = fonts[ids]
                if not len(ids):
                    proposed.append(old[g])
                elif policy['pooling'] == 'row-median':
                    proposed.append(np.median([np.median(fonts[ids[index[ids] == i]]) for i in set(index[ids])]))
                elif policy['pooling'] == 'trimmed-mean':
                    proposed.append(np.exp(np.mean(np.log(np.clip(values, *np.quantile(values, [.1, .9]))))))
                else:
                    proposed.append(np.median(values))
        elif stage == 86:
            bank = neighbors84
            index, sizes = bank['indices'].astype(int), bank['sizes']
            d = bank['distances']
            weights = np.exp(-d / .02) * (d <= policy['maxDistance']) * np.log1p(bank['support'])
            weights /= np.maximum(1e-12, weights.sum(axis=1, keepdims=True))
            weights *= ((sizes / priors[index]) >= policy['minBodyRatio'])[:, None]
            valid = weights.sum(axis=1) > 0
            proposed = []
            for g, members in enumerate(records):
                ids = np.flatnonzero(np.isin(index, members) & valid)
                if len(ids) < 3:
                    proposed.append(old[g])
                    continue
                _, inv, counts = np.unique(index[ids], return_inverse=True, return_counts=True)
                w = weights[ids] / counts[inv, None]
                values = sizes[ids, None] * bank['ratios'][ids]
                candidates = np.arange(max(4, int(old[g] * .65)), int(old[g] * 1.45) + 1, .5)
                logdiff = np.log(candidates[:, None, None] / np.maximum(.1, values)[None, :, :])
                density = (np.exp(-.5 * (logdiff / policy['bandwidth'])**2) * w[None, :, :]).sum(axis=(1, 2))
                proposed.append(candidates[np.argmax(density)])
        elif stage in (90, 92, 93, 96, 98, 102):
            if row_features is None:
                row_features = _row_features(native, evidence, masked, cadence, components,
                                             neighbors84, point, priors, groups)
            if stage in MODEL_STAGES:
                f = np.c_[row_features, colors] if stage == 102 else row_features
                probabilities[stage] = model.predict_proba(f)
            if stage in (90, 96, 102):
                if policy.get('posteriorUnbiasPower', 0) != 0:
                    raise ValueError('Accepted round96 posteriorUnbiasPower must remain zero')
                proposed = _class_proposals(probabilities[stage], model, prepared, policy, page_sizes)
            elif stage == 98:
                p = np.asarray([probabilities[96][ids].mean(axis=0) for ids in records])
                classes = _asset(models, 96).classes_.astype(float)
                units = np.array([np.median(page_sizes[ids, 0] / 2048) for ids in records])
                proposed = units * classes[p.argmax(axis=1)]
                certainty = p.max(axis=1) if policy['certainty'] == 'probability' else np.sort(p, axis=1)[:, -1] - np.sort(p, axis=1)[:, -2]
                confident = np.clip((certainty - policy['threshold']) / max(.05, 1 - policy['threshold']), 0, 1)
                support = confident * np.exp(-.5 * (np.log(proposed / prepared['anchors']) / policy['physicalAgreementTolerance'])**2)
                if policy['directionGate']:
                    support *= ((proposed - old) * (prepared['anchors'] - old) > 0)
                weight = policy['baseStrength'] + (1 - policy['baseStrength']) * support
            else:
                proposed = []
                for g, ids in enumerate(records):
                    grid = np.arange(max(4, old[g] * (.6 if stage == 92 else .65)), old[g] * (1.5 if stage == 92 else 1.4) + .25, .5)
                    step = policy['logRatioStep'] if stage == 92 else _asset(policies, 92)['logRatioStep']
                    classes = _asset(models, 92).classes_.astype(float) * step
                    b = np.array([np.interp(np.log(grid / priors[i]), classes, probabilities[92][i], left=0, right=0) for i in ids])
                    if stage == 92:
                        likelihood = b.mean(axis=0) if policy['pooling'] == 'mean' else np.exp(np.log(np.maximum(1e-6, b)).mean(axis=0))
                    else:
                        c90 = _asset(models, 90).classes_.astype(float)
                        a = np.array([np.interp(grid / (page_sizes[i, 0] / 2048), c90, probabilities[90][i], left=0, right=0) for i in ids])
                        w = np.clip(np.expm1(evidence[ids, 146]), 1, 30)**policy['characterCountPower']
                        w /= w.sum()
                        if policy['pooling'] == 'mean':
                            a, b = (a * w[:, None]).sum(axis=0), (b * w[:, None]).sum(axis=0)
                        else:
                            a, b = np.exp((np.log(np.maximum(a, 1e-6)) * w[:, None]).sum(axis=0)), np.exp((np.log(np.maximum(b, 1e-6)) * w[:, None]).sum(axis=0))
                        mix = policy['absolutePosteriorWeight']
                        likelihood = np.maximum(a, 1e-8)**mix * np.maximum(b, 1e-8)**(1 - mix)
                    density = likelihood * np.exp(-.5 * (np.log(grid / old[g]) / policy['priorSigma'])**2)
                    proposed.append(grid[np.argmax(density)] if density.max() > 0 else old[g])
        elif stage == 108:
            t = templates[:, :64].reshape(-1, 4, 16)
            features, proposed = [], []
            for g, ids in enumerate(records):
                # Original round72 CE, not the actual103 branch of round105.
                a, f = _scaled_features(ids, 'prior', native, evidence, masked, cadence,
                                        point, priors, page_sizes, experts)
                raw, summary = _physical(ids, t, priors, policy)
                raw = raw if raw > 0 else old[g]
                features.append(np.r_[f, summary, np.log(old[g] / a), np.log(raw / a), np.log(raw / old[g])])
                proposed.append(raw)
            probability = model.predict_proba(np.asarray(features))[:, 1]
            proposed = np.where(probability >= policy['gateProbability'], proposed, old)
        elif stage == 112:
            features, grids, bounds = [], [], [0]
            for g, ids in enumerate(records):
                dim, appearance = signature(ids, native, actual, masked, cadence, colors,
                                            point, priors, *actual_experts)
                grid = np.arange(max(4, old[g] * .65), old[g] * 1.4 + .25, .5)
                f = candidate_features(dim, appearance, grid)
                grids.append(grid)
                features.append(f)
                bounds.append(bounds[-1] + len(f))
            f = np.vstack(features)
            density = np.maximum(1e-8, np.concatenate([model.predict(f[start:start + 4096]) for start in range(0, len(f), 4096)]))
            proposed = []
            for g, grid in enumerate(grids):
                values = density[bounds[g]:bounds[g+1]] * np.exp(-.5 * (np.log(grid / old[g]) / policy['priorSigma'])**2)
                if policy['decoding'] == 'mode':
                    v = grid[values.argmax()]
                elif policy['decoding'] == 'plateau':
                    v = np.mean(grid[values >= values.max() * .95])
                else:
                    v = np.average(grid, weights=values**4)
                proposed.append(v)
        before = apply_prepared(before, prepared, np.asarray(proposed), weight, policy['clip'], policy['quantum'])
        if return_stages:
            stages[f'round{stage}'] = before.copy()
    return (before, stages) if return_stages else before
