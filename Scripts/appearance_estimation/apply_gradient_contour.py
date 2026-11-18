"""Final source-only gradient contour RGB correction and emitted-output evaluation.

Run after every other head, including final background. This module never trains,
changes candidate indices, or promotes a checkpoint. GT stays in the coordinator.
"""
import argparse
import copy
from concurrent.futures import ProcessPoolExecutor
from pathlib import Path
import pickle
import sys

import numpy as np
from PIL import Image

from optimize_appearance import (assign_splits, digest, evaluate_predictions,
                                 objective, read, save, split, targets)
from source_appearance import lab

MODEL_FILES = ('model.pkl', 'pixel-role-model.pkl', 'width-model.pkl',
               'background-palette.pkl', 'source-fill-palette-model.pkl',
               'final-background-model.pkl')
SOURCE_FIELDS = ('itemID', 'crop', 'cropSHA256', 'page', 'sourceImageSHA256',
                 'pageSize', 'cropBounds', 'individualPolygonsCrop', 'mergedPolygonCrop', 'fontPixels', 'maxContextFraction')
_RUNTIME = {}


def source_request(row):
    """Explicit source metadata whitelist: no GT style, anchors, or full row."""
    context = float(row['maxContextFraction'])
    if not np.isfinite(context) or not 0 <= context <= .15:
        raise ValueError('Source crop context exceeds approved bound')
    return {key: copy.deepcopy(row[key]) for key in SOURCE_FIELDS}


def assert_rgb_only(before, after):
    """Allow outline RGB and authenticated source fill primary/palette provenance."""
    if not isinstance(after, dict):
        raise ValueError('Contour result must be a prediction dictionary')
    expected = copy.deepcopy(before)
    restored = copy.deepcopy(after)
    expected['outline'].pop('gradientContourCorrection', None)
    restored.get('outline', {}).pop('gradientContourCorrection', None)
    if 'rgb' not in before['outline'] or 'rgb' not in restored.get('outline', {}):
        raise ValueError('Contour removed or introduced outline RGB structure')
    restored['outline']['rgb'] = copy.deepcopy(before['outline']['rgb'])
    from source_gradient_contour import restore_baseline as restore_native
    expected['fill'] = restore_native(expected)['fill']
    restored['fill'] = restore_native(restored)['fill']
    if restored != expected:
        raise ValueError('A non-outline-colour output changed')
    colour = after['outline']['rgb']
    if colour != before['outline']['rgb']:
        if (not isinstance(colour, list) or len(colour) != 3
                or any(type(v) is not int or not 0 <= v <= 255 for v in colour)):
            raise ValueError('Contour RGB must contain three native byte values')
        if not before['outline']['present']:
            raise ValueError('Contour changed RGB for an absent outline')


def load_expensive(source, options, identity):
    """Same authenticated source loaders as apply_source_shadow, lazily per process."""
    root = Path(options['source_root'])
    key = (str(root), str(options['estimator']))
    if key not in _RUNTIME:
        sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'segmentation'))
        from source_boundary_votes import SourceBoundaryVotes
        observations = read(root / 'boundary-lean/evaluation-manifest.json')['items']
        votes = SourceBoundaryVotes(root / 'boundary-lean', root / 'deep-classifier-observations',
                                    root / 'edge-context60-native', root / 'edge-context60-observations')
        with (Path(options['estimator']) / 'pixel-role-model.pkl').open('rb') as handle:
            model = pickle.load(handle)
        if model['appearanceModelSHA256'] != digest(Path(options['estimator']) / 'model.pkl'):
            raise ValueError('Source/pixel-role model pairing changed')
        fields = ('id', 'rgb', 'rf', 'width', 'height', 'polygons', 'fontPixels')
        _RUNTIME[key] = ({r['id']: {f: r[f] for f in fields} for r in observations}, votes, model)
    observations, votes, model = _RUNTIME[key]
    from prepare_full_rf import load_case_features
    from source_confidence_evidence import raster
    observation = observations[source['itemID']]
    casepath = root / 'boundary-lean/rf-full/crops' / (source['itemID'] + '.json')
    case = read(casepath)
    native = (casepath.parent / case['nativeGrids']).resolve()
    if (case['sourceSHA256'] != source['sourceImageSHA256']
            or case['cropBounds'] != source['cropBounds'] or case['pageSize'] != source['pageSize']):
        raise ValueError('RF/source geometry mismatch')
    checks = dict(RFCaseSHA256=digest(casepath), RFNativeSHA256=digest(native),
                  RFModelWeightsSHA256=case['modelWeightsSHA256'],
                  primaryClassifierSHA256=votes.primary_identity,
                  boundaryClassifierSHA256=votes.boundary_identity)
    if any(identity.get(k) != v for k, v in checks.items()):
        raise ValueError('RF/segmentation source feature pairing changed')
    primary, boundary, _ = votes.load(observation)
    rf = load_case_features(observation, root / 'boundary-lean')
    ocrpath = Path(options['ocr_evidence']) / (source['page'] + '.json.gz')
    if digest(ocrpath) != identity['OCRSourceSHA256']:
        raise ValueError('Source feature OCR identity mismatch')
    ocr = raster(ocrpath, source['sourceImageSHA256'], source['pageSize'], source['cropBounds'])
    arrays = dict(rf=rf, segPrimary=primary, segBoundary=boundary, ocr=ocr)
    return arrays, model, dict(OCRFileSHA256=digest(ocrpath),
                               OCRSourceSHA256=source['sourceImageSHA256'], **checks)


