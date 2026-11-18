"""Portable, source-only last-stage style calibration (round194/196).

No fitting, files, experiment imports, or query labels. ``style`` is the PCA
transform *before* whitening; ``support`` is S[:,255] (the numeric glyph
support, not a boolean); ``quality`` is S[:,256]. Source groups are opaque
identities used only for exclusion/diversity. The caller must supply a bank
already restricted to TRAIN, with .25 < calibrationRatio < 4 and quality > .5.
Bank row order is the deterministic secondary key for equal NN distances.
The caller owns PCA/source provenance and the upstream cohort ancestry; this
module deliberately does not connect itself to the active estimator.
"""

from collections.abc import Mapping

import numpy as np


CONFIG_KEYS = frozenset((
    'whitening', 'styleDimensions', 'sourceSizeDistanceWeight', 'neighbors',
    'neighborAggregation', 'TRAINSourceExcludedDistanceQuantile',
    'maximumCalibrationLogSpread', 'strength', 'clip', 'quantum',
))


def _numeric(value, name, ndim):
    raw = np.asarray(value)
    if raw.dtype.kind not in 'iuf' or raw.ndim != ndim:
        raise ValueError(f'{name} must be a numeric {ndim}D array')
    result = raw.astype(float)
    if not np.isfinite(result).all():
        raise ValueError(f'{name} must be finite')
    return result


def _indices(value, name, size):
    raw = np.asarray(value)
    if raw.ndim != 1 or raw.dtype.kind not in 'iu' or not len(raw):
        raise ValueError(f'{name} must contain integer indices')
    if np.any(raw < 0) or np.any(raw >= size) or len(np.unique(raw)) != len(raw):
        raise ValueError(f'{name} contains duplicate/out-of-range indices')
    return raw.astype(int)


def _partition(records, name, size):
    result = [_indices(ids, name, size) for ids in records]
    flat = np.concatenate(result) if result else np.array([], int)
    if not np.array_equal(np.sort(flat), np.arange(size)):
        raise ValueError(f'{name} must partition all indices exactly once')
    return result


def _evidence(data, name):
    if not isinstance(data, Mapping):
        raise ValueError(f'{name} must be a mapping')
    required = {'style', 'referenceFamily', 'measuredEm', 'quality', 'sourceGroup'}
    required.add('support' if name == 'source' else 'calibrationRatio')
    if set(data) != required:
        raise ValueError(f'{name} requires exactly {sorted(required)}')
    result = {key: _numeric(data[key], key, 2 if key == 'style' else 1)
              for key in required - {'sourceGroup'}}
    n = len(result['style'])
    if any(len(value) != n for value in result.values()):
        raise ValueError(f'{name} row counts differ')
    family = result['referenceFamily']
    if np.any((family != np.floor(family)) | (family < 0) | (family > 3)):
        raise ValueError('referenceFamily must contain integers in [0, 3]')
    groups = np.asarray(data['sourceGroup'])
    if groups.shape != (n,) or groups.dtype.kind not in 'iuUS':
        raise ValueError('sourceGroup must contain integer or string identities')
    if groups.dtype.kind in 'US' and np.any(np.char.str_len(groups) == 0):
        raise ValueError('sourceGroup identities must not be empty')
    result['sourceGroup'] = groups
    if np.any((result['quality'] < 0) | (result['quality'] > 1)):
        raise ValueError('quality must be in [0, 1]')
    if name == 'source':
        if np.any(result['support'] < 0) or np.any(result['measuredEm'] < 0):
            raise ValueError('source support/measuredEm must be nonnegative')
    elif (np.any(result['measuredEm'] < 2) or np.any(result['quality'] <= .5)
          or np.any(result['calibrationRatio'] <= .25)
          or np.any(result['calibrationRatio'] >= 4)):
        raise ValueError('bank does not satisfy TRAIN bank admission bounds')
    return result


