"""Bounded diagnostic only: observed outer paint, local baselines and normal asymmetry.

The inference function accepts native source arrays and predicted styles, never IDs,
GT colours, pages, labels, or a scalar outline width. No production entrypoint imports it.
"""
import cv2
import numpy as np
from scipy.ndimage import distance_transform_edt
from scipy.special import ndtr
from source_appearance import lab
from source_profile_sampling import sample_source

VERSION = 'observed-shadow-boundary-v2'
POLICY = dict(maxComponents=12, raysPerComponent=8, exteriorPixels=24,
              colourToleranceLAB=10, baselineSpreadLAB=4, minimumComponents=3,
              minimumSectors=2, minimumExplained=.35, minimumGain=.05,
              minimumAttenuation=.03, maximumNeutralSpread=.15,
              sigmas=[1., 2., 3.], spatialControl='last occupied horizontal half',
              rgbStratumLAB=12, rgbMaximumSpreadLAB=10,
              bodyBridge='native RGB antialias between adjacent predicted paint colours',
              ownership='positive RF owner support; nested frame is not a text competitor',
              baselineWindow='first observed stable six-pixel plateau after at least two exterior samples; max24',
              minimumExteriorSamples=8, minimumBackgroundNormals=2,
              missingBackground='censor control only; require independent rank2 finite background normals',
              componentOwnership='nearest independently supported fill-core seed; full native union contour only')


def _validate(rgb, mask, rf, primary, boundary, ocr, font):
    h, w = mask.shape
    if rgb.shape != (h, w, 3) or rgb.dtype != np.uint8:
        raise ValueError('Expected aligned native uint8 RGB')
    for a, shape in [(rf, (h, w, 27)), (primary, (h, w)),
                     (boundary, (h, w)), (ocr, (h, w, 8))]:
        if a.shape != shape or not np.isfinite(a).all():
            raise ValueError('Missing, unaligned or nonfinite source evidence')
    for a in [primary, boundary, ocr]:
        if a.min() < 0 or a.max() > 1.001:
            raise ValueError('Probability outside source contract')
    if not np.isfinite(font) or font <= 0:
        raise ValueError('Invalid native font scale')


def observed_body(rgb, mask, prediction, rf, primary, boundary, ocr, polygons):
    """All predicted paint colours, connected to independently supported seeds.

    Segmentation/RF/OCR seed ownership; they do not hard clip exterior rays.
    No dilation by an estimated outline width, and no global background matching.
    """
    il = cv2.cvtColor(rgb.astype(np.float32) / 255, cv2.COLOR_RGB2LAB)
    colors = [prediction['fill'].get('rgb')] + prediction['fill'].get('colors', [])
    outline = prediction.get('outline', {})
    if outline.get('present'):
        colors += [outline.get('rgb')]
        colors += [r.get('rgb') for r in outline.get('layers', []) if isinstance(r, dict)]
    paint = np.zeros(mask.shape, bool)
    endpoint_masks = []
    endpoint_colors = []
    for color in colors:
        if color is not None:
            matched = np.linalg.norm(il - lab([color])[0], axis=2) <= POLICY['colourToleranceLAB']
            endpoint_masks.append(matched); endpoint_colors.append(np.asarray(color, float))
            paint |= matched
    # At-most-two-pixel antialias bridges need BOTH observed endpoint colours nearby.
    # A generic black/white colour segment alone would swallow gray background.
    bridge = np.zeros(mask.shape, bool)
    dilated = [cv2.dilate(m.astype(np.uint8), np.ones((5, 5), np.uint8)).astype(bool) for m in endpoint_masks]
    for i, a in enumerate(endpoint_colors):
        for j in range(i):
            b = endpoint_colors[j]; delta = b - a; norm = float(delta @ delta)
            if norm < 1:
                continue
            nearby = dilated[i] & dilated[j] & ~paint
            yy, xx = np.where(nearby)
            pixel = rgb[yy, xx].astype(float)
            alpha = np.clip(((pixel - a) @ delta) / norm, 0, 1)
            distance = np.linalg.norm(pixel - a - alpha[:, None] * delta, axis=1)
            bridge[yy[distance <= 12], xx[distance <= 12]] = True
    paint |= bridge
    support = np.zeros(mask.shape, np.uint8)
    for p in polygons:
        cv2.fillPoly(support, [np.rint(p).astype(np.int32)], 1)
    # RF owner mask*affinity for text/SFX, compared with competing owner queries.
    owner = np.maximum(rf[:, :, 15] * rf[:, :, 16], rf[:, :, 17] * rf[:, :, 18])
    # Frame/balloon evidence can co-occur with text on the SAME background.
    # Their affinities must not veto a text seed (the v1 control failure).
    rf_ok = owner >= .001
    ocr_ok = (ocr[:, :, 0] > 0) & ((ocr[:, :, 1] == 0) | (ocr[:, :, 2] >= .2))
    ocr_ok &= (ocr[:, :, 3] == 0) | (ocr[:, :, 4] >= .2)
    ocr_ok &= (ocr[:, :, 5] == 0) | (ocr[:, :, 6] >= .1)
    seed = mask.astype(bool) & (np.maximum(primary, boundary) >= .25) & rf_ok & ocr_ok & (support > 0)
    # Native paint and soft support trace the outer contour outside the seed
    # mask too. A connected body is partitioned by cores, never clipped to boxes.
    candidate = paint & (mask.astype(bool) | (np.maximum(primary, boundary) >= .25))
    n, labels = cv2.connectedComponents(candidate.astype(np.uint8), connectivity=8)
    accepted = np.unique(labels[seed & candidate]); accepted = accepted[accepted > 0]
    body = np.isin(labels, accepted)
    return body, dict(candidateComponents=n - 1, ownedPaintComponents=len(accepted),
                      seedPixels=int((seed & candidate).sum()), antialiasBridgePixels=int(bridge.sum()),
                      frameVetoUsed=False,
                      ownerAffinityMedian=float(np.median(owner[seed])) if seed.any() else None)


