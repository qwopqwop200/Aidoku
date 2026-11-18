"""Source-only final secondary-band replay; evaluation never enters workers."""
import argparse
import copy
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path

import numpy as np
from PIL import Image

from optimize_appearance import read, save, digest, assign_splits
from apply_gradient_contour import process_one as primary_process, source_request
from source_outer_shell import refine, restore_baseline
from source_outer_shell_policy import make_policy, validate_policy, MODEL_NAMES, PRIMARY_POLICY


def assert_layers_only(before, after):
    old, new = copy.deepcopy(before), copy.deepcopy(after)
    for value in (old, new):
        value['outline'].pop('outerShellCorrection', None)
        value['outline'].pop('observedLayers', None)
    if old != new:
        raise ValueError('Outer shell changed a non-layer output')


def process_one(payload):
    source, prediction, options, threshold = payload
    baseline = restore_baseline(prediction)
    # Recreate current ownership directly from authenticated native source;
    # cached study decisions and labels are never runtime inputs.
    current, provenance = primary_process((source, baseline, options))
    if current != baseline:
        raise ValueError('Outer-shell stage requires current final primary source predictions')
    feature = read(Path(options['features']) / (source['itemID'] + '.json'))
    identity = feature['identity']
    geometry = dict(polygons=identity['polygons'], mergedPolygon=identity['mergedPolygon'],
                    fontPixels=identity['fontPixels'])
    rgb = np.asarray(Image.open(source['crop']).convert('RGB'))
    result, diagnostic = refine(rgb, geometry, baseline, provenance['diagnostic'], threshold)
    identity_checks = ((Path(source['crop']), 'sourceRGBSHA256'),
                       (Path(options['features']) / (source['itemID'] + '.json'), 'sourceFeatureSHA256'),
                       (Path(options['masks']) / (source['itemID'] + '.png'), 'predictedMaskSHA256'))
    if any(digest(path) != provenance['provenance'][key] for path, key in identity_checks):
        raise ValueError('Outer-shell source changed during native measurement')
    assert_layers_only(prediction, result)
    return result, dict(itemID=source['itemID'], sourceRGBSHA256=provenance['provenance']['sourceRGBSHA256'],
                        sourceFeatureSHA256=provenance['provenance']['sourceFeatureSHA256'],
                        diagnostic=diagnostic)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('gt', 'estimator', 'features', 'masks', 'source-root', 'ocr-evidence'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--threshold', type=float, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    args = parser.parse_args()
    if args.jobs < 1:
        raise ValueError('jobs must be positive')
    folder = args.estimator
    policy = make_policy(folder, args.threshold)
    identities = {name: digest(folder / name) for name in MODEL_NAMES}
    primary_hash = digest(folder / PRIMARY_POLICY)
    validate_policy(policy, identities, primary_hash)
    predpath = folder / 'predictions-with-width.json'
    before_hash, gt_hash = digest(predpath), digest(args.gt)
    original = read(predpath)
    rows = read(args.gt)['items']
    assign_splits(rows)
    if [r['itemID'] for r in rows] != [p['itemID'] for p in original['items']]:
        raise ValueError('Outer-shell source identities differ')
    options = {name: str(getattr(args, name)) for name in
               ('estimator', 'features', 'masks', 'source_root', 'ocr_evidence')}
    tasks = [(source_request(row), pred, options, args.threshold)
             for row, pred in zip(rows, original['items'])]
    with ProcessPoolExecutor(max_workers=args.jobs) as pool:
        outputs = list(pool.map(process_one, tasks, chunksize=1))
    result = copy.deepcopy(original)
    result['items'] = [value for value, _ in outputs]
    changed = []
    for old, new in zip(original['items'], result['items']):
        assert_layers_only(old, new)
        if old['outline'].get('observedLayers') != new['outline'].get('observedLayers'):
            changed.append(new['itemID'])
    if digest(predpath) != before_hash or digest(args.gt) != gt_hash:
        raise ValueError('Outer-shell source snapshot changed')
    validate_policy(policy, {name: digest(folder / name) for name in MODEL_NAMES}, digest(folder / PRIMARY_POLICY))
    save(predpath, result)
    save(folder / 'NATIVE-OUTER-SHELL-POLICY.json', policy)
    save(folder / 'NATIVE-OUTER-SHELL-RESULTS.json', dict(itemCount=len(rows), changedItems=changed,
         items=[report for _, report in outputs], GTAtInference=False, GTUnchanged=True,
         allNonLayerOutputsUnchanged=True, originalPredictionSHA256=before_hash,
         finalPredictionSHA256=digest(predpath), sourceContextMaxEachSide=.15))
    print('Native visible outer-shell:', len(rows), 'items;', len(changed), 'layer changes', flush=True)


if __name__ == '__main__':
    main()
