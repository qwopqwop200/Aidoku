"""Final-background source batch replay; workers receive source metadata only.

Frozen v1 local and v2 fused rankers share the same background-only output contract.
Styles are used by the coordinator only after all inference has finished.
"""
import argparse
import copy
from concurrent.futures import ProcessPoolExecutor
import hashlib
import io
import json
from pathlib import Path
import pickle
import tempfile
import time

import numpy as np
from PIL import Image
from optimize_appearance import read, save, digest, assign_splits, split
from source_appearance import lab
import final_background_refinement as refinement
from apply_gradient_contour import SOURCE_FIELDS, source_request, load_expensive

_RUNTIME = {}


def geometry_only(row):
    return source_request(row)


def _json_snapshot(path):
    data = Path(path).read_bytes()
    return json.loads(data), hashlib.sha256(data).hexdigest()


def _image(path, rgb=False):
    with Image.open(io.BytesIO(Path(path).read_bytes())) as image:
        return np.asarray(image.convert('RGB') if rgb else image).copy()


def _validate_geometry(source, entry):
    identity = entry['identity']
    if entry.get('itemID', source['itemID']) != source['itemID']:
        raise ValueError('Source/feature item identity mismatch')
    for key, field in (('polygons', 'individualPolygonsCrop'),
                       ('mergedPolygon', 'mergedPolygonCrop'), ('fontPixels', 'fontPixels')):
        if identity[key] != source[field]:
            raise ValueError('Source feature geometry mismatch: ' + key)
    if entry['packet']['fontPixels'] != source['fontPixels']:
        raise ValueError('Source packet font geometry mismatch')
    for key in ('cropBounds', 'pageSize', 'sourceImageSHA256'):
        if key in identity and identity[key] != source[key]:
            raise ValueError('Source feature identity mismatch: ' + key)


def source_context(geometry, neighbors, masks, features):
    """Union overlapping native predicted masks, without polygon/bbox clipping."""
    masks, features = Path(masks), Path(features)
    x, y, right, bottom = geometry['cropBounds']
    result = np.zeros((bottom-y, right-x), bool)
    identities = []
    for neighbor in neighbors:
        a, b, c, d = neighbor['cropBounds']
        left, top, end_x, end_y = max(x, a), max(y, b), min(right, c), min(bottom, d)
        if left >= end_x or top >= end_y:
            continue
        path = masks / (neighbor['itemID'] + '.png')
        featurepath = features / (neighbor['itemID'] + '.json')
        entry, feature_hash = _json_snapshot(featurepath)
        _validate_geometry(neighbor, entry)
        sha = digest(path)
        if sha != entry['identity']['predictedMaskSHA256']:
            raise ValueError('Neighbor predicted-mask identity mismatch')
        mask = _image(path) > 0
        if mask.shape != (d-b, c-a):
            raise ValueError('Neighbor source-mask geometry mismatch')
        result[top-y:end_y-y, left-x:end_x-x] |= mask[top-b:end_y-b, left-a:end_x-a]
        if digest(path) != sha or digest(featurepath) != feature_hash:
            raise ValueError('Neighbor inputs changed during context construction')
        identities.append(dict(itemID=neighbor['itemID'], cropBounds=neighbor['cropBounds'],
                               predictedMaskSHA256=sha, sourceFeatureSHA256=feature_hash))
    return result, identities


def assert_background_only(before, after):
    """Full equality catches added/deleted fields, including nested output fields."""
    if not isinstance(after, dict) or not isinstance(after.get('background'), dict):
        raise ValueError('Final background result must be a prediction dictionary')
    expected, restored = copy.deepcopy(before), copy.deepcopy(after)
    expected['background'].pop('primaryCorrectionEvidence', None)
    restored['background'].pop('primaryCorrectionEvidence', None)
    if 'rgb' not in expected['background'] or 'rgb' not in restored['background']:
        raise ValueError('Final background RGB structure changed')
    restored['background']['rgb'] = copy.deepcopy(expected['background']['rgb'])
    if restored != expected:
        raise ValueError('Final background changed another output field')
    colour = after['background']['rgb']
    if colour != before['background']['rgb'] and (
            not isinstance(colour, list) or len(colour) != 3
            or any(type(v) is not int or not 0 <= v <= 255 for v in colour)):
        raise ValueError('Final background RGB must contain three byte integers')