def _profile(rgb, body, point, normal):
    t = np.arange(1, 25, dtype=np.float32)
    xy = point[None, :] + t[:, None] * normal
    values, valid = sample_source(rgb, xy[:, 0][None, :], xy[:, 1][None, :])
    # A float remap avoids uint8 rounding away partial own-outline occupancy.
    occupied, _ = sample_source(body.astype(np.float32), xy[:, 0][None, :], xy[:, 1][None, :])
    valid = valid[0]; occupied = occupied[0] >= .5
    # Treat the first transition separately from later paint. Up to two native
    # samples can still be the same observed contour at a slanted raster edge.
    prefix = 0
    while prefix < 2 and valid[prefix] and occupied[prefix]:
        prefix += 1
    usable = valid & ~occupied
    usable[:prefix] = False
    if prefix == 2 and occupied[2]:
        return None, 'unresolved-own-contour'
    obstacles = np.flatnonzero(~usable & (np.arange(24) >= prefix))
    end = int(obstacles[0]) if len(obstacles) else 24
    if end - prefix < POLICY['minimumExteriorSamples']:
        return None, 'neighbor-before-local-baseline' if occupied[prefix:end+1].any() else 'crop-before-local-baseline'
    values = values[0].astype(np.float32)
    baseline = None
    # Six contiguous finite, paint-free native samples beyond the fringe.
    for start in range(prefix + 2, end - 5):
        block = values[start:start+6]; reference = np.median(block, axis=0)
        spread = float(np.max(np.linalg.norm(lab(block) - lab([reference])[0], axis=1)))
        if spread <= POLICY['baselineSpreadLAB']:
            baseline = (start, reference, spread); break
    if baseline is None:
        return None, 'unstable-or-missing-local-baseline'
    start, reference, spread = baseline
    weights = np.zeros(24, np.float32); weights[prefix:start+6] = 1
    ratios = (reference - values) / np.maximum(reference, 32)
    neutral = np.ptp(ratios, axis=1) <= POLICY['maximumNeutralSpread']
    if not neutral[prefix:start].all():
        return None, 'non-attenuation-colour-change'
    data = np.clip(np.median(ratios, axis=1), 0, .95) * weights
    coordinates = np.rint(xy).astype(int)
    witness = np.zeros((24, 3), np.uint8)
    witness[valid] = rgb[coordinates[valid, 1], coordinates[valid, 0]]
    return dict(data=data, weights=weights, distances=t-prefix, reference=reference, spread=spread,
                witness=witness, coordinates=coordinates, baselineIndices=list(range(start,start+6)),
                ownPrefixPixels=prefix, exteriorObservedSamples=int(weights.sum())), None