def process_one(payload):
    source, prediction, options = payload
    if set(source) != set(SOURCE_FIELDS):
        raise ValueError('Worker source metadata is not whitelisted')
    import source_gradient_core as core
    from source_gradient_contour import refine, restore_baseline, needs_source
    item = source['itemID']
    featurepath = Path(options['features']) / (item + '.json')
    maskpath = Path(options['masks']) / (item + '.png')
    feature_hash = digest(featurepath)
    entry = read(featurepath)
    identity = entry['identity']
    rgb_hash, mask_hash = digest(source['crop']), digest(maskpath)
    if rgb_hash != source['cropSHA256'] or identity['sourceRGBSHA256'] != rgb_hash:
        raise ValueError('Source RGB mismatch')
    if identity['predictedMaskSHA256'] != mask_hash:
        raise ValueError('Predicted mask mismatch')
    for key, field in [('polygons', 'individualPolygonsCrop'),
                       ('mergedPolygon', 'mergedPolygonCrop'), ('fontPixels', 'fontPixels')]:
        if identity[key] != source[field]:
            raise ValueError('Source feature geometry mismatch: ' + key)
    if entry.get('itemID', item) != item:
        raise ValueError('Feature item correspondence changed')
    with Image.open(source['crop']) as image:
        rgb = np.asarray(image.convert('RGB'))
    with Image.open(maskpath) as image:
        mask = np.asarray(image) > 0
    if mask.ndim != 2 or rgb.shape[:2] != mask.shape:
        raise ValueError('Original source RGB/mask dimensions differ')
    geometry = dict(polygons=identity['polygons'], mergedPolygon=identity['mergedPolygon'],
                    fontPixels=entry['packet']['fontPixels'])
    if entry['packet']['fontPixels'] != identity['fontPixels']:
        raise ValueError('Source packet font geometry mismatch')
    bounds = source['cropBounds']
    if [rgb.shape[1], rgb.shape[0]] != [bounds[2] - bounds[0], bounds[3] - bounds[1]]:
        raise ValueError('Source crop bounds/dimensions mismatch')
    before = copy.deepcopy(prediction)
    base = restore_baseline(before)
    groups = needs_source(rgb, mask, geometry, base, entry['packet'])
    provenance = dict(itemID=item, sourceRGBSHA256=rgb_hash, predictedMaskSHA256=mask_hash,
                      sourceFeatureSHA256=feature_hash, sourceImageSHA256=source['sourceImageSHA256'],
                      nativeSize=[rgb.shape[1], rgb.shape[0]],
                      sourceFeatureIdentity=copy.deepcopy(identity))
    if not groups:
        from source_native_primary_quality import attach as attach_native_quality
        result, quality_evidence = attach_native_quality(rgb, mask, geometry, base)
        diagnostic = dict(expensiveSourceLoaded=False, reason='no-source-gradient-components', nativePrimaryQuality=quality_evidence)
    else:
        arrays, pixel_model, extra = load_expensive(source, options, identity)
        provenance.update(extra)
        result, diagnostic = refine(rgb, mask, arrays, geometry, copy.deepcopy(base),
                                    pixel_model, entry['packet'])
        diagnostic = {**diagnostic, 'expensiveSourceLoaded': True}
    from source_gradient_contour import PALETTE_TAG
    from owned_palette import validate_additions
    palette_tag=result['fill'].get(PALETTE_TAG)
    if palette_tag:validate_additions(palette_tag.get('sourceEvidence'),palette_tag['addedRGB'],rgb=rgb)
    from certified_bright_primary import TAG as PRIMARY_TAG,validate as validate_primary
    if PRIMARY_TAG in result['fill']:validate_primary(result['fill'][PRIMARY_TAG]['sourceEvidence'],rgb=rgb)
    from certified_interior_palette import TAG as PRUNING_TAG,validate as validate_pruning
    if PRUNING_TAG in result['fill']:
        from source_native_primary_quality import restore_baseline as restore_quality
        tag=restore_quality(result)['fill'][PRUNING_TAG];validate_pruning(tag['sourceEvidence'],tag['previousColors'],tag['retainedColors'],tag['primaryRGB'],rgb=rgb)
    from source_native_primary_quality import TAG as QUALITY_TAG, validate as validate_quality
    if QUALITY_TAG in result['fill']:validate_quality(result['fill'][QUALITY_TAG],rgb)
    assert_rgb_only(before, result)
    if (digest(source['crop']) != rgb_hash or digest(maskpath) != mask_hash
            or digest(featurepath) != feature_hash):
        raise ValueError('Source inputs changed during contour replay')
    return result, dict(itemID=item, provenance=provenance, diagnostic=diagnostic,
                        outlineRGBChanged=before['outline']['rgb'] != result['outline']['rgb'])