def assert_document_background_only(before, after):
    expected, restored = copy.deepcopy(before), copy.deepcopy(after)
    if len(expected['items']) != len(restored['items']):
        raise ValueError('Final background item count changed')
    for old, new in zip(expected['items'], restored['items']):
        assert_background_only(old, new)
        old['background'].pop('primaryCorrectionEvidence', None)
        new['background'].pop('primaryCorrectionEvidence', None)
        new['background']['rgb'] = copy.deepcopy(old['background']['rgb'])
    if restored != expected:
        raise ValueError('Final background document metadata changed')


def initialize(model_path, model_hash, options, by_source):
    """Unpickle and validate the frozen classifier exactly once per process."""
    data = Path(model_path).read_bytes()
    if hashlib.sha256(data).hexdigest() != model_hash:
        raise ValueError('Worker model snapshot changed')
    model = pickle.loads(data)
    refinement.validate_model(model)
    _RUNTIME.clear()
    _RUNTIME.update(model=model, options=options, by_source=by_source)


def process_one(payload):
    source, prediction = payload
    if set(source) != set(SOURCE_FIELDS):
        raise ValueError('Worker source metadata is not whitelisted')
    source = geometry_only(source)  # finite, nonnegative, <= .15 per side; no area gate
    model, options = _RUNTIME['model'], _RUNTIME['options']
    item = source['itemID']
    if prediction['itemID'] != item:
        raise ValueError('Worker prediction/source correspondence mismatch')
    featurepath = Path(options['features']) / (item + '.json')
    maskpath = Path(options['masks']) / (item + '.png')
    entry, feature_hash = _json_snapshot(featurepath)
    _validate_geometry(source, entry)
    identity = entry['identity']
    rgb_hash, mask_hash = digest(source['crop']), digest(maskpath)
    if rgb_hash != source['cropSHA256'] or identity['sourceRGBSHA256'] != rgb_hash:
        raise ValueError('Source RGB identity mismatch')
    if identity['predictedMaskSHA256'] != mask_hash:
        raise ValueError('Own predicted-mask identity mismatch')
    rgb, own = _image(source['crop'], True), _image(maskpath) > 0
    x, y, right, bottom = source['cropBounds']
    if own.shape != (bottom-y, right-x) or rgb.shape != own.shape + (3,):
        raise ValueError('Native source crop/mask/bounds mismatch')
    context, neighbors = source_context(source, _RUNTIME['by_source'][source['sourceImageSHA256']],
                                        options['masks'], options['features'])
    arrays, extra = None, {}
    if refinement.requires_source(model):
        arrays, _pixel_model, extra = load_expensive(source, options, identity)
    before = copy.deepcopy(prediction)
    corrected = refinement.apply(rgb, own, context, entry['packet'], copy.deepcopy(prediction),
                                 model, source['fontPixels'], source_arrays=arrays)
    assert_background_only(before, corrected)
    if (digest(source['crop']) != rgb_hash or digest(maskpath) != mask_hash
            or digest(featurepath) != feature_hash):
        raise ValueError('Native source inputs changed during final-background replay')
    for neighbor in neighbors:
        name = neighbor['itemID']
        if (digest(Path(options['masks']) / (name + '.png')) != neighbor['predictedMaskSHA256']
                or digest(Path(options['features']) / (name + '.json')) != neighbor['sourceFeatureSHA256']):
            raise ValueError('Neighbor inputs changed during final-background replay')
    contribution = dict(source=source, neighborMasks=neighbors, sourceFeatureSHA256=feature_hash,
                        preCorrectionPrediction=refinement.restore_baseline(before), expensiveSource=extra)
    contribution_hash = hashlib.sha256(json.dumps(contribution, sort_keys=True).encode()).hexdigest()
    provenance = dict(itemID=item, sourceRGBSHA256=rgb_hash, predictedMaskSHA256=mask_hash,
                      sourceFeatureSHA256=feature_hash, sourceImageSHA256=source['sourceImageSHA256'],
                      nativeSize=[rgb.shape[1], rgb.shape[0]], expensiveSourceLoaded=arrays is not None,
                      sourceInputsSHA256=contribution_hash)
    # No arrays, unbounded feature packets, or source predictions in diagnostics.
    return corrected, provenance, contribution_hash