def _pseudo_origin(body, point, normal):
    """Choose one matched pseudo-ray by occupancy/finite geometry, never RGB score.

    A fixed outward48px footprint invalidated narrow native crops. Prefer nearby
    free tangential exterior, with outward alternatives when adjacent glyphs block.
    Exactly ONE pseudo RGB ray is sampled after this geometry-only choice.
    """
    tangent = np.array([-normal[1], normal[0]])
    candidates = [point+24*tangent, point-24*tangent, point+24*normal,
                  point+12*normal+24*tangent, point+12*normal-24*tangent]
    ranked = []
    for index, origin in enumerate(candidates):
        x,y = np.rint(origin).astype(int)
        if not (0<=x<body.shape[1] and 0<=y<body.shape[0]) or body[y,x]:
            continue
        coords=np.rint(origin+np.arange(1,25)[:,None]*normal).astype(int)
        valid=(coords[:,0]>=0)&(coords[:,0]<body.shape[1])&(coords[:,1]>=0)&(coords[:,1]<body.shape[0])
        occupied=np.ones(24,bool);occupied[valid]=body[coords[valid,1],coords[valid,0]]
        blocked=np.flatnonzero(occupied);clearance=int(blocked[0]) if len(blocked) else 24
        ranked.append((clearance,-index,origin))
    return max(ranked,key=lambda r:r[:2])[2] if ranked else None


def _grids(normals, data, radius, weights=None, distances=None):
    shifts = np.array([(x, y) for y in range(-radius, radius + 1)
                       for x in range(-radius, radius + 1)], np.float32)
    if weights is None:
        weights = np.ones_like(data)
    t = np.broadcast_to(np.arange(1, 25), data.shape) if distances is None else distances
    models = np.stack([ndtr((normals @ shifts.T)[:, :, None] - t[:, None, :]) if s == 1
                       else ndtr(((normals @ shifts.T)[:, :, None] - t[:, None, :]) / s)
                       for s in POLICY['sigmas']])
    # Nonnegative least-squares energy, common amplitude per component.
    dot = np.einsum('srkt,rt->sk', models, data * weights)
    energy = np.sum(weights * data * data)
    norm = np.sum(models * models * weights[None, :, None, :], axis=(1, 3))
    return np.clip(dot * dot / np.maximum(norm * energy, 1e-10), 0, 1)


def select_offset(scores, sectors, radius, background_scores):
    """Fit alternating components, validate alternation AND held-out spatial half."""
    out = dict(identified=False, offsetPx=None)
    if len(scores) < POLICY['minimumComponents'] or len(set(sectors)) < 2:
        return dict(out, reason='Insufficient usable components or spatial sectors')
    scores = np.asarray(scores); sectors = np.asarray(sectors)
    held = sectors == max(sectors)
    rest = np.flatnonzero(~held)
    train = rest[::2]; validation = rest[1::2]
    if not len(validation):
        return dict(out, reason='Insufficient alternating components outside held-out sector')
    best_sigma, position = np.unravel_index(np.argmax(scores[train].mean(0)), scores.shape[1:])
    side = 2 * radius + 1; iy, ix = divmod(position, side)
    dx, dy = ix - radius, iy - radius
    zero = radius * side + radius; opposite = (2 * radius - iy) * side + 2 * radius - ix
    selected = scores[:, best_sigma, position]
    baseline = scores[:, :, zero].max(1)
    reverse = scores[:, best_sigma, opposite]
    bg = np.asarray(background_scores)[:, best_sigma, position]
    checks = {}
    for name, indices in [('train', train), ('validation', validation), ('spatial', np.flatnonzero(held))]:
        checks[name] = dict(components=len(indices), selected=float(selected[indices].mean()),
                            zero=float(baseline[indices].mean()), opposite=float(reverse[indices].mean()),
                            background=float(bg[indices].mean()))
    interior = abs(dx) < radius and abs(dy) < radius and (dx != 0 or dy != 0)
    passed = interior and all(v['selected'] >= POLICY['minimumExplained'] and
                             min(v['selected'] - v[k] for k in ['zero', 'opposite', 'background']) >= POLICY['minimumGain']
                             for v in checks.values())
    return dict(out, identified=bool(passed), offsetPx=[dx, dy] if passed else None,
                candidateOffsetPx=[dx, dy], interiorOptimum=bool(interior), scores=checks,
                sigmaNuisancePx=POLICY['sigmas'][best_sigma],
                reason='Held-out observed boundary displacement' if passed else 'Failed interior/zero/opposite/background/spatial control')


