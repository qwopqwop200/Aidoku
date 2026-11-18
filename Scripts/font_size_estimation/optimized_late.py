"""Frozen source-only font graph, stages 133 through 198.

All learned objects are supplied in ``models``; policies contain scalar decoder
settings only. No fitting, query labels, cohort metadata, or prediction files
are used. ``point`` must be the full frozen model56 prediction for every row.
"""

from pathlib import Path
import json
import pickle

import numpy as np
from scipy.special import logsumexp

from optimized_late_features import (
    prepare_all,
    apply_prepared,
    fill_signature,
    compact,
    append_joint_signature,
    candidate_features,
    weighted_median,
    group_physics,
    optical_features,
    append_advance,
    stack_features,
)
from style_calibration import calibrate_style
from cohort_repair import repair_cohorts

STAGES = (
    133,
    138,
    139,
    142,
    144,
    148,
    159,
    161,
    164,
    175,
    177,
    179,
    181,
    182,
    184,
    189,
    193,
    196,
    198,
)
# Relative paths within the portable artifact directory, not research paths.
MODEL_FILES = {
    str(n): f'late_{n}.pkl'
    for n in (133, 138, 139, 142, 144, 148, 159, 164, 175, 177, 179, 181, 182, 184, 189, 190)
}
MODEL_FILES.update(
    style_encoder='late_style_encoder.pkl',
    page_prior='late_page_prior.npz',
    style_bank='late_style_bank.npz',
)
SIGNAL_KEYS = (
    'geometry128',
    'paint130',
    'templates135',
    'templates143',
    'joint147',
    'joint158',
    'templates167',
    'areas169',
    'style187',
    'cadence69',
    'pair_affinities',
)


def load_late_bundle(directory):
    """Load a trusted, packaged artifact directory; never resolve study files.

    The caller owns artifact integrity/authentication before loading pickle.
    NPZ bank fields are the exact ``calibrate_style`` TRAIN bank schema.
    """
    directory = Path(directory)
    models = {}
    for key, name in MODEL_FILES.items():
        path = directory / name
        if path.suffix == '.npz':
            with np.load(path, allow_pickle=False) as data:
                models[key] = {name: data[name].copy() for name in data.files}
        else:
            with path.open('rb') as stream:
                models[key] = pickle.load(stream)
    models['source_identity_aliases'] = json.loads(
        (directory / 'late_source_aliases.json').read_text()
    )
    models['sourceIdentityGroups'] = models['source_identity_aliases']
    policies = json.loads((directory / 'late_policies.json').read_text())
    return models, policies


def _get(mapping, key):
    return mapping[str(key)] if str(key) in mapping else mapping[key]


def _predict(model, features):
    if not len(features):
        return np.empty(0)
    return np.concatenate(
        [
            np.asarray(model.predict(features[i : i + 4096])).reshape(-1)
            for i in range(0, len(features), 4096)
        ]
    )


def _apply(before, prepared, proposed, policy):
    return apply_prepared(
        before,
        prepared,
        np.asarray(proposed),
        policy['strength'],
        policy['clip'],
        policy['quantum'],
    )


def _signature(ids, stage, priors, point, page_sizes, signals):
    fn = fill_signature if stage == 138 else compact
    templates = signals['templates135' if stage <= 142 else 'templates143']
    dim, app = fn(ids, priors, templates, signals['geometry128'], signals['paint130'], point)
    if stage >= 148:
        joint = signals['joint147' if stage == 148 else 'joint158']
        dim, app = append_joint_signature(ids, priors, joint, dim, app)
    width, height = page_sizes[ids[0]]
    return np.r_[dim, width, height, np.sqrt(width * height)], np.r_[app, np.log(width / height)]


