"""Write actual source-predicted masks, then independently score persisted PNGs."""
import argparse
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import numpy as np
from PIL import Image

import audit_joint_mask_refinement as joint
from audit_kernel_free_completion import metrics
from evaluate_gt import read, save, sha

CONFIG = None
OUTPUT = None
AUXILIARY = None


def initialize(root, model, cache, config, output):
    global CONFIG, OUTPUT, AUXILIARY
    CONFIG, OUTPUT = config, Path(output)
    joint.initialize(root, model, cache)
    if config.get('auxiliaryPixelGate'):
        import joblib
        import train_oof_style_pixel as oof
        from compiled_point_predict import CompiledPointPredictor
        gate = config['auxiliaryPixelGate']
        if sha(gate['modelPath']) != gate['modelSHA256']:
            raise ValueError('Auxiliary pixel model changed')
        oof.initialize(root)
        AUXILIARY = CompiledPointPredictor(joblib.load(gate['modelPath']))


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


def write_and_measure(row):
    from audit_style_calibration import style_features
    import train_point_recovery as point
    inputs = {k: row[k] for k in ['id', 'rgb', 'rf', 'width', 'height', 'polygons', 'fontPixels']}
    base, distance, group, codes = joint.source_predictions(inputs)
    p, q, _ = point.CONTEXT[2].load(inputs)
    rgb = np.fromfile(row['rgb'], np.uint8).reshape(row['height'], row['width'], 3)
    case = read(joint.STATE['root'] / 'boundary-lean/rf-full/crops' / (row['id'] + '.json'))
    values = style_features(rgb, base, distance, p, q, row['fontPixels'], case)
    predicted = refine_source_mask(base, distance, group, codes, CONFIG, values, row['fontPixels'], rgb, (p, q))
    if CONFIG.get('auxiliaryPixelGate'):
        import train_oof_style_pixel as oof
        gate = CONFIG['auxiliaryPixelGate']
        strength = np.minimum(64, np.ceil(np.maximum(p, q) * 64 - 1e-6)).astype(np.int32)
        positions = np.flatnonzero(((predicted > 0) & (strength <= gate['maximumSourceStrengthCode'])).ravel())
        features = oof.inference_features(inputs)
        probabilities = AUXILIARY.probabilities(features, positions)
        odds = np.log(np.maximum(probabilities, 1e-12)) - np.log(np.maximum(1 - probabilities, 1e-12))
        quantized = np.clip(np.floor((odds + 24) * joint.BINS / 48), 0, joint.BINS - 1).astype(np.uint16)
        predicted.ravel()[positions[quantized < gate['thresholdCode']]] = 0
    output = OUTPUT / (row['id'] + '.png')
    Image.fromarray(predicted).save(output)
    # Targets are first opened after the actual output image has been written.
    if sha(row['target']) != row['targetSHA256']:
        raise ValueError('GT changed')
    actual = np.asarray(Image.open(output)) > 0
    gt = np.asarray(Image.open(row['target'])) > 0
    counts = np.array([np.count_nonzero(actual & gt), np.count_nonzero(actual & ~gt),
                       np.count_nonzero(~actual & gt)], np.int64)
    return row['split'], counts


def main():
    parser = argparse.ArgumentParser()
    for name in ['root', 'model', 'cache', 'report', 'out']:
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--selection', default='allRecall99999')
    parser.add_argument('--jobs', type=int, default=8)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    selected = read(args.report)[args.selection]
    if selected is None:
        raise ValueError('No selected policy')
    rows = read(args.root / 'boundary-lean/evaluation-manifest.json')['items']
    counts = {s: np.zeros(3, np.int64) for s in ['train', 'dev', 'test']}
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=initialize,
                             initargs=(args.root.resolve(), args.model.resolve(), args.cache.resolve(),
                                       selected, args.out.resolve())) as pool:
        for i, (split, c) in enumerate(pool.map(write_and_measure, rows, chunksize=8)):
            counts[split] += c
            if (i + 1) % 1000 == 0:
                print(f'Actual mask replay {i + 1}/{len(rows)}', flush=True)
    actual = dict(all=metrics(sum(counts.values())), bySplit={s: metrics(c) for s, c in counts.items()})
    if actual['all'] != selected['all'] or actual['bySplit'] != selected['bySplit']:
        raise ValueError('Actual persisted masks do not match calibration counts')
    save(args.out / 'VERIFIED-RESULT.json', dict(**actual, actualMasksWritten=len(rows),
         independentReadback=True, expectedCountsMatched=True, GTAtInference=False,
         GTChanged=False, productionEnabled=False, selection=args.selection,
         selectionReportSHA256=sha(args.report), modelSHA256=sha(args.model)))
    print(actual, flush=True)


if __name__ == '__main__':
    main()
