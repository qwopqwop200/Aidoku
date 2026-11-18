"""Frozen selected source-only numerical functions; generated without changing bodies."""
import cv2
import numpy as np
from types import SimpleNamespace
joint = SimpleNamespace(BINS=8192, RADIUS=12)
RING_NAMES = ["ringLuminanceStd", "ringLuminanceRange90", "ringChromaMean", "ringRGBStd",
              "ringGradientMean", "ringGradientFraction", "ringNonwhiteFraction"]
EDGE_NAMES = ["rgbEdgeDistance8RelativeFont", "rgbEdgeDistance32RelativeFont",
              "rgbEdgeDistance64RelativeFont", "rgbRange3", "rgbRangeMeanFontHalf"]

def component_candidates(mask):
    contours,_=cv2.findContours(mask,cv2.RETR_EXTERNAL,cv2.CHAIN_APPROX_SIMPLE)
    holes=np.zeros_like(mask);hulls=np.zeros_like(mask);boxes=np.zeros_like(mask)
    cv2.drawContours(holes,contours,-1,255,cv2.FILLED)
    for contour in contours:
        cv2.fillConvexPoly(hulls,cv2.convexHull(contour),255)
        x,y,w,h=cv2.boundingRect(contour);boxes[y:y+h,x:x+w]=255
    whole=np.zeros_like(mask)
    if contours:
        x,y,w,h=cv2.boundingRect(np.concatenate(contours));whole[y:y+h,x:x+w]=255
    return dict(baseline=mask,fillHoles=holes,componentConvexHull=hulls,componentBounds=boxes,sourceForegroundBounds=whole)

def style_features(rgb, base, distance, p, q, font, rf_case):
    """All crop statistics come from source predictions and RGB, not GT masks."""
    rgb = rgb.astype(np.float32) / 255
    luma = rgb[:, :, 0] * .2126 + rgb[:, :, 1] * .7152 + rgb[:, :, 2] * .0722
    ring = (distance > 0) & (distance <= max(3, min(12, font * .1)))
    if ring.any():
        gradient = cv2.dilate(luma, np.ones((3, 3), np.uint8)) - cv2.erode(luma, np.ones((3, 3), np.uint8))
        colors, light = rgb[ring], luma[ring]
        values = [light.std(), np.quantile(light, .95) - np.quantile(light, .05),
                  (colors.max(axis=1) - colors.min(axis=1)).mean(), colors.std(axis=0).max(),
                  gradient[ring].mean(), (gradient[ring] > .1).mean(), (light < .95).mean()]
    else:
        values = [0.] * len(RING_NAMES)
    seed = (p >= .5) & (q >= .3)
    if not seed.any():
        seed = base
    if seed.any():
        colors, light = rgb[seed], luma[seed]
        values += [light.mean(), light.std(), (colors.max(axis=1) - colors.min(axis=1)).mean(),
                   (light < .25).mean(), (light > .75).mean()]
    else:
        values += [0.] * 5
    values += [min(1., font / 128)] + rf_case['affinityScores']
    return np.asarray(values, np.float64)

def context_features(features, base, font):
    """Source-only spatial/color evidence; never accepts labels or GT paths."""
    h, w = base.shape
    planes = features.reshape(h, w, -1)
    font = max(1., float(font))
    p, q = planes[:, :, 0], planes[:, :, -1]
    extra, names = [], []
    for size in [3, 7, 15, max(3, min(65, int(round(font * .25)) | 1))]:
        for source, label in [(q, 'boundary'), (base.astype(np.float32), 'base')]:
            extra.extend([cv2.dilate(source, np.ones((size, size), np.uint8)),
                          cv2.boxFilter(source, -1, (size, size), borderType=cv2.BORDER_REPLICATE)])
            suffix = str(size) if len(names) < 24 else 'FontQuarter'
            names.extend([label + 'Max' + suffix, label + 'Mean' + suffix])
    for threshold in [.1, .5]:
        distance = cv2.distanceTransform((q < threshold).astype(np.uint8), cv2.DIST_L2, 5)
        extra.append(np.minimum(distance / font, 1.))
        names.append('boundaryRelativeDistance' + str(threshold))
    seed = (p >= .75) & (q >= .5)
    if not seed.any():
        seed = (p >= .25) | (q >= .25)
    rgb = planes[:, :, 2:5]
    if seed.any():
        distance, labels = cv2.distanceTransformWithLabels((~seed).astype(np.uint8), cv2.DIST_L2,
                                                        5, labelType=cv2.DIST_LABEL_PIXEL)
        colors = np.vstack([np.zeros((1, 3), np.float32), rgb[seed]])
        if int(labels.max()) >= len(colors):
            raise ValueError('Unexpected nearest-source seed labels')
        delta = np.abs(rgb - colors[labels])
        relative = np.minimum(distance / font, 1.)
    else:
        delta = np.ones_like(rgb)
        relative = np.ones(base.shape, np.float32)
    extra.extend([relative, delta.max(axis=2), delta.mean(axis=2)])
    names.extend(['nearestConsensusDistanceRelativeFont', 'nearestConsensusRGBMaxDifference',
                  'nearestConsensusRGBMeanDifference'])
    outside = cv2.distanceTransform((~base).astype(np.uint8), cv2.DIST_L2, 5)
    extra.append(np.minimum(outside / font, 1.))
    names.append('baseDistanceRelativeFont')
    return np.concatenate([features, np.stack(extra, axis=2).reshape(-1, len(extra))], axis=1), names