def _candidate_stage(stage, before, prepared, priors, point, page_sizes, signals, models, policy):
    grids, features, bounds = [], [], [0]
    for ids, old in zip(prepared['records'], prepared['old']):
        dim, app = _signature(ids, stage, priors, point, page_sizes, signals)
        grid = np.arange(max(4, old * 0.65), old * 1.4 + 0.25, 0.5)
        grids.append(grid)
        features.append(candidate_features(dim, app, grid))
        bounds.append(bounds[-1] + len(grid))
    model = _get(models, 159 if stage == 161 else stage)
    density = np.maximum(1e-8, _predict(model, np.vstack(features)))
    proposed = []
    for i, (ids, grid, old) in enumerate(zip(prepared['records'], grids, prepared['old'])):
        values = density[bounds[i] : bounds[i + 1]]
        decoder = policy.get('decoding', policy.get('decoder'))
        if stage == 161:
            prior = models['page_prior']
            kind = policy['pageNormalization']
            sizes = prior['pageSizes']
            units = (
                sizes[:, 0]
                if kind == 'width'
                else sizes[:, 1] if kind == 'height' else np.sqrt(np.prod(sizes, axis=1))
            )
            page = page_sizes[ids[0]]
            unit = (
                page[0]
                if kind == 'width'
                else page[1] if kind == 'height' else np.sqrt(np.prod(page))
            )
            z = np.log(prior['targets'] / units)
            lp = logsumexp(
                -0.5
                * ((np.log(grid / unit)[:, None] - z[None, :]) / policy['TRAINChosenBandwidth'])
                ** 2
                + np.log(prior['weights'])[None, :],
                axis=1,
            )
            lp -= lp.max()
            logits = (
                np.log(values)
                + policy['priorStrength'] * lp
                - 0.5 * (np.log(grid / old) / policy['priorSigma']) ** 2
            )
            mass = np.exp(logits - logits.max())
        else:
            mass = values * np.exp(-0.5 * (np.log(grid / old) / policy['priorSigma']) ** 2)
        if decoder == 'mode':
            value = grid[mass.argmax()]
        elif decoder == 'plateau':
            value = np.mean(grid[mass >= mass.max() * 0.95])
        elif decoder == 'relative-median':
            cdf = np.cumsum(mass / grid)
            value = grid[np.searchsorted(cdf, 0.5 * cdf[-1])]
        else:
            value = np.average(grid, weights=mass**4)
        proposed.append(value)
    return _apply(before, prepared, proposed, policy)


def _physical_stage(before, prepared, point, priors, signals, model, policy):
    geo, paint = signals['geometry128'], signals['paint130']
    geometry = np.c_[geo['X'], paint]
    physical = np.c_[geo['physical'], np.exp(paint[:, :32]) * priors[:, None]]
    anchors, features = [], []
    # The selected round133 policy uses physical cues only; no source experts.
    if policy['mode'] != 'physical':
        raise ValueError('Only the frozen physical round133 policy is supported')
    for ids in prepared['records']:
        anchor = float(np.median(priors[ids]))
        z = geometry[ids]
        size = np.quantile(physical[ids] / anchor, [0.2, 0.5, 0.8], axis=0).ravel()
        f = np.r_[
            np.quantile(z, [0.2, 0.5, 0.8], axis=0).ravel(),
            z.mean(axis=0),
            z.std(axis=0),
            np.log(np.maximum(0.01, size)),
            np.quantile(point[ids] / anchor, [0.1, 0.5, 0.9]),
        ]
        anchors.append(anchor)
        features.append(f)
    features = np.asarray(features)
    aggregation = policy['aggregation']
    raw = (
        _predict(model, features)
        if aggregation == 'mean'
        else np.quantile(
            [tree.predict(features) for tree in model.estimators_], aggregation, axis=0
        )
    )
    proposed = np.asarray(anchors) * np.maximum(0.01, raw) / 100
    return _apply(before, prepared, proposed, policy)


def _optical(prepared, priors, evidence, page_sizes, signals, models):
    physics, optical = [], []
    for ids in prepared['records']:
        measured = group_physics(
            ids, priors, signals['templates167'], signals['areas169'], signals['paint130']
        )
        base = optical_features(*measured, signals['geometry128']['X'], ids, page_sizes[ids[0]])
        optical.append(
            append_advance(
                base, ids, priors, signals['cadence69'], evidence[:, 146:164], measured[0]
            )
        )
        physics.append(measured)
    physics, optical = np.asarray(physics), np.asarray(optical)
    points = []
    for font, state in enumerate(_get(models, 175)):
        correction = (
            _predict(state['model'], (optical[:, font] - state['mean']) / state['std'])
            / state['targetScale']
        )
        points.append(physics[:, 0, font] * np.exp(np.clip(correction, -0.5, 0.5)))
    points = np.asarray(points).T
    anchor = np.array(
        [
            np.median(e[0][e[0] > 0]) if np.any(e[0] > 0) else prepared['anchors'][i]
            for i, e in enumerate(physics)
        ]
    )
    return physics, optical, points, anchor


