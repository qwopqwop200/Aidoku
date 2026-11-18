"""Export only a complete validated reinspection with unchanged geometry."""
import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path
import shutil


def read(p):
    return json.loads(p.read_text())


def viewed_counts(value):
    result = []
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = key.lower().replace('_', '')
            if normalized in ['viewed', 'totalviewed', 'viewedtotal', 'viewedcount', 'totalcropsviewed', 'visuallyreviewed'] and type(child) is int:
                result.append(child)
            if normalized in ['vieweditemids', 'visuallyrevieweditemids'] and isinstance(child, list):
                result.append(len(child))
            if isinstance(child, dict):
                result.extend(viewed_counts(child))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--destination', type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    validation = read(root / 'VALIDATION.json')
    consistency = read(root / 'SOURCE-CONSISTENCY.json')
    if not validation['complete'] or consistency['sourceHashErrors'] or consistency['exactSourceStyleConflicts']:
        raise SystemExit('Incomplete review or unresolved source conflicts; refusing export')
    before = read(root / 'before-appearance-gt.json')
    after = read(root / 'appearance-gt.json')
    manifest = read(root / 'input-manifest.json')
    summaries = list((root / 'shards').glob('*/review.json'))
    if len(summaries) != 64:
        raise SystemExit('Some reviewer completion summaries are still missing')
    protocol_notes = []
    for path in summaries:
        summary = read(path)
        expected = len(read(path.parent / 'assignment.json')['items'])
        counts = viewed_counts(summary)
        if not counts or max(counts) != expected:
            raise SystemExit(f'Full-assignment viewed total missing or incomplete in {path}: {counts}, expected {expected}')
        notes = []
        for key in ['notes', 'workflowNotes']:
            value = summary.get(key, [])
            notes.extend(value if isinstance(value, list) else [value])
        for note in notes:
            if isinstance(note, str) and ('exposed embedded prior' in note or 'procedural exception' in note.lower()):
                protocol_notes.append(dict(shard=path.parent.name, note=note))
    digest = hashlib.sha256((root / 'before-appearance-gt.json').read_bytes()).hexdigest()
    if digest != manifest['sourceStyleGTSHA256']:
        raise SystemExit('Baseline snapshot changed')
    immutable = ['itemID', 'page', 'regionID', 'sourceRegionIDs', 'sourceImageSHA256', 'cropBounds',
                 'pageSize', 'mergedPolygonCrop', 'individualPolygonsCrop', 'maxContextFraction',
                 'crop', 'cropSHA256', 'ownershipMask', 'ownershipMaskSHA256', 'cropSize', 'fontPixels']
    if after['pages'] != before['pages'] or len(after['items']) != len(before['items']):
        raise SystemExit('Dataset coverage changed')
    for a, b in zip(after['items'], before['items']):
        if any(a[k] != b[k] for k in immutable):
            raise SystemExit('Geometry/source metadata changed: ' + a['itemID'])
    if hashlib.sha256(Path(before['sourceGT']).read_bytes()).hexdigest() != before['sourceGTSHA256']:
        raise SystemExit('Segmentation GT changed')
    changes = read(root / 'CHANGES.json')
    changed_fields = Counter(f for d in changes['items'] for f in d['changedFields'])
    dispatch = read(root / 'dispatch.json')['dispatch']
    if len(dispatch) != 64 or any(r.get('status') != 'completed' for r in dispatch):
        raise SystemExit('Wait for all 64 reviewers to finish before exporting')
    report = dict(reviewRound=manifest['reviewRound'], requestedAgents=64, dispatchedAgents=len(dispatch),
        datasetPages=len(after['pages']), pagesWithRegions=after['pagesWithAppearanceItems'],
        expected=validation['expected'], visuallyReviewed=validation['valid'], completedShards=validation['completedShards'],
        actualStyleChanges=changes['styleChanged'], confidenceOnlyChanges=changes['confidenceOnly'], unchanged=changes['unchanged'],
        changedFieldCounts=dict(changed_fields), uncertainItems=len(after['uncertainItems']),
        exactPixelAnchors=sum(len(r['review']['anchors']) for r in after['items']),
        sourceImagesMasksGeometryRelationsUnchanged=True, cropContextMaxEachSide=.15, wholePagesVisuallyOpened=False,
        unresolvedExactSourceConflicts=0, userConfirmed=False, approximatePhysicalMeasurements=True,
        reviewProtocolNotes=protocol_notes,
        dispatchCorrectionNotes=str(root / 'DISPATCH-NOTES.json') if (root / 'DISPATCH-NOTES.json').exists() else None,
        output=str(args.destination.resolve()), review=str(root / 'review/index.html'))
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    if args.destination.exists() and args.destination.read_bytes() != (root / 'appearance-gt.json').read_bytes():
        raise SystemExit('Destination already contains another revision; choose a fresh filename')
    shutil.copyfile(root / 'appearance-gt.json', args.destination)
    report['outputSHA256'] = hashlib.sha256(args.destination.read_bytes()).hexdigest()
    (root / 'FINAL-REPORT.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(report, ensure_ascii=False))


if __name__ == '__main__':
    main()