def edge_features(rgb,font):
    font=max(1,float(font));gradient=rgb_gradient(rgb).astype(np.float32)/np.float32(255)
    size=max(3,min(257,int(round(font*.5))|1))
    planes=[np.minimum(edge_distances(rgb,t).astype(np.float64)/font,1).astype(np.float32) for t in [8,32,64]]
    planes.extend([gradient,cv2.boxFilter(gradient,-1,(size,size),borderType=cv2.BORDER_REPLICATE)])
    return np.stack(planes,axis=2).reshape(-1,len(EDGE_NAMES))

def edge_distances(rgb,threshold):
    kernel=np.ones((3,3),np.uint8)
    high=cv2.dilate(rgb,kernel,borderType=cv2.BORDER_REPLICATE)
    low=cv2.erode(rgb,kernel,borderType=cv2.BORDER_REPLICATE)
    edge=np.max(high-low,axis=2)>=threshold
    if not edge.any():return np.full(edge.shape,65534,np.int32)
    return np.minimum(cv2.distanceTransform((~edge).astype(np.uint8),cv2.DIST_L1,3),65534).astype(np.int32)

def rgb_gradient(rgb):
    kernel=np.ones((3,3),np.uint8)
    return np.max(cv2.dilate(rgb,kernel,borderType=cv2.BORDER_REPLICATE)-
                  cv2.erode(rgb,kernel,borderType=cv2.BORDER_REPLICATE),axis=2)

def infer(base, distance, group, codes, config):
    domain = base | (distance <= joint.RADIUS)
    if np.any(codes[domain] >= joint.BINS):
        raise ValueError('Uncomputed score inside inference domain')
    protection = config['protection']
    if protection == 'anyStrong':
        protected = group >= 1
    elif protection == 'consensus':
        protected = group == 2
    elif protection == 'none':
        protected = np.zeros(base.shape, bool)
    else:
        raise ValueError('Unknown protection policy')
    retained = base & (protected | (codes >= config['interiorThresholdCode']))
    additions = (~base) & (distance <= config['outerRadiusPixels']) & (
        (distance <= config['coreRadiusPixels']) | (codes >= config['exteriorThresholdCode']))
    return (retained | additions).astype(np.uint8) * 255

