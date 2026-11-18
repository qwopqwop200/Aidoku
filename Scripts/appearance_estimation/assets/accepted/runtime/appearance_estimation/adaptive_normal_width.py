"""Single primary paint band measured on actual native pixels along local normals.

No IDs, labels, nominal width, page rules, RF or CNN enter this measurement.
"""
from collections import Counter
import cv2
import numpy as np

VERSION = 'native-local-exterior-adaptive-normal-width-v2'
POLICY = dict(maxComponents=12, raysPerComponent=48, sectors=8,
              depthMinimumPx=32, depthMaximumPx=96, depthFontFraction=.8,
              normalSmoothSigma=1., minimumComponentPixels=20,
              maximumFillToleranceLAB=14., maximumPrimaryToleranceLAB=14.,
              minimumFillPrimaryContrastLAB=16., minimumExteriorContrastLAB=3.,
              exteriorNativeSamples=3, exteriorSpreadLAB=8.,
              minimumAcceptedRays=12, minimumSectors=3)


def _lab(rgb):
    a = np.asarray(rgb, np.float32)
    return cv2.cvtColor(a.reshape(-1, 1, 3) / 255., cv2.COLOR_RGB2LAB).reshape(a.shape)


def _crossing(t, values, first, last, a, b):
    """Half-paint transition between native witnesses; no interpolated RGB witnesses."""
    vector = b - a
    alpha = ((values[first:last + 1] - a) @ vector) / max(1e-6, float(vector @ vector))
    crossings = np.flatnonzero((alpha[:-1] <= .5) & (alpha[1:] >= .5))
    if not len(crossings):
        return None
    k = int(crossings[0])
    fraction = np.clip((.5 - alpha[k]) / max(1e-6, alpha[k + 1] - alpha[k]), 0, 1)
    return float(t[first + k] + fraction * (t[first + k + 1] - t[first + k]))


def _ray(rgb, image_lab, labels, identity, point, normal, depth, fill, primary, ftol, otol):
    steps = np.arange(-3., depth + .5, .5)
    xy = np.rint(point[None] + steps[:, None] * normal).astype(int)
    keep = np.r_[True, np.any(xy[1:] != xy[:-1], axis=1)]
    xy = xy[keep]
    t = (xy - point) @ normal
    h, w = labels.shape
    valid = (xy[:, 0] >= 0) & (xy[:, 0] < w) & (xy[:, 1] >= 0) & (xy[:, 1] < h)
    # Retain finite prefix only; crop edges never become observed paint.
    forward_bad = np.flatnonzero((t >= 0) & ~valid)
    stop = int(forward_bad[0]) if len(forward_bad) else len(t)
    xy, t, valid = xy[:stop], t[:stop], valid[:stop]
    xy, t = xy[valid], t[valid]
    clipped = bool(len(forward_bad))
    if len(t) < 7:
        return None, 'outside-crop'
    values = image_lab[xy[:, 1], xy[:, 0]]
    df = np.linalg.norm(values - fill, axis=1)
    do = np.linalg.norm(values - primary, axis=1)
    fill_match = df <= ftol
    primary_match = (do <= otol) & (do < df)
    seed_fill = np.flatnonzero((t >= -2.5) & (t <= .75) & fill_match)
    if not len(seed_fill):
        return None, 'no-native-fill-anchor'
    anchor = int(seed_fill[-1])
    positions = np.flatnonzero((np.arange(len(t)) > anchor) & primary_match & (t <= 6))
    if not len(positions):
        return None, 'no-adjacent-primary-core'
    start = int(positions[0])
    # Actual best source core calibrates small prediction/compression RGB shifts.
    observed_primary = values[int(positions[np.argmin(do[positions])])] 
    if np.any(fill_match[anchor + 1:start]):
        return None, 'unstable-fill-boundary'
    entry = _crossing(t, values, anchor, start, fill, primary)
    if entry is None:
        return None, 'unresolved-fill-primary-transition'
    # First stable, distinct exterior terminates PRIMARY only, including a second ring.
    # Its color is local source observation; no global background-color requirement.
    for j in range(start + 1, len(t) - 2):
        owner = labels[xy[j, 1], xy[j, 0]]
        if owner > 0 and owner != identity:
            return None, 'other-fill-component'
        if fill_match[j]:
            return None, 'fill-return-or-concavity'
        window = values[j:j + 3]
        reference = np.median(window, axis=0)
        contrast = float(np.linalg.norm(reference - observed_primary))
        if contrast < POLICY['minimumExteriorContrastLAB']:
            continue
        # The old global primary tolerance (up to14LAB) swallowed pale
        # backgrounds whose genuine separation from the ring is only3..14LAB.
        # Certify a stable local exterior first, then adapt the core tolerance
        # to that observed separation; no nominal width enters this decision.
        if fill_match[j:j + 3].any():continue
        spread = min(POLICY['exteriorSpreadLAB'],max(.75,.3*contrast))
        if np.max(np.linalg.norm(window-reference,axis=1)) > spread:continue
        if np.min(np.linalg.norm(window-observed_primary,axis=1)) < .6*contrast:continue
        if np.any((labels[xy[j:j + 3, 1], xy[j:j + 3, 0]] > 0) &
                  (labels[xy[j:j + 3, 1], xy[j:j + 3, 0]] != identity)):
            return None, 'other-fill-component'
        local_primary = np.linalg.norm(values[start:j]-observed_primary,axis=1)<=min(otol,max(.75,.3*contrast))
        positions_primary = np.flatnonzero(local_primary)
        if not len(positions_primary):continue
        last_primary = int(positions_primary[-1])+start
        if t[j] - t[last_primary] > 4:
            return None, 'unresolved-primary-exterior-gap'
        exit_position = _crossing(t, values, last_primary, j, observed_primary, reference)
        if exit_position is None:
            return None, 'unresolved-primary-exterior-transition'
        width = exit_position - entry
        if width <= 0:
            return None, 'nonpositive-band'
        # Orientation describes the actual local normal, not a cardinal ray.
        sector = int(((np.arctan2(normal[1], normal[0]) + np.pi) / (np.pi / 4))) % 8
        witness = [anchor, start, last_primary, j, j + 2]
        return dict(widthPx=float(width), sector=sector, primaryCoreWidthPx=float(t[last_primary] - t[start]),
                    exteriorContrastLAB=contrast, transitionSpanPx=float((t[start] - t[anchor]) + (t[j] - t[last_primary])),
                    seedXY=point.astype(int).tolist(), normal=normal.tolist(),
                    witnessXY=xy[witness].tolist(), witnessRGB=rgb[xy[witness, 1], xy[witness, 0]].tolist(),
                    termination='observed-distinct-local-exterior'), None
    return None, 'outside-crop-before-exit' if clipped else 'depth-without-observed-exit'