def colour_metrics(rows, predictions, role):
    groups = {}
    for group in ('train', 'dev', 'test', 'all'):
        values = []
        n = 0
        for row, prediction in zip(rows, predictions):
            if group != 'all' and split(row) != group:
                continue
            if role == 'outline' and row[role]['present'] is not True:
                continue
            targets = row[role].get('colors') or ([row[role]['rgb']] if row[role].get('rgb') else [])
            if not targets:
                continue
            n += 1
            rgb = prediction[role].get('rgb')
            if rgb is None or role == 'outline' and not prediction[role]['present']:
                continue
            values.append(float(np.linalg.norm(lab(targets) - lab([rgb])[0], axis=1).min()))
        groups[group] = dict(n=n, emittedN=len(values), missingEmissions=n-len(values),
            meanDeltaE=float(np.mean(values)) if values else None,
            deltaEMedian=float(np.median(values)) if values else None,
            within10=sum(v <= 10 for v in values) / max(1, n),
            failures=n-sum(v <= 10 for v in values))
    return groups


def run(args):
    if args.jobs <= 0:
        raise ValueError('jobs must be positive')
    started = time.monotonic()
    folder = Path(args.estimator)
    prediction_path = folder / 'predictions-with-width.json'
    original, original_hash = _json_snapshot(prediction_path)
    source_document, gt_hash = _json_snapshot(args.gt)
    geometries = [geometry_only(row) for row in source_document['items']]
    del source_document  # workers never receive GT style rows
    if len({g['itemID'] for g in geometries}) != len(geometries):
        raise ValueError('Duplicate source identities')
    if [g['itemID'] for g in geometries] != [p['itemID'] for p in original['items']]:
        raise ValueError('Source/prediction correspondence mismatch')
    model_bytes = Path(args.model).read_bytes()
    source_model_hash = hashlib.sha256(model_bytes).hexdigest()
    model = pickle.loads(model_bytes)
    refinement.validate_model(model)  # validates v2 helper digest and exact 102 feature names
    if refinement.requires_source(model) and (
            args.source_root is None or args.ocr_evidence is None):
        raise ValueError('Fused v2 requires --source-root and --ocr-evidence')
    names = refinement.MODEL_NAMES
    if len(names) != 6 or len(set(names)) != 6:
        raise ValueError('Expected six paired model artifacts')
    identities = {name: digest(folder / name) for name in names if name != 'final-background-model.pkl'}
    model_path = folder / 'final-background-model.pkl'
    prior_model_hash = digest(model_path) if model_path.exists() else None
    if Path(args.model).resolve() != model_path.resolve():
        # Unique staging file; never reserialize the supplied classifier.
        with tempfile.NamedTemporaryFile(dir=folder, prefix='.final-background-', delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(model_bytes)
        try:
            current = digest(model_path) if model_path.exists() else None
            if current != prior_model_hash:
                raise ValueError('Checkpoint model changed before staging')
            temporary.replace(model_path)
        finally:
            temporary.unlink(missing_ok=True)
    identities['final-background-model.pkl'] = source_model_hash
    if any(digest(folder / name) != sha for name, sha in identities.items()):
        raise ValueError('Paired checkpoint changed during model staging')
    policy = refinement.make_policy(folder, model, Path(args.model))
    refinement.validate_policy(policy, identities)
    if policy['modelVersion'] != model['version']:
        raise ValueError('Policy/model version mismatch')
    options = {name: str(getattr(args, name)) if getattr(args, name) is not None else None
               for name in ('estimator', 'features', 'masks', 'source_root', 'ocr_evidence')}
    by_source = {}
    for geometry in geometries:
        by_source.setdefault(geometry['sourceImageSHA256'], []).append(geometry)
    tasks = [(geometry, prediction) for geometry, prediction in zip(geometries, original['items'])]
    # Even one job uses the same process boundary and initializer contract.
    with ProcessPoolExecutor(max_workers=args.jobs, initializer=initialize,
                             initargs=(str(model_path), source_model_hash, options, by_source)) as pool:
        results = []
        for completed, result in enumerate(pool.map(process_one, tasks, chunksize=1), 1):
            results.append(result)
            if completed % 250 == 0 or completed == len(tasks):
                print('final-background-native', completed, '/', len(tasks), flush=True)
    output = copy.deepcopy(original)
    output['items'] = [result[0] for result in results]
    assert_document_background_only(original, output)
    baseline = copy.deepcopy(original)
    baseline['items'] = [refinement.restore_baseline(p) for p in original['items']]
    changed = [dict(itemID=g['itemID'], previousRGB=a['background']['rgb'], rgb=b['background']['rgb'])
               for g, a, b in zip(geometries, baseline['items'], output['items'])
               if a['background']['rgb'] != b['background']['rgb']]
    source_digest = hashlib.sha256()
    for _, _, contribution in results:
        source_digest.update(bytes.fromhex(contribution))
    # Reopen styles only after every source-only worker has finished.
    evaluation_document, evaluation_hash = _json_snapshot(args.gt)
    if evaluation_hash != gt_hash:
        raise ValueError('GT snapshot changed during replay')
    rows = evaluation_document['items']
    grouping = assign_splits(rows)
    # Styles are consumed only here, after source inference is complete.
    metrics = {stage: {role: colour_metrics(rows, packet['items'], role) for role in ('fill', 'outline', 'background')}
        for stage, packet in [('baseline', baseline), ('selected', output)]}
    base = metrics['baseline']['background']
    selected = metrics['selected']['background']
    paired = {}
    for group in ('train', 'dev', 'test', 'all'):
        fixed = lost = improved = worsened = 0
        for row, a, b in zip(rows, baseline['items'], output['items']):
            if group != 'all' and split(row) != group:
                continue
            target = row['background'].get('colors') or [row['background']['rgb']]
            da, db = [float(np.linalg.norm(lab(target) - lab([p['background']['rgb']])[0], axis=1).min()) for p in (a, b)]
            fixed += da > 10 and db <= 10
            lost += da <= 10 and db > 10
            improved += db < da
            worsened += db > da
        paired[group] = dict(oldFailuresFixed=int(fixed), oldPassLost=int(lost), improvedItems=int(improved), worsenedItems=int(worsened))
    def check_snapshot(prediction_hash=original_hash):
        if digest(args.gt) != gt_hash or digest(Path(args.model)) != source_model_hash:
            raise ValueError('GT or frozen source artifact changed during replay')
        if any(digest(folder / name) != sha for name, sha in identities.items()):
            raise ValueError('Paired checkpoint models changed during replay')
        refinement.validate_model(model)
        refinement.validate_policy(policy, identities)
        if digest(prediction_path) != prediction_hash:
            raise ValueError('Saved predictions changed concurrently')

    def non_regression(group):
        old, new = base[group]['meanDeltaE'], selected[group]['meanDeltaE']
        return old is None and new is None or old is not None and new is not None and new <= old

    guards = dict(TRAINDEVNoCategoricalLoss=all(paired[s]['oldPassLost'] == 0 for s in ('train', 'dev')),
        TRAINDEVMeanNonRegression=all(non_regression(s) for s in ('train', 'dev')),
        noOtherFieldChanged=True, GTChanged=False, GTAtInference=False, backgroundIndexPreserved=True)
    # Check just before each publication, including after policy serialization.
    check_snapshot()
    save(folder / 'FINAL-BACKGROUND-POLICY.json', policy)
    check_snapshot()
    save(prediction_path, output)
    emitted, emitted_hash = _json_snapshot(prediction_path)
    assert_document_background_only(original, emitted)
    actual = {role: colour_metrics(rows, emitted['items'], role) for role in ('fill', 'outline', 'background')}
    if actual != metrics['selected'] or emitted != output:
        raise ValueError('Emitted prediction snapshot/colour metrics differ')
    report = dict(baseline=base, selected=selected,
        baselineSemantics='RAW pre-final-background RGB, not frozen V2 output; paired V2 admission is separate',
        actualColourMetrics=metrics, paired=paired, guards=guards, changed=changed, itemCount=len(rows),
        grouping=grouping, sourceInputsSHA256=source_digest.hexdigest(), GTSHA256=gt_hash,
        inputPredictionsSHA256=original_hash, emittedPredictionsSHA256=emitted_hash,
        policy=policy, seconds=time.monotonic()-started, GTAtInference=False, GTChanged=False,
        noOtherFieldChanged=True, TESTDescriptiveOnly=True, sourceContextExpanded=False,
        limitation='Fixed GT-localization historical crop benchmark. No unseen-page or true ownership guarantee.')
    # Retain the legacy report schema; fused replay adds only bounded per-case provenance.
    if refinement.requires_source(model):
        report.update(items=[r[1] for r in results], sourceContextMaxEachSide=.15,
                      sourceRGBAndMasksUnchanged=True, sourceResized=False)
    check_snapshot(emitted_hash)
    save(folder / 'FINAL-BACKGROUND-RESULTS.json', report)
    print(json.dumps(dict(selected=selected, paired=paired, guards=guards)), flush=True)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('gt', 'estimator', 'features', 'masks', 'model'):
        parser.add_argument('--' + name, type=Path, required=True)
    for name in ('source-root', 'ocr-evidence'):
        parser.add_argument('--' + name, type=Path)
    parser.add_argument('--jobs', type=int, default=4)
    return run(parser.parse_args(argv))


if __name__ == '__main__':
    main()