def _style(signals, encoder, records):
    source = signals['style187']
    values = np.clip(source[:, :255], -encoder['clip'], encoder['clip'])
    latent = encoder['model'].transform((values - encoder['mean']) / encoder['std'])
    # Calibration uses all transformed rows; only pooling zeroes unsupported rows.
    pooled_latent = latent.copy()
    pooled_latent[source[:, 255] <= 0] = 0.0
    pooled = {}
    for mode, values in [
        ('raw', np.c_[values, source[:, 255:]]),
        ('pca', np.c_[pooled_latent, source[:, 255:]]),
    ]:
        rows = []
        for ids in records:
            ok = source[ids, 255] > 0
            weight = source[ids, 255] * np.maximum(0.05, source[ids, 256]) ** 4
            z, w = values[ids][ok], weight[ok]
            if not len(z):
                rows.append(np.zeros(2 * values.shape[1] + 9))
                continue
            average = np.average(z, axis=0, weights=w)
            rows.append(
                np.r_[
                    average,
                    np.sqrt(np.average((z - average) ** 2, axis=0, weights=w)),
                    float(ok.mean()),
                    float(source[ids, 255].mean()),
                    float(source[ids, 256].mean()),
                    float(source[ids, 257].mean()),
                    source[ids, 258:].mean(axis=0),
                    np.log1p(len(ids)),
                ]
            )
        pooled[mode] = np.asarray(rows)
    return latent, pooled


def _posterior_decode(classes, logits, decoder):
    mass = np.exp(logits - logits.max(axis=1, keepdims=True))
    mass /= mass.sum(axis=1, keepdims=True)
    if decoder == 'mode':
        return classes[mass.argmax(axis=1)]
    if decoder == 'mean':
        return np.sum(mass * classes[None, :], axis=1)
    cdf = np.cumsum(mass / classes[None, :], axis=1)
    cdf /= cdf[:, -1, None]
    return classes[(cdf >= 0.5).argmax(axis=1)]