def _summary(records):
    if not records:
        return dict(n=0, medianPx=0., p25Px=0., p75Px=0., MADPx=0.)
    v = np.array([r['widthPx'] for r in records])
    center = np.median(v)
    return dict(n=len(v), medianPx=float(center), p25Px=float(np.quantile(v, .25)),
                p75Px=float(np.quantile(v, .75)), MADPx=float(np.median(abs(v - center))))


def measure(rgb, predicted_mask, fill_rgb, primary_rgb, outline_present, font_pixels, polygons=None):
    """Source-only, width-independent input contract, bounded to the original crop."""
    if rgb.dtype != np.uint8 or rgb.shape != (*predicted_mask.shape, 3):
        raise ValueError('Expected aligned native uint8 RGB/predicted mask')
    if not np.isfinite(font_pixels) or font_pixels <= 0:
        raise ValueError('Invalid source font scale')
    result = dict(version=VERSION, identified=False, primaryWidthPx=None, sourceOnly=True,
                  GTAtInference=False, contextExpanded=False, nativeWitnesses=True,
                  semantics='Single first primary paint band with half adjacent transitions; never sum of rings',
                  attemptedRays=0, acceptedRays=0, censoring={}, components=[], sectors=[], summary=_summary([]))
    if not outline_present:
        return dict(result, reason='predicted-outline-absent')
    image_lab = cv2.cvtColor(rgb.astype(np.float32) / 255, cv2.COLOR_RGB2LAB)
    fill, primary = _lab([fill_rgb, primary_rgb])
    contrast = float(np.linalg.norm(fill - primary))
    if contrast < POLICY['minimumFillPrimaryContrastLAB']:
        return dict(result, reason='fill-primary-not-separated')
    ftol = min(POLICY['maximumFillToleranceLAB'], contrast * .3)
    otol = min(POLICY['maximumPrimaryToleranceLAB'], contrast * .3)
    core = (np.linalg.norm(image_lab - fill, axis=2) <= ftol) & predicted_mask.astype(bool)
    seeds = np.ones(core.shape, np.uint8)
    if polygons:
        seeds[:] = 0
        cv2.fillPoly(seeds, [np.rint(p).astype(np.int32) for p in polygons], 1)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(core.astype(np.uint8), connectivity=8)
    seeded = np.bincount(labels[seeds.astype(bool)], minlength=count)
    ids = sorted([i for i in range(1, count) if stats[i, 4] >= POLICY['minimumComponentPixels'] and seeded[i] >= 3],
                 key=lambda i: (-stats[i, 4], i))[:POLICY['maxComponents']]
    if not ids:
        return dict(result, reason='no-owned-fill-components')
    selected_core = np.isin(labels, ids)
    inside = cv2.distanceTransform(selected_core.astype(np.uint8), cv2.DIST_L2, 5)
    outside = cv2.distanceTransform((~selected_core).astype(np.uint8), cv2.DIST_L2, 5)
    gy, gx = np.gradient(cv2.GaussianBlur(inside - outside, (0, 0), POLICY['normalSmoothSigma']))
    edge = selected_core & ~cv2.erode(selected_core.astype(np.uint8), np.ones((3, 3), np.uint8)).astype(bool)
    depth = max(POLICY['depthMinimumPx'], min(POLICY['depthMaximumPx'], int(np.ceil(font_pixels * POLICY['depthFontFraction']))))
    records, reasons = [], Counter()
    for identity in ids:
        y, x = np.where(edge & (labels == identity))
        norm = np.hypot(gx[y, x], gy[y, x])
        valid = norm > .2
        y, x, norm = y[valid], x[valid], norm[valid]
        normals = np.column_stack([-gx[y, x] / norm, -gy[y, x] / norm])
        # Equal angle-sector budget avoids dense flat sides dominating all samples.
        sectors = (np.floor((np.arctan2(normals[:, 1], normals[:, 0]) + np.pi) / (np.pi / 4)).astype(int)) % 8
        chosen = []
        for sector in range(8):
            candidates = np.flatnonzero(sectors == sector)
            chosen.extend(candidates[np.linspace(0, len(candidates) - 1, min(6, len(candidates))).astype(int)].tolist() if len(candidates) else [])
        local, local_reasons = [], Counter()
        for k in chosen:
            result['attemptedRays'] += 1
            record, reason = _ray(rgb, image_lab, labels, identity, np.array([x[k], y[k]], float), normals[k], depth, fill, primary, ftol, otol)
            if record is None:
                reasons[reason] += 1
                local_reasons[reason] += 1
            else:
                record['component'] = int(identity)
                local.append(record)
                records.append(record)
        result['components'].append(dict(component=int(identity), nativeFillPixels=int(stats[identity, 4]),
            attemptedRays=len(chosen), censoring=dict(local_reasons), summary=_summary(local),
            sectors=[dict(sector=k, **_summary([r for r in local if r['sector'] == k])) for k in range(8)]))
    result.update(acceptedRays=len(records), censoring=dict(reasons), summary=_summary(records), sourceDepthPx=depth,
                  sectors=[dict(sector=k, **_summary([r for r in records if r['sector'] == k])) for k in range(8)])
    # Equal component medians: a large glyph does not erase repeated small glyph evidence.
    medians = [c['summary']['medianPx'] for c in result['components'] if c['summary']['n'] >= 3]
    supported_sectors = sum(s['n'] >= 2 for s in result['sectors'])
    result['supportedSectors'] = supported_sectors
    result['measuredComponents'] = len(medians)
    result['componentMedianIQR'] = float(np.ptp(np.quantile(medians, [.25, .75]))) if medians else 0.
    result['medianExteriorContrastLAB'] = float(np.median([r['exteriorContrastLAB'] for r in records])) if records else 0.
    result['medianTransitionSpanPx'] = float(np.median([r['transitionSpanPx'] for r in records])) if records else 0.
    result['identified'] = len(records) >= POLICY['minimumAcceptedRays'] and supported_sectors >= POLICY['minimumSectors'] and bool(medians)
    result['primaryWidthPx'] = float(np.median(medians)) if result['identified'] else None
    result['reason'] = 'repeated-observed-primary-band' if result['identified'] else 'insufficient-repeatable-finite-exits'
    # Small reproducible witness budget; summaries retain all accepted measurements.
    result['witnessRays'] = records[:8]
    return result