def _config(config):
    if (not isinstance(config, Mapping) or not CONFIG_KEYS <= set(config)
            or set(config) - CONFIG_KEYS - {'inverseDistancePower'}):
        raise ValueError(f'config requires exactly {sorted(CONFIG_KEYS)}')
    c = dict(config)
    c.setdefault('inverseDistancePower', 2.)
    if not isinstance(c['whitening'], (bool, np.bool_)):
        raise ValueError('whitening must be boolean')
    for key in ('styleDimensions', 'neighbors'):
        if isinstance(c[key], (bool, np.bool_)) or not isinstance(c[key], (int, np.integer)) or c[key] < 1:
            raise ValueError(f'{key} must be a positive integer')
    if c['neighbors'] > 31 or c['neighborAggregation'] not in ('mean', 'median'):
        raise ValueError('expected 1..31 neighbors and mean/median aggregation')
    for key in (CONFIG_KEYS | {'inverseDistancePower'}) - {'whitening', 'styleDimensions', 'neighbors', 'neighborAggregation'}:
        value = _numeric(c[key], key, 0).item()
        c[key] = value
        if value < 0:
            raise ValueError(f'{key} must be nonnegative')
    if not 0 < c['TRAINSourceExcludedDistanceQuantile'] <= 1 or c['quantum'] <= 0:
        raise ValueError('distance quantile must be in (0, 1]; quantum must be positive')
    return c


def _weighted_median(values, weights):
    order = np.argsort(values, kind='stable')
    return float(values[order][np.searchsorted(np.cumsum(weights[order]), weights.sum() / 2)])