def predict_late(
    before,
    point,
    native,
    evidence,
    priors,
    groups,
    page_sizes,
    signals,
    models,
    policies,
    source_ids=None,
    return_stages=False,
):
    """Predict source fonts, optionally returning ``(sizes, {stage: sizes})``.

    ``source_ids`` are opaque source-connected identities for TRAIN-bank
    exclusion only; they never select a model, cohort, label, or size. Membership
    always derives from exact current predicted sizes within ``groups``.
    ``pair_affinities`` is the base graph's list of (row indices, NxN matrix).
    Models/policies accept integer or decimal-string stage keys.
    """
    before, point, native, evidence, priors, groups, page_sizes = (
        np.asarray(v) for v in (before, point, native, evidence, priors, groups, page_sizes)
    )
    n = len(before)
    if (
        before.shape != (n,)
        or point.shape != (n,)
        or priors.shape != (n,)
        or groups.shape != (n,)
        or page_sizes.shape != (n, 2)
        or native.shape != (n, 156)
        or evidence.shape != (n, 291)
    ):
        raise ValueError('Invalid late graph input dimensions')
    if any(not np.isfinite(v).all() for v in (before, point, native, evidence, priors, page_sizes)):
        raise ValueError('Late graph inputs must be finite')
    if any(np.any(v <= 0) for v in (before, point, priors, page_sizes)):
        raise ValueError('Sizes and page dimensions must be positive')
    if source_ids is None:
        raise ValueError('source_ids required for source-excluded style calibration')
    source_ids = np.asarray(source_ids)
    aliases = models.get('source_identity_aliases', {})
    if source_ids.ndim == 1:
        source_ids = np.asarray(
            [aliases.get(str(identity), str(identity)) for identity in source_ids]
        )
    if source_ids.shape != (n,):
        raise ValueError('source_ids must align with query rows')
    for key in SIGNAL_KEYS:
        if key not in signals:
            raise ValueError(f'Missing source signal {key}')
    if n == 0:
        result = np.asarray(before, float).copy()
        return (
            (result, {f'round{stage}': result.copy() for stage in STAGES})
            if return_stages
            else result
        )
    rows = [{'pageSize': size} for size in page_sizes]
    values = np.asarray(before, float).copy()
    stages = {}
    optical_cache = None
    for stage in STAGES:
        policy = _get(policies, stage)
        prepared = prepare_all(values, point, rows, groups, native, evidence, False)
        if stage == 133:
            values = _physical_stage(
                values, prepared, point, priors, signals, _get(models, stage), policy
            )
        elif stage in (138, 139, 142, 144, 148, 159, 161, 164):
            values = _candidate_stage(
                stage, values, prepared, priors, point, page_sizes, signals, models, policy
            )
        elif stage == 175:
            # The common 176 covariates are source-only and pooled on the
            # incoming 164 partition. Reuse only if membership stays identical.
            physics, optical, points, anchor = _optical(
                prepared, priors, evidence, page_sizes, signals, models
            )
            optical_cache = (prepared['records'], physics, optical, points, anchor)
            q = physics[:, 1, :]
            ratios = np.log(
                np.divide(
                    physics[:, 0, :],
                    physics[:, 2, :],
                    out=np.ones_like(q),
                    where=(physics[:, 0, :] > 0) & (physics[:, 2, :] > 0),
                )
            )
            same = (physics[:, 0, :] > 0) & (physics[:, 2, :] > 0) & (physics[:, 3, :] > 0.1)
            noise = np.array([state['OOFNoise'] for state in _get(models, 175)])
            logits = (
                policy['shapeTemperature'] * q
                - 0.5 * (ratios / policy['consistencySigma']) ** 2 * same
                - np.log(noise)[None, :]
            )
            weights = np.exp(logits - logits.max(axis=1)[:, None]) * (q > 0.1)
            proposal = np.array(
                [
                    (
                        weighted_median(v, w)
                        if policy['decoder'] == 'median' and w.sum() > 0
                        else np.average(v, weights=w) if w.sum() > 0 else prepared['old'][i]
                    )
                    for i, (v, w) in enumerate(zip(points, weights))
                ]
            )
            logcount = np.log1p([len(ids) for ids in prepared['records']])
            proposal = np.where(
                q.max(axis=1) + policy['qualityCountBonus'] * logcount
                >= policy['minimumMatchQuality'],
                proposal,
                prepared['old'],
            )
            values = _apply(values, prepared, proposal, policy)
        elif stage in (177, 179, 181, 182, 184, 189, 193):
            cached_records = optical_cache[0]
            if len(cached_records) == len(prepared['records']) and all(
                np.array_equal(a, b) for a, b in zip(cached_records, prepared['records'])
            ):
                _, physics, optical, points, anchor = optical_cache
            else:
                physics, optical, points, anchor = _optical(
                    prepared, priors, evidence, page_sizes, signals, models
                )
                optical_cache = (prepared['records'], physics, optical, points, anchor)
            features, spread, q = stack_features(points, physics, optical, anchor)
            if stage in (177, 179, 181, 182, 184):
                state = _get(models, stage)
                if stage == 184:
                    features = np.c_[features, np.log(anchor)]
                if state.get('logTarget'):
                    raw = (
                        np.exp(
                            np.clip(
                                _predict(state['model'], (features - state['mean']) / state['std'])
                                / 100,
                                -0.5,
                                0.5,
                            )
                        )
                        * 100
                    )
                else:
                    f = (
                        (features - state['mean']) / state['std']
                        if state.get('standardized')
                        else features
                    )
                    raw = np.maximum(0.1, _predict(state['model'], f))
                proposed = anchor * raw / 100
                logcount = np.log1p([len(ids) for ids in prepared['records']])
                proposed = np.where(
                    (spread <= policy['maximumExpertLogSpread'])
                    & (q + policy['qualityCountBonus'] * logcount >= policy['minimumMatchQuality']),
                    proposed,
                    prepared['old'],
                )
            else:
                _, style = _style(signals, models['style_encoder'], prepared['records'])
                base = np.c_[features, np.log(anchor)]
                classifier = _get(models, 189)
                mode = _get(policies, 189)['styleRepresentation']
                prob = classifier.predict_proba(np.c_[base, style[mode]])
                classes = classifier.classes_.astype(float)
                order = np.argsort(classes)
                classes, prob = classes[order], prob[:, order]
                old = prepared['old']
                supported = np.min(abs(old[:, None] - classes[None, :]), axis=1) <= 0.5
                if stage == 189:
                    logits = (
                        np.log(np.maximum(1e-12, prob))
                        - 0.5
                        * (np.log(classes[None, :] / old[:, None]) / policy['priorSigma']) ** 2
                    )
                    supported &= prob.max(axis=1) >= policy['minimumSourceProbability']
                else:
                    state = _get(models, 190)
                    f = np.c_[base, style['pca']]
                    raw = _predict(state['model'], (f - state['mean']) / state['std'])
                    mu = anchor * np.maximum(0.001, raw) / 100
                    center, native_spread, count = [], [], []
                    for v, qq, a in zip(physics[:, 0, :], physics[:, 1, :], anchor):
                        ok = (v > 0) & (qq > 0.3)
                        center.append(float(np.median(v[ok])) if ok.any() else a)
                        native_spread.append(float(np.std(np.log(v[ok]))) if ok.sum() >= 2 else 0.4)
                        count.append(int(ok.sum()))
                    center = np.asarray(center)
                    physical_sigma = np.clip(
                        policy['physicalSigmaFloor']
                        + policy['rawReferenceSpreadScale'] * np.asarray(native_spread)
                        + policy['sourceMatchQualityScale'] * (1 - q),
                        0.005,
                        0.4,
                    )
                    logits = (
                        np.log(np.maximum(1e-12, prob)) / policy['classTemperature']
                        - 0.5
                        * (np.log(classes[None, :] / center[:, None]) / physical_sigma[:, None])
                        ** 2
                        - 0.5
                        * (np.log(classes[None, :] / old[:, None]) / policy['previousPriorSigma'])
                        ** 2
                        - 0.5
                        * (np.log(classes[None, :] / mu[:, None]) / policy['continuousPriorSigma'])
                        ** 2
                    )
                    supported &= np.asarray(count) >= 2
                proposed = np.where(
                    supported, _posterior_decode(classes, logits, policy['decoder']), old
                )
            values = _apply(values, prepared, proposed, policy)
        elif stage == 196:
            encoder = models['style_encoder']
            latent, _ = _style(signals, encoder, prepared['records'])
            s = signals['style187']
            family = s[:, 258:].argmax(axis=1)
            em = (
                signals['templates167'][:, :64].reshape(-1, 4, 16)[np.arange(n), family, 1] * priors
            )
            source = dict(
                style=latent,
                referenceFamily=family,
                measuredEm=em,
                quality=s[:, 256],
                support=s[:, 255],
                sourceGroup=source_ids,
            )
            values = calibrate_style(
                values,
                prepared['records'],
                prepared['pages'],
                config=policy,
                source_evidence=source,
                train_bank=models['style_bank'],
                explained_variance=encoder['model'].explained_variance_,
            )
        elif stage == 198:
            s = signals['style187']
            family = s[:, 258:].argmax(axis=1)
            em = (
                signals['templates167'][:, :64].reshape(-1, 4, 16)[np.arange(n), family, 1] * priors
            )
            covered = np.zeros(n, bool)
            for ids, affinity in signals['pair_affinities']:
                ids = np.asarray(ids, int)
                if (
                    ids.ndim != 1
                    or np.any(ids < 0)
                    or np.any(ids >= n)
                    or len(np.unique(ids)) != len(ids)
                    or covered[ids].any()
                    or len(set(groups[ids])) != 1
                ):
                    raise ValueError('Invalid pair-affinity page partition')
                covered[ids] = True
                values[ids] = repair_cohorts(
                    values[ids], affinity, em[ids], family[ids], s[ids, 256], s[ids, 255], **policy
                )
            if not covered.all():
                raise ValueError('Pair affinities must cover every query row')
        if not np.isfinite(values).all() or np.any(values <= 0):
            raise ValueError(f'Invalid prediction at late stage {stage}')
        if return_stages:
            stages[f'round{stage}'] = values.copy()
    return (values, stages) if return_stages else values