def refine_source_mask(base, distance, group, codes, CONFIG, values, font, rgb=None, source_votes=None):
    """Pure source-only refinement; no item identities or target arguments."""
    if 'confidenceRecovery' in CONFIG:
        import cv2
        policy = CONFIG['confidenceRecovery']
        strong = refine_source_mask(base, distance, group, codes, policy['strong'], values, font, rgb, source_votes) > 0
        weak = refine_source_mask(base, distance, group, codes, policy['weak'], values, font, rgb, source_votes) > 0
        if not strong.any():
            return weak.astype(np.uint8) * 255
        kind = {'chebyshev': cv2.DIST_C, 'manhattan': cv2.DIST_L1, 'euclidean': cv2.DIST_L2}[policy['metric']]
        size = cv2.DIST_MASK_PRECISE if kind == cv2.DIST_L2 else 3
        support = cv2.distanceTransform((~strong).astype(np.uint8), kind, size)
        addition = weak & (support <= policy['radiusPixels'])
        if policy.get('weakSignalGate'):
            from boundary_uniformity_dense import rgb_gradient
            if rgb is None:
                raise ValueError('RGB source required for weak-signal gate')
            gate = policy['weakSignalGate']
            signal = rgb_gradient(rgb)
            radius = gate['radiusPixels']
            if radius:
                signal = cv2.dilate(signal, np.ones((2 * radius + 1, 2 * radius + 1), np.uint8))
            supported_signal = signal >= gate['minimumContrast']
            if policy.get('sourceCorroboration'):
                if source_votes is None:
                    raise ValueError('Authenticated source votes required')
                corroboration = policy['sourceCorroboration']
                reference = strong if corroboration['neighborReference'] == 'strong' else (strong | (addition & supported_signal))
                neighbors = cv2.filter2D(reference.astype(np.uint8), cv2.CV_16U, np.ones((3, 3), np.uint8),
                                        borderType=cv2.BORDER_CONSTANT)
                p, q = source_votes
                pv, qv = np.rint(p * 64).astype(np.int32), np.rint(q * 48).astype(np.int32)
                supported_signal |= (neighbors >= corroboration['minimumNeighbors']) | (
                    pv >= corroboration['minimumPrimaryVotes']) | (qv >= corroboration['minimumBoundaryVotes'])
            addition &= supported_signal
        return (strong | addition).astype(np.uint8) * 255
    if 'ensembleMembers' in CONFIG:
        votes = sum((refine_source_mask(base, distance, group, codes, member, values, font, rgb, source_votes) > 0).astype(np.uint8)
                    for member in CONFIG['ensembleMembers'])
        return (votes >= CONFIG['requiredVotes']).astype(np.uint8) * 255
    config = CONFIG
    if 'styleFeatureIndex' in CONFIG or 'styleFeatureIndices' in CONFIG or 'styleCalibration' in CONFIG:
        if 'styleCalibration' in CONFIG:
            from audit_linear_style_calibration import normalized_features
            model = CONFIG['styleCalibration']
            features = normalized_features(values[None, :], np.array(model['mean']), np.array(model['scale']))
            offset = int(np.rint(float(features[0] @ np.array(model['coefficients'])) * joint.BINS / 48))
        elif 'styleFeatureIndices' in CONFIG:
            indices = CONFIG['styleFeatureIndices']
            groups = [int(np.searchsorted(bounds, values[index], side='right'))
                      for index, bounds in zip(indices, CONFIG['boundariesByFeature'])]
            band = groups[0] if len(groups) == 1 else groups[0] * CONFIG['groupShape'][1] + groups[1]
            if 'exteriorThresholds' in CONFIG:
                config = dict(CONFIG, exteriorThresholdCode=CONFIG['exteriorThresholds'][band])
                offset = 0
            else:
                offset = CONFIG['offsets'][band]
        else:
            band = int(np.searchsorted(CONFIG['boundaries'], values[CONFIG['styleFeatureIndex']], side='right'))
            offset = CONFIG['offsets'][band]
        codes = codes.copy()
        eligible = (base | (distance <= joint.RADIUS)) if CONFIG.get('styleApplyToInterior') else (
            (~base) & (distance <= joint.RADIUS))
        codes[eligible] = np.clip(codes[eligible].astype(np.int32) + offset, 0, joint.BINS - 1)
    predicted = infer(base, distance, group, codes, config)
    if CONFIG.get('confidenceSupport'):
        import cv2
        policy = CONFIG['confidenceSupport']
        weak = infer(base, distance, group, codes, dict(config,
            exteriorThresholdCode=config['exteriorThresholdCode'] + policy['weakExteriorDelta'])) > 0
        strong = infer(base, distance, group, codes, dict(config,
            coreRadiusPixels=policy['strongCoreRadiusPixels'],
            interiorThresholdCode=config['interiorThresholdCode'] + policy['strongInteriorDelta'],
            exteriorThresholdCode=config['exteriorThresholdCode'] + policy['strongExteriorDelta'])) > 0
        if np.any(strong & ~weak):
            raise ValueError('Strong support is not nested in weak prediction')
        if strong.any():
            radius = policy['radius']
            pixels = int(radius) if isinstance(radius, int) else max(1, min(12,
                int(np.ceil(font * float(radius[4:])))))
            support = cv2.distanceTransform((~strong).astype(np.uint8), cv2.DIST_C, 3)
            weak &= support <= pixels
        predicted = weak.astype(np.uint8) * 255
    if CONFIG.get('finalMaskPostprocess'):
        from audit_final_mask_closing import finish_mask
        predicted = finish_mask(predicted, CONFIG['finalMaskPostprocess'])
    return predicted