def assert_document_rgb_only(before, after):
    if len(before['items']) != len(after['items']):
        raise ValueError('Prediction item count changed')
    expected = copy.deepcopy(before)
    restored = copy.deepcopy(after)
    for old, new in zip(expected['items'], restored['items']):
        assert_rgb_only(old, new)
        old['outline'].pop('gradientContourCorrection', None)
        new['outline'].pop('gradientContourCorrection', None)
        new['outline']['rgb'] = copy.deepcopy(old['outline']['rgb'])
        from source_gradient_contour import restore_baseline as restore_native
        old['fill'] = restore_native(old)['fill']
        new['fill'] = restore_native(new)['fill']
    for old in expected['items']:
        old['outline'].pop('gradientContourCorrection', None)
    if restored != expected:
        raise ValueError('Prediction document metadata changed')


def run(args):
    from source_gradient_contour import make_policy, validate_policy, restore_baseline
    folder = args.estimator
    if args.jobs < 1:
        raise ValueError('jobs must be positive')
    # A partial checkpoint is not a valid final-stage input.
    for name in (*MODEL_FILES, 'FINAL-BACKGROUND-RESULTS.json'):
        if not (folder / name).is_file():
            raise ValueError('Missing final-stage checkpoint file: ' + name)
    policy = make_policy(folder)
    identities = {name: digest(folder / name) for name in MODEL_FILES}
    validate_policy(policy, identities)
    gt_hash = digest(args.gt)
    prediction_path = folder / 'predictions-with-width.json'
    prediction_hash = digest(prediction_path)
    original = read(prediction_path)
    rows = read(args.gt)['items']
    grouping = assign_splits(rows)
    if len({r['itemID'] for r in rows}) != len(rows):
        raise ValueError('Duplicate source identities')
    if [r['itemID'] for r in rows] != [p['itemID'] for p in original['items']]:
        raise ValueError('Contour/source identities differ')
    options = {name: str(getattr(args, name)) for name in
               ('estimator', 'features', 'masks', 'source_root', 'ocr_evidence')}
    tasks = [(source_request(row), prediction, options)
             for row, prediction in zip(rows, original['items'])]
    if args.jobs == 1:
        results = list(map(process_one, tasks))
    else:
        with ProcessPoolExecutor(max_workers=args.jobs) as pool:
            results = list(pool.map(process_one, tasks, chunksize=1))
    output = copy.deepcopy(original)
    output['items'] = [result for result, _ in results]
    assert_document_rgb_only(original, output)
    packets = [read(args.features / (r['itemID'] + '.json'))['packet'] for r in rows]
    # Evaluation runs only after all source-only worker outputs have returned.
    baseline_output = copy.deepcopy(original)
    baseline_output['items'] = [restore_baseline(p) for p in original['items']]
    baseline = evaluate_predictions(rows, packets, baseline_output['items'])
    selected = evaluate_predictions(rows, packets, output['items'])
    best = read(folder / 'BEST.json')
    best.update(metrics=selected, devObjective=objective(selected['dev']))
    def error(row, pred):
        colours = targets(row, 'outline')
        if not colours or row['outline']['present'] is not True:
            return None
        return float(np.linalg.norm(lab(colours) - lab([pred['outline']['rgb']])[0], axis=1).min())

    changed = [dict(itemID=old['itemID'], beforeRGB=old['outline']['rgb'],
                    afterRGB=new['outline']['rgb'], evaluationSplit=split(row),
                    beforeDeltaE=error(row, old), afterDeltaE=error(row, new))
               for row, old, new in zip(rows, baseline_output['items'], output['items'])
               if old['outline']['rgb'] != new['outline']['rgb']]
    current = {name: digest(folder / name) for name in MODEL_FILES}
    if current != identities:
        raise ValueError('Checkpoint models changed during contour replay')
    validate_policy(policy, current)
    if digest(args.gt) != gt_hash or digest(prediction_path) != prediction_hash:
        raise ValueError('GT or predictions changed during contour replay')
    report = dict(baseline=baseline, selected=selected, changedItems=changed,
                  changedItemCount=len(changed), itemCount=len(rows), grouping=grouping,
                  allOtherOutputsUnchangedExceptAuthenticatedOutlineAndFill=True, GTUnchanged=True, GTAtInference=False,
                  sourceRGBAndMasksUnchanged=True, sourceResized=False,
                  sourceContextMaxEachSide=.15, wholePagesVisuallyOpened=False,
                  allowedMutationPaths=['outline.rgb', 'outline.gradientContourCorrection','fill.rgb','fill.colors','fill.gradientPaletteCorrection','fill.brightPrimaryCorrection','fill.interiorPalettePruning','fill.nativePrimaryQualityCorrection'],
                  warmSemantics='Peel native learned primary first, then certified palette pruning and primary fill and native outline/palette corrections, before prescreen and source refinement',
                  sourceGeometryFields=['polygons', 'mergedPolygon', 'fontPixels'],
                  modelIdentities=identities, GTSHA256=gt_hash,
                  baselinePredictionsSHA256=prediction_hash, policy=policy,
                  stage='final-after-all-heads-including-final-background',
                  items=[diagnostic for _, diagnostic in results],
                  limitation='Fixed GT crop benchmark; repeatedly inspected corpus, not unseen-page validation')
    save(prediction_path, output)
    # Read back and evaluate the actual emitted RGB, never a candidate-index proxy.
    emitted = read(prediction_path)
    assert_document_rgb_only(original, emitted)
    actual = evaluate_predictions(rows, packets, emitted['items'])
    if actual != selected:
        raise ValueError('Emitted prediction evaluation differs')
    from paint_palette_metrics import measure as palette_measure, predicted_colours
    def palette_metrics(document):
        result={}
        for group in ('train','dev','test','all'):
            indices=[i for i,r in enumerate(rows) if group=='all' or split(r)==group]
            selected_rows=[rows[i] for i in indices];preds=[document['items'][i] for i in indices]
            result[group]=palette_measure(selected_rows,preds,[predicted_colours(v) for v in preds])
        return result
    report['fillPaletteMetrics']=dict(baseline=palette_metrics(baseline_output),selected=palette_metrics(emitted))
    report['emittedPredictionsSHA256'] = digest(prediction_path)
    save(folder / 'BEST.json', best)
    save(folder / 'NATIVE-GRADIENT-CONTOUR-POLICY.json', policy)
    save(folder / 'NATIVE-GRADIENT-CONTOUR-RESULTS.json', report)
    print('Native gradient contour:', len(rows), 'items;', len(changed), 'RGB changes', flush=True)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('gt', 'estimator', 'features', 'masks', 'source-root', 'ocr-evidence'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--jobs', type=int, default=4)
    return run(parser.parse_args(argv))


if __name__ == '__main__':
    main()
