"""Scratch-only export/parity study of the existing frozen bold candidate.

Run with .venv-source-inference/bin/python Scripts/models/export_font_weight_runtime.py
--verify. No fitting, source scans, font copies, production registration or activation.
Only the exact trusted candidate SHA below may be unpickled. Portable metadata is
an allowlisted runtime graph; synthetic requests/replies live only in a temporary
directory, never in the portable assets.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import time
import warnings
from importlib.metadata import version

import export_source_model_runtime as base
import numpy as np

SHA = 'fc68d62720f2b874d9af46d5e525efebcbb388ec45b24feb503f3a1005e756fc'
STUDY = base.ROOT.parent / 'font-weight-estimation-20261111'
SOURCE = STUDY / 'complete-complementary/candidate.pkl'
PREFIX = 'font-weight/complete-complementary'
FAMILIES = {'CatBoostClassifier', 'ExtraTreesClassifier', 'HistGradientBoostingClassifier'}
HEADS = {'primary/primary/model': ('CatBoostClassifier', 2598),
         'primary/polarity/model': ('ExtraTreesClassifier', 2790),
         'body/model': ('HistGradientBoostingClassifier', 1791),
         'physical/model': ('CatBoostClassifier', 2742),
         'stem/model': ('CatBoostClassifier', 2934)}

# Reject unexpected metadata rather than silently exporting evaluation records.
FIELDS = {
    '': 'sourceBandHeads primary body physical stem bandFeatureCount bandPolicy referencePairs productionActivated sourceOnly directionalInkPolicy directionalInkVerificationSHA256 referenceInkPolicy referenceInkPairs referenceInkAdditionalPolicies softInkPolicy orderedInkPolicy',
    'primary': 'sourceComplementaryHeads primary polarity fillVersion sourceOnly productionActivated',
    'primary/primary': 'model threshold featureVersion rawFeatureCount featureCount pixelObservations pairedPhysical sourceGlyphResiduals physicalCorrection activationStatus',
    'primary/polarity': 'model threshold rawFeatureCount featureCount featureVersion sourceGlyphResiduals ownedFill trainingPolarityAugmentation physicalCorrection',
    'body': 'model threshold featureVersion rawFeatureCount featureCount',
    'physical': 'model threshold featureVersion rawFeatureCount featureCount pixelObservations pairedPhysical sourceGlyphResiduals',
    'stem': 'model threshold mode features rawFeatureCount featureCount referencePairsSHA256 incumbent',
    'physicalCorrection': 'minimumWhiteFill maximumBlackBackground serifFit serifHeavyMargin blackSansMinimumMargin blackSansFit blackSansHeavyMargin',
    'bandPolicy': 'minimumAddedStem minimumCommonBody minimumGlyphFit maximumReconstructionError',
    'directionalInkPolicy': 'mode direction quantile minimumWidthEm minimumDirectionContrast minimumPageRelative existingScoreField minimumExistingScore minimumDirectionalRays measurementSHA256 geometryVersion',
    'referenceInkPolicy': 'minimumFit minimumNormalMargin minimumStrokeFraction maximumFractionSpread minimumWordAgreement existingScoreField minimumExistingScore minimumRegisteredFraction minimumRegisteredSupport implementationSHA256',
    'referenceInkAdditionalPolicy': 'minimumFit minimumNormalMargin minimumStrokeFraction maximumFractionSpread minimumWordAgreement minimumRegisteredFraction minimumRegisteredSupport existingScoreField minimumExistingScore informationFont minimumReferencePerimeterEm minimumInformativeGlyphs requireCompleteWordEvidence implementationSHA256 informationImplementationSHA256',
    'softInkPolicy': 'minimumFit minimumNormalMargin minimumSoftFraction minimumSourceSupport minimumExistingScore wordSampling requireCompleteWordEvidence implementationSHA256',
    'orderedInkPolicy': 'minimumExistingScore minimumWordFit minimumWordMargin minimumIndependentGlyphs minimumGlyphFit minimumKnownSupport minimumMeanGlyphMargin requireAllGlyphsPositive wordSampling requireWitnessedOutline minimumOutlineProbability minimumPaintSeparation implementationSHA256',
    'pair': 'name regular heavy',
    'font': 'path SHA256 weight faceIndex',
}


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')


def portable_metadata(value, path='', obligations=None):
    """Preserve policies and thresholds; relocate font paths without copying bytes."""
    if obligations is None:
        obligations = []
    if path.endswith('/model'):
        if type(value).__name__ not in FAMILIES:
            raise ValueError('Unsupported frozen head: ' + path)
        return {'modelID': PREFIX + '/' + path}
    if isinstance(value, dict):
        tail = path.rsplit('/', 1)[-1]
        if tail == 'implementationSHA256':
            if not all(k.endswith('.py') and isinstance(v, str) and len(v) == 64
                       and all(c in '0123456789abcdef' for c in v) for k, v in value.items()):
                raise ValueError('Invalid implementation hashes: ' + path)
            return dict(value)
        schema = 'font' if tail in ('regular', 'heavy', 'informationFont') else (
            'pair' if path.startswith(('referencePairs/', 'referenceInkPairs/')) else (
                'referenceInkAdditionalPolicy' if path.startswith('referenceInkAdditionalPolicies/') else path))
        if tail == 'physicalCorrection':
            schema = tail
        if schema not in FIELDS or set(value) - set(FIELDS[schema].split()):
            raise ValueError('Unapproved metadata keys at ' + path)
        if schema == 'font':
            if not {'path', 'SHA256', 'weight'} <= value.keys():
                raise ValueError('Incomplete font identity: ' + path)
            asset = 'external-fonts/' + value['SHA256'] + '/' + Path(value['path']).name
            obligations.append(dict(metadataPath=path, originalPath=value['path'], asset=asset,
                                    sha256=value['SHA256'], weight=value['weight'],
                                    faceIndex=value.get('faceIndex'),
                                    faceIndexStatus='explicit' if 'faceIndex' in value else 'source-default-0-unverified',
                                    bytesBundled=False))
            return dict(value, path=asset)
        return {k: portable_metadata(v, path + '/' + k if path else k, obligations)
                for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        if path not in ('referencePairs', 'referenceInkPairs', 'referenceInkAdditionalPolicies'):
            raise ValueError('Unapproved metadata array: ' + path)
        return [portable_metadata(v, path + '/' + str(i), obligations) for i, v in enumerate(value)]
    if value is None or type(value) in (str, bool, int, float):
        return value
    raise ValueError('Unapproved metadata value: ' + path)


def export_candidate(source, out):
    # Validate before loading executable pickle payloads or writing any output.
    if digest(source) != SHA:
        raise ValueError('Frozen candidate SHA mismatch')
    if out.resolve().is_relative_to(base.ROOT.resolve()):
        raise ValueError('Scratch output must be outside the application repository')
    bundle = base.load(source)
    obligations = []
    tree = portable_metadata(bundle, obligations=obligations)
    objects = {}
    docs = base.collect(bundle, PREFIX, objects=objects)
    actual = {k.removeprefix(PREFIX + '/'): (type(objects[k]).__name__, d['featureCount'])
              for k, d in docs.items()}
    if actual != HEADS:
        raise ValueError('Frozen learned head inventory differs')
    if bundle['productionActivated'] or not bundle['sourceOnly']:
        raise ValueError('Candidate must remain source-only and inactive')
    out.mkdir(parents=True, exist_ok=True)
    registry = dict(schema=1, sourceOnly=True, GTAtInference=False, productionActivated=False,
                    studyOnly=True, nativeFeatureExtractionComplete=False,
                    heads={}, sourceArtifacts={PREFIX: SHA}, metadata={'tree': {PREFIX: tree}})
    for key, doc in docs.items():
        raw = plistlib.dumps(doc, fmt=plistlib.FMT_BINARY, sort_keys=False)
        sha = hashlib.sha256(raw).hexdigest()
        asset = 'heads/' + sha + '.plist'
        target = out / asset
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(raw)
        registry['heads'][key] = dict(asset=asset, sha256=sha, kind=doc['kind'],
                                      featureCount=doc['featureCount'], sourceModelSHA256=SHA)
    # Deliberately do not call write_registry: it attaches unrelated production policies.
    write_json(out / 'registry.json', registry)
    index = {k: v for k, v in registry.items() if k != 'metadata'}
    index.update(metadataAsset='registry.json', metadataSHA256=digest(out / 'registry.json'))
    write_json(out / 'registry-index.json', index)
    write_json(out / 'font-asset-obligations.json', dict(
        fonts=obligations, copiedFontBytes=False,
        requirements=[
            'Resolve external-fonts paths through a caller-owned asset map and verify exact file SHA256 before use.',
            'No system font bytes are copied; redistribute only with appropriate licensing and explicit packaging.',
            'weight is the exact variable-font wght coordinate, not a synthetic bold flag; preserve all other axes/defaults.',
            'Null weight selects the static face. Validate fvar axes and coordinate ranges before native raster parity.',
            'Absent faceIndex means the source loader default 0, not verified collection identity. Resolve and validate faceIndex for TTC/OTC before shipping.',
            'Bind faceIndex, variation coordinates, SHA and resolved asset path into font/raster cache identities.',
            'Reference matching must preserve shared frame, baseline, bearings, advances, vertical rotation and glyph coverage.',
        ]))
    if digest(source) != SHA:
        raise ValueError('Candidate changed during export')
    return bundle, objects, docs


def probe_rows(doc):
    """No feature archive, dataset row, prediction table or GT is consulted."""
    n = doc['featureCount']
    rng = np.random.default_rng(20261111 + n)
    rows = [np.zeros(n), np.ones(n), -np.ones(n)]
    rows.extend(rng.normal(size=(6, n)))
    rows.extend(rng.uniform(-10, 255, size=(6, n)))
    splits = []
    for forest in doc['forests']:
        for nodes in forest['trees'][:4]:
            splits.extend((v['feature'], v['threshold']) for v in nodes if not v['leaf'])
    for tree in doc['symmetricTrees'][:4]:
        splits.extend(zip(tree['features'], tree['borders']))
    for feature, border in splits[:12]:
        if not np.isfinite(border):
            continue
        f = np.float32(border)
        for v in (np.nextafter(f, np.float32(-np.inf)), border,
                  np.nextafter(f, np.float32(np.inf))):
            row = np.zeros(n)
            row[feature] = v
            rows.append(row)
    finite = np.asarray(rows, dtype=float)
    missing = np.vstack([np.full(n, np.nan), finite[:4]])
    for i in range(1, len(missing)):
        missing[i, i - 1::5] = np.nan
    return finite, missing


def verify(out, bundle, objects, docs):
    """Compile only the existing three-file numeric replay; never build the app."""
    started = time.monotonic()
    ensemble = base.ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
    sources = [ensemble / 'NativeAppearanceForest.swift', ensemble / 'NativeFrozenSourceModel.swift',
               base.ROOT / 'Scripts/models/NativeFrozenSourceModelReplay.swift']
    report = dict(passed=False, sourceSHA256=SHA, productionActivated=False,
                  nativeFeatureExtractionComplete=False, modelTrainingPerformed=False,
                  existingLearnedWeightsChanged=False, deterministicSeed=20261111,
                  inputs='Synthetic zero/sign/random/split-neighborhood matrices; no dataset/GT',
                  tolerance=dict(rtol=2e-10, atol=2e-10), heads={},
                  packageVersions={name: version(name) for name in ('numpy', 'scikit-learn', 'catboost')},
                  runtimeSHA256={p.name: digest(p) for p in sources})
    with tempfile.TemporaryDirectory(prefix='bold-numeric-parity-') as temporary:
        work = Path(temporary)
        binary = work / 'replay'
        before = time.monotonic()
        subprocess.run(['swiftc', '-O', *map(str, sources), '-o', str(binary)], check=True)
        report['numericReplayCompileSeconds'] = time.monotonic() - before
        requests, expected, thresholds = [], {}, {}
        for key, model in objects.items():
            finite, missing = probe_rows(docs[key])
            entry = dict(family=type(model).__name__, featureCount=docs[key]['featureCount'],
                         finiteRows=len(finite), missingRows=0)
            batches = [('finite', finite)]
            try:
                model.predict_proba(missing)
            except ValueError as error:
                if 'nan' not in str(error).lower():
                    raise
                entry['missingSupport'] = 'Source estimator rejects NaN; no native missing parity claim'
            else:
                batches.append(('missing', missing))
                entry.update(missingRows=len(missing), missingSupport='Source and native tested')
            parent = bundle
            for part in key.removeprefix(PREFIX + '/').split('/')[:-1]:
                parent = parent[part]
            thresholds[key] = parent['threshold']
            report['heads'][key] = entry
            # One call per head; classifiers are independent across matrix rows.
            rows = np.vstack([batch for _, batch in batches])
            with warnings.catch_warnings():
                warnings.simplefilter('ignore')
                probabilities = np.asarray(model.predict_proba(rows), float)
                labels = np.asarray(model.predict(rows), float).reshape(-1, 1)
            expected[key] = (probabilities, labels)
            encoded = [[None if np.isnan(v) else float(v) for v in row] for row in rows]
            requests.extend([dict(id=key, rows=encoded, probability=True, trees=False),
                             dict(id=key + '#labels', rows=encoded, probability=False, trees=False)])
        # Label aliases exist only in the temporary replay registry.
        registry = json.loads((out / 'registry.json').read_text())
        registry.pop('metadata')
        for key in objects:
            spec = dict(registry['heads'][key])
            spec['asset'] = str((out / spec['asset']).resolve())
            # Registry resolves paths relative to its directory: use symlinks locally.
            alias = work / (spec['sha256'] + '.plist')
            if not alias.exists():
                alias.symlink_to(spec['asset'])
            spec['asset'] = alias.name
            registry['heads'][key] = spec
            registry['heads'][key + '#labels'] = spec
        write_json(work / 'registry.json', registry)
        write_json(work / 'requests.json', requests)
        before = time.monotonic()
        subprocess.run([str(binary), str(work), str(work / 'requests.json'), str(work / 'replies.json')], check=True)
        report['numericReplaySeconds'] = time.monotonic() - before
        responses = json.loads((work / 'replies.json').read_text())
        if [r['id'] for r in responses] != [r['id'] for r in requests]:
            raise AssertionError('Incomplete or reordered replay responses')
        for response in responses:
            label = response['id'].endswith('#labels')
            key = response['id'].removesuffix('#labels')
            probabilities, labels = expected[key]
            actual = np.asarray(response['values'], float)
            wanted = labels if label else probabilities
            np.testing.assert_allclose(actual, wanted, rtol=2e-10, atol=2e-10, err_msg=response['id'])
            np.testing.assert_array_equal(response['classes'], docs[key]['classes'])
            if label:
                np.testing.assert_array_equal(actual, wanted)
                report['heads'][key]['labelMismatches'] = 0
            else:
                entry = report['heads'][key]
                entry['maxAbsoluteProbabilityError'] = float(np.max(np.abs(actual - wanted)))
                entry['threshold'] = thresholds[key]
                np.testing.assert_array_equal(actual[:, 1] >= thresholds[key], wanted[:, 1] >= thresholds[key])
                entry['thresholdDecisionMismatches'] = 0
    report.update(passed=True, totalSeconds=time.monotonic() - started)
    write_json(out / 'PARITY.json', report)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=SOURCE)
    parser.add_argument('--out', type=Path, default=STUDY / 'native-export')
    parser.add_argument('--verify', action='store_true', help='Run existing Swift numeric runtime against synthetic matrices')
    args = parser.parse_args()
    # Never leave an old PASS receipt after a failed attempt.
    if args.out.resolve().is_relative_to(base.ROOT.resolve()):
        raise ValueError('Scratch output must be outside the application repository')
    for receipt in ('PARITY.json', 'STUDY.json'):
        (args.out / receipt).unlink(missing_ok=True)
    bundle, objects, docs = export_candidate(args.source, args.out)
    report = verify(args.out, bundle, objects, docs) if args.verify else None
    if digest(args.source) != SHA:
        raise ValueError('Candidate changed during study')
    prior_path = args.source.parent / 'full-source/VERIFICATION.json'
    prior = json.loads(prior_path.read_text())
    if prior.get('candidateSHA256') != SHA or prior.get('passed') is not True:
        raise ValueError('Existing full-source verification does not attest this candidate')
    write_json(args.out / 'STUDY.json', dict(
        sourceSHA256=SHA, headCount=len(objects), supportedModelFamilies=sorted(FAMILIES),
        previousSourceVerification=dict(asset=str(prior_path), sha256=digest(prior_path),
                                        passed=prior['passed'], rows=prior['rows'],
                                        rerun=False, nativeAcceptance=False),
        modelTrainingPerformed=False, existingLearnedWeightsChanged=False, productionActivated=False,
        nativeFeatureExtractionComplete=False, numericParityPassed=bool(report and report['passed']),
        remainingGaps=[
            'Native bold feature kernels and full policy graph execution remain pending.',
            'Page context is [raw, clip((raw - pageMedian) / max(pageIQR, .02), -8, 8), tiled pageMedian]; preserve feature versions, widths and page membership.',
            'Legacy fill-v1 and complete fill-v2 have distinct distributions; never interchange equal-width arrays.',
            'External reference font packaging, path resolution, variable axes and faceIndex validation remain pending.',
            'Existing glyph RF dependency assets and their feature contracts require a separate inventory/export.',
            'Native raster/feature parity and source-pixel/style/geometry binding remain unverified.',
            'Renderer integration, mixed/regular/bold policy wiring and end-to-end native validation remain pending.',
            'Existing full-source verification is prior Python-source evidence, not native feature/rendering acceptance.',
        ]))
    print(json.dumps(dict(output=str(args.out), heads=len(objects), parityPassed=bool(report and report['passed']))))


if __name__ == '__main__':
    main()