def _colours(components):
    # Sequential deterministic background strata; no GT or nearest-label selection.
    strata = []
    for ci, c in enumerate(components):
        for ray in c['rays']:
            profile = ray['profile']; data = profile['data']
            if max(data[:12]) < POLICY['minimumAttenuation']:
                continue
            k = int(np.argmax(data[:12])); ref = lab([profile['reference']])[0]
            group = next((s for s in strata if np.linalg.norm(ref - s['referenceLAB']) <= POLICY['rgbStratumLAB']), None)
            if group is None:
                group = dict(referenceLAB=ref, samples=[], ids=[], coordinates=[]); strata.append(group)
            group['samples'].append(profile['witness'][k]); group['ids'].append(ci)
            group['coordinates'].append(profile['coordinates'][k].tolist())
    palette = []
    for s in sorted(strata, key=lambda s: (-len(set(s['ids'])), -len(s['ids']))):
        ids = sorted(set(s['ids']))
        if len(ids) < 3 or len({components[i]['sector'] for i in ids}) < 2:
            continue
        # Strong evidence must repeat in fit, alternation validation, spatial holdout.
        held = max(c['sector'] for c in components)
        rest = [i for i, c in enumerate(components) if c['sector'] != held]
        groups = [set(rest[::2]), set(rest[1::2]), {i for i, c in enumerate(components) if c['sector'] == held}]
        if not all(set(ids) & g for g in groups):
            continue
        pixels = np.asarray(s['samples']); ls = lab(pixels)
        index = int(np.argmin(np.linalg.norm(ls[:, None] - ls[None, :], axis=2).sum(1)))
        spread = float(np.quantile(np.linalg.norm(ls - ls[index], axis=1), .9))
        if spread <= POLICY['rgbMaximumSpreadLAB']:
            palette.append(dict(rgb=pixels[index].tolist(), nativeXY=s['coordinates'][index],
                                components=ids, samples=len(pixels), spreadLAB90=spread,
                                referenceLAB=s['referenceLAB'].tolist()))
    incompatible = any(np.linalg.norm(lab([a['rgb']])[0] - lab([b['rgb']])[0]) > 10
                       for a in palette for b in palette)
    return dict(rgb=palette[0]['rgb'] if palette and not incompatible else None,
                palette=palette, incompatibleModes=incompatible)