REASONS = ['outside-crop', 'no-native-fill-anchor', 'no-adjacent-primary-core', 'unstable-fill-boundary',
           'unresolved-fill-primary-transition', 'other-fill-component', 'fill-return-or-concavity',
           'unresolved-primary-exterior-gap', 'unresolved-primary-exterior-transition', 'nonpositive-band',
           'outside-crop-before-exit', 'depth-without-observed-exit']


def features(evidence, font):
    e = evidence
    attempts = max(1, e['attemptedRays'])
    s = e['summary']
    width = float(e['primaryWidthPx'] or 0.)
    vector = [float(e['identified']), width, width / max(1, font), np.log1p(e['attemptedRays']),
              e['acceptedRays'] / attempts, float(e.get('measuredComponents', 0)), float(e.get('supportedSectors', 0)),
              s['medianPx'], s['p25Px'], s['p75Px'], s['MADPx'], float(e.get('componentMedianIQR', 0)),
              float(e.get('medianExteriorContrastLAB', 0)), float(e.get('medianTransitionSpanPx', 0))]
    vector += [e['censoring'].get(reason, 0) / attempts for reason in REASONS]
    for sector in range(8):
        summary = next((v for v in e['sectors'] if v['sector'] == sector), dict(n=0, medianPx=0., MADPx=0.))
        vector += [summary['n'] / attempts, summary['medianPx'], summary['MADPx']]
    return np.asarray(vector, float)