def calibrate_style(before, cohorts, pages, *, config, source_evidence, train_bank,
                    explained_variance=None, train_indices=None, return_diagnostics=False):
    """Return calibrated float sizes, preserving the supplied cohort partition.

    ``cohorts`` partitions query row indices; ``pages`` partitions cohort indices.
    Each cohort must have one exact before size, distinct within its page.
    Config uses the ten round194 selected-setting keys (without DEV metrics),
    plus optional ``inverseDistancePower`` (default 2; round196 uses 1).
    For quantiles < 1, supply TRAIN query indices to reproduce the source-excluded
    nearest-distance cutoff. A quantile of 1 uses infinity, even with no bank.
    Optional diagnostics return ``(sizes, dict)`` including NN bank indices,
    distances, row points, log spreads, cohort proposals and collision pages.
    Inputs are never mutated. Missing neighbors fall back to old proposals;
    even fallback proposals undergo rounding, just as in apply_prepared.
    """
    c = _config(config)
    old_rows = _numeric(before, 'before', 1)
    if np.any(old_rows <= 0):
        raise ValueError('before sizes must be positive')
    source = _evidence(source_evidence, 'source')
    bank = _evidence(train_bank, 'bank')
    n = len(old_rows)
    if len(source['style']) != n:
        raise ValueError('before/source row counts differ')
    records = _partition(cohorts, 'cohorts', n)
    page_records = _partition(pages, 'pages', len(records))
    old = np.array([old_rows[ids[0]] for ids in records])
    if any(np.any(old_rows[ids] != value) for ids, value in zip(records, old)):
        raise ValueError('cohort before sizes differ')
    if any(len(np.unique(old[ids])) != len(ids) for ids in page_records):
        raise ValueError('page before sizes collide across cohorts')
    dimensions = c['styleDimensions']
    if source['style'].shape[1] != bank['style'].shape[1] or dimensions > source['style'].shape[1]:
        raise ValueError('incompatible PCA style dimensions')
    z = source['style'][:, :dimensions].copy()
    b = bank['style'][:, :dimensions].copy()
    if explained_variance is not None:
        variance = _numeric(explained_variance, 'explained_variance', 1)
        if len(variance) < dimensions or np.any(variance < 0):
            raise ValueError('incompatible explained variance')
    elif c['whitening']:
        raise ValueError('whitening requires explained_variance')
    if c['whitening']:
        scale = np.sqrt(np.maximum(1e-6, variance[:dimensions]))
        z /= scale
        b /= scale
    train_ids = None if train_indices is None else _indices(train_indices, 'train_indices', n)
    if c['TRAINSourceExcludedDistanceQuantile'] < 1 and train_ids is None:
        raise ValueError('distance quantiles below 1 require train_indices')
    support = (source['support'] > 0) & (source['quality'] > .3) & (source['measuredEm'] >= 2)
    capacity = max(15, c['neighbors'])
    ref_indices = np.full((n, capacity), -1, int)
    distance = np.full((n, capacity), np.inf)
    # Keep the original matrix arithmetic order to preserve cached numerics.
    with np.errstate(over='raise', invalid='raise', divide='raise'):
        try:
            for family in range(4):
                queries = np.flatnonzero(support & (source['referenceFamily'] == family))
                references = np.flatnonzero(bank['referenceFamily'] == family)
                if not len(queries) or not len(references):
                    continue
                a, bb = z[queries], b[references]
                d2 = (np.sum(a*a, axis=1)[:, None] + np.sum(bb*bb, axis=1)[None, :]
                      - 2*np.einsum('ik,jk->ij', a, bb)) / dimensions
                d2 = np.maximum(0, d2) + c['sourceSizeDistanceWeight'] * (
                    np.log(source['measuredEm'][queries, None] / bank['measuredEm'][references][None, :]))**2
                for i, distances in zip(queries, d2):
                    distances = np.where(bank['sourceGroup'][references] == source['sourceGroup'][i], np.inf, distances)
                    seen = set()
                    chosen = []
                    for j in np.argsort(distances, kind='stable'):
                        if not np.isfinite(distances[j]):
                            break
                        group = bank['sourceGroup'][references[j]]
                        if group in seen:
                            continue
                        seen.add(group)
                        chosen.append(j)
                        if len(chosen) == capacity:
                            break
                    ref_indices[i, :len(chosen)] = references[chosen]
                    distance[i, :len(chosen)] = np.sqrt(distances[chosen])
            limit = np.inf
            if c['TRAINSourceExcludedDistanceQuantile'] < 1:
                train_distance = distance[train_ids, 0]
                train_distance = train_distance[np.isfinite(train_distance)]
                if not len(train_distance):
                    raise ValueError('no finite TRAIN source-excluded distances')
                limit = float(np.quantile(train_distance, c['TRAINSourceExcludedDistanceQuantile']))
            row_points = np.zeros(n)
            spread = np.full(n, 10.)
            for i in np.flatnonzero(support):
                refs = ref_indices[i, :c['neighbors']]
                d = distance[i, :c['neighbors']]
                ok = refs >= 0
                if not ok.any():
                    continue
                values = np.log(bank['calibrationRatio'][refs[ok]])
                weights = 1 / np.maximum(.05, d[ok])**c['inverseDistancePower']
                centre = (_weighted_median(values, weights) if c['neighborAggregation'] == 'median'
                          else float(np.average(values, weights=weights)))
                row_points[i] = source['measuredEm'][i] * np.exp(centre)
                spread[i] = float(np.median(abs(values - np.median(values))))
            proposed = old.copy()
            for j, ids in enumerate(records):
                members = ids[(row_points[ids] > 0) & (distance[ids, 0] <= limit)
                              & (spread[ids] <= c['maximumCalibrationLogSpread'])]
                if len(members):
                    weights = np.maximum(.001, source['quality'][members])**4 * np.maximum(.25, source['support'][members])
                    proposed[j] = _weighted_median(row_points[members], weights)
            values = old * np.exp(np.clip(c['strength'] * np.log(proposed / old), -c['clip'], c['clip']))
            values = np.maximum(c['quantum'], np.round(values / c['quantum']) * c['quantum'])
            if not np.isfinite(values).all() or not np.isfinite(row_points).all():
                raise ValueError('calibration produced nonfinite values')
        except FloatingPointError as error:
            raise ValueError('calibration numeric range exceeded') from error
    collisions = []
    for page, ids in enumerate(page_records):
        if len(set(values[ids])) != len(ids):
            values[ids] = old[ids]
            collisions.append(page)
    result = old_rows.copy()
    for ids, value in zip(records, values):
        result[ids] = value
    if return_diagnostics:
        return result, dict(referenceIndices=ref_indices, distance=distance, distanceLimit=limit,
                            rowPoints=row_points, ratioSpread=spread, proposals=proposed,
                            collisionPages=collisions)
    return result