def estimate(rgb, mask, prediction, font_pixels, polygons, rf, primary, boundary, ocr):
    _validate(rgb, mask, rf, primary, boundary, ocr, font_pixels)
    result = dict(version=VERSION, identified=False, offsetPx=None, rgb=None, palette=[],
                  GTAtInference=False, contextExpanded=False, intrinsicRGB=None, opacity=None, blurRadiusPx=None)
    body, evidence = observed_body(rgb, mask, prediction, rf, primary, boundary, ocr, polygons)
    native_body_count = cv2.connectedComponents(body.astype(np.uint8), connectivity=8)[0] - 1
    il = cv2.cvtColor(rgb.astype(np.float32) / 255, cv2.COLOR_RGB2LAB)
    fill_match = np.zeros(mask.shape, bool)
    outline_color = prediction.get('outline', {}).get('rgb') if prediction.get('outline', {}).get('present') else None
    for color in [prediction['fill'].get('rgb')] + prediction['fill'].get('colors', []):
        if color is None or (outline_color is not None and np.linalg.norm(lab([color])[0]-lab([outline_color])[0]) <= 10):
            continue
        fill_match |= np.linalg.norm(il-lab([color])[0],axis=2) <= POLICY['colourToleranceLAB']
    core = fill_match & body
    n, core_labels, stats, centers = cv2.connectedComponentsWithStats(core.astype(np.uint8), connectivity=8)
    ids = sorted([i for i in range(1, n) if stats[i, 4] >= max(12, font_pixels ** 2 * .005)],
                 key=lambda i: (-stats[i, 4], i))[:12]
    # Every owner is a source core. Do NOT erode this ownership partition:
    # its internal Voronoi seams are not observed outer-body boundaries.
    _, nearest = distance_transform_edt(~core, return_indices=True)
    labels = core_labels[nearest[0], nearest[1]] if core.any() else np.zeros(mask.shape,int)
    native_edge = body & ~cv2.erode(body.astype(np.uint8), np.ones((3,3),np.uint8)).astype(bool)
    evidence.update(nativeBodyComponents=int(native_body_count), fillCoreComponents=n-1,
                    selectedFillCoreSeeds=len(ids), partitionCreatesContour=False)
    radius = min(12, max(3, round(.15 * font_pixels)))
    # Smooth signed-distance gradients give local normals on actual observed paint.
    signed = distance_transform_edt(~body) - distance_transform_edt(body)
    smooth = cv2.GaussianBlur(signed.astype(np.float32), (5, 5), 1)
    gy, gx = np.gradient(smooth)
    components = []; logs = []; censors = {}
    middle = float(np.median(centers[ids, 0])) if ids else 0
    for identity in ids:
        edge = native_edge & (labels == identity)
        ys, xs = np.where(edge); normals = np.column_stack((gx[ys, xs], gy[ys, xs]))
        normals /= np.maximum(np.linalg.norm(normals, axis=1)[:, None], 1e-8)
        rays = []; ray_logs = []; source_usable = 0
        for j in range(8):
            direction = np.array([np.cos(j * np.pi / 4), np.sin(j * np.pi / 4)])
            choices = np.flatnonzero(normals @ direction >= .9)
            if not len(choices):
                ray_logs.append(dict(direction=j,reason='no-native-outer-contour-for-owner'))
                continue
            xy = np.column_stack((xs, ys))
            clearance = []
            for ci in choices:
                coords = np.rint(xy[ci] + np.arange(1,25)[:,None]*normals[ci]).astype(int)
                inside = (coords[:,0]>=0)&(coords[:,0]<body.shape[1])&(coords[:,1]>=0)&(coords[:,1]<body.shape[0])
                occupied = np.ones(24, bool)
                occupied[inside] = body[coords[inside,1],coords[inside,0]]
                hits = np.flatnonzero(occupied)
                clearance.append(int(hits[0]) if len(hits) else 24)
            # Tangential centers avoid arbitrary contour corners with equal clearance.
            center = centers[identity]; projections = xy[choices] @ direction
            quality = np.asarray(clearance)*1000 + projections - .01*np.linalg.norm(xy[choices]-center,axis=1)
            k = choices[int(np.argmax(quality))]
            point = xy[k].astype(float); normal = normals[k]
            p, reason = _profile(rgb, body, point, normal)
            if p is None:
                reason='source:'+reason; censors[reason]=censors.get(reason,0)+1
                ray_logs.append(dict(direction=j,point=point.tolist(),sourceValid=False,reason=reason))
                continue
            source_usable += 1
            pseudo_point = _pseudo_origin(body, point, normal)
            pseudo, bg_reason = _profile(rgb, body, pseudo_point, normal) if pseudo_point is not None else (None,'no-finite-nontext-pseudo-origin')
            if pseudo is None:
                bg_reason='pseudo:'+bg_reason; censors[bg_reason]=censors.get(bg_reason,0)+1
            ray_logs.append(dict(direction=j,point=point.tolist(),sourceValid=True,
                                 backgroundValid=pseudo is not None,reason=bg_reason or 'paired-source-and-background-valid'))
            rays.append(dict(direction=j,point=point.tolist(),normal=normal,profile=p,pseudo=pseudo,
                             pseudoPoint=pseudo_point.tolist() if pseudo_point is not None else None))
        pairs = sum(any(r['direction'] == j for r in rays) and any(r['direction'] == j + 4 for r in rays) for j in range(4))
        background_rays=[r for r in rays if r['pseudo'] is not None]
        bg_rank=int(np.linalg.matrix_rank([r['normal'] for r in background_rays])) if background_rays else 0
        entry = dict(sourceComponent=int(identity), sourceUsableRays=source_usable, usableRays=len(rays), oppositePairs=pairs,
                     backgroundValidRays=len(background_rays),backgroundNormalRank=bg_rank,
                     rayLogs=ray_logs,
                     sector=int(centers[identity, 0] >= middle))
        logs.append(entry)
        if pairs < 2 or len(background_rays)<POLICY['minimumBackgroundNormals'] or bg_rank<2:
            continue
        normals = np.asarray([r['normal'] for r in rays]); data = np.asarray([r['profile']['data'] for r in rays])
        pseudo_data = np.asarray([r['pseudo']['data'] if r['pseudo'] is not None else np.zeros(24) for r in rays])
        signal = float(np.mean(data[:, :12])); bg_signal = float(np.mean([r['pseudo']['data'][:12] for r in background_rays]))
        entry.update(nearAttenuation=signal, backgroundAttenuation=bg_signal)
        weights = np.asarray([r['profile']['weights'] for r in rays])
        distances = np.asarray([r['profile']['distances'] for r in rays])
        bgweights = np.asarray([r['pseudo']['weights'] if r['pseudo'] is not None else np.zeros(24) for r in rays])
        bgdistances = np.asarray([r['pseudo']['distances'] if r['pseudo'] is not None else np.arange(1,25) for r in rays])
        components.append(dict(rays=rays, sector=entry['sector'], score=_grids(normals, data, radius, weights, distances),
                               bgScore=_grids(normals, pseudo_data, radius, bgweights, bgdistances), signal=signal,
                               bgSignal=bg_signal))
    selected = select_offset([c['score'] for c in components], [c['sector'] for c in components], radius,
                             [c['bgScore'] for c in components])
    result.update(selected, bodyEvidence=evidence, components=len(components), sourceComponentLogs=logs,
                  usableRays=sum(len(c['rays']) for c in components), sourceUsableRays=sum(x['sourceUsableRays'] for x in logs),
                  pairedValidRays=sum(x['backgroundValidRays'] for x in logs), censoring=censors, searchRadiusPx=radius)
    colour_ok = len(components) >= 3 and all(c['signal'] >= .015 and c['signal'] >= 2 * c['bgSignal'] + .005 for c in components)
    color = _colours(components) if colour_ok else dict(rgb=None, palette=[], incompatibleModes=False)
    result.update(color, rgbOwnershipPassed=bool(colour_ok),
                  rgbReason='Repeated native fringe in local stratum' if color['rgb'] is not None else 'Unresolved ownership/repetition or incompatible local modes')
    # Compact exact ray evidence, including all finite native baseline witnesses.
    result['profiles'] = [dict(sector=c['sector'], rays=[dict(point=r['point'], normal=r['normal'].tolist(),
        attenuation=r['profile']['data'].tolist(), baselineRGB=r['profile']['reference'].tolist(),
        baselineSpreadLAB=r['profile']['spread'], weights=r['profile']['weights'].tolist(),
        baselineIndices=r['profile']['baselineIndices'], ownPrefixPixels=r['profile']['ownPrefixPixels'],
        pseudoPoint=r['pseudoPoint'],
        pseudoBaselineRGB=r['pseudo']['reference'].tolist() if r['pseudo'] is not None else None,
        pseudoWeights=r['pseudo']['weights'].tolist() if r['pseudo'] is not None else None, nativeXY=r['profile']['coordinates'].tolist(),
        nativeRGB=r['profile']['witness'].tolist(), pseudoAttenuation=r['pseudo']['data'].tolist() if r['pseudo'] is not None else None) for r in c['rays']]) for c in components]
    return result
