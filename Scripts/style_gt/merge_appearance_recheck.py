"""Validate independent review rounds while preserving source geometry and prior GT."""
import argparse
import copy
import hashlib
import json
from collections import defaultdict
from pathlib import Path
from merge_appearance_gt import validate, numeric, rgb

FIELDS = ['fill', 'outline', 'shadow', 'background', 'substyles']


def read(p):
    return json.loads(p.read_text())


def write(p, obj):
    temporary = p.with_suffix(p.suffix + '.tmp')
    temporary.write_text(json.dumps(obj, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(p)


def semantic(value):
    if isinstance(value, dict):
        return {k: semantic(v) for k, v in value.items()
                if k not in ['confidence', 'hex', 'widthRelativeToReferenceFont']}
    if isinstance(value, list):
        return [semantic(v) for v in value]
    return value


def recheck_errors(record):
    errors = []
    rc = record.get('recheck', {})
    if rc.get('decision') not in ['keep', 'adjusted', 'uncertain'] or rc.get('comparedWithPrevious') is not True or rc.get('reviewedAllLayers') is not True:
        errors.append('fresh recheck receipt missing or invalid')
    if not all(isinstance(rc.get(k), list) for k in ['problemsFound', 'adjustmentReasons']):
        errors.append('recheck reason lists missing')
    for field in ['outline', 'shadow']:
        if record.get(field, {}).get('present') is True and record[field].get('rgb') is None and not record.get('review', {}).get('uncertainFields'):
            errors.append(field + ' has unresolved paint without uncertainty')
    shadow = record.get('shadow', {})
    if shadow.get('kind') not in ['none', 'drop', 'glow', 'mixed', 'unknown']:
        errors.append('shadow.kind invalid')
    blur = shadow.get('blurRadiusPx')
    if blur is not None and (not numeric(blur) or blur < 0):
        errors.append('shadow blur invalid')
    for layer in record.get('outline', {}).get('layers', []):
        if not isinstance(layer, dict) or (layer.get('rgb') is not None and not rgb(layer['rgb'])):
            errors.append('outline layer RGB invalid')
            continue
        width, bounds = layer.get('widthPx'), layer.get('widthRangePx')
        if width is not None and (not numeric(width) or width < 0):
            errors.append('outline layer width invalid')
        if bounds is not None and (not isinstance(bounds, list) or len(bounds) != 2 or
                not all(numeric(v) and v >= 0 for v in bounds) or bounds[0] > bounds[1] or
                numeric(width) and not bounds[0] <= width <= bounds[1]):
            errors.append('outline layer width range invalid')
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--partial', action='store_true')
    args = parser.parse_args()
    root = args.root.resolve()
    manifest = read(root / 'input-manifest.json')
    baseline = read(root / 'before-appearance-gt.json')
    before = {r['itemID']: r for r in baseline['items']}
    dispatch = {r['shard']: r for r in read(root / 'dispatch.json')['dispatch']}
    corrections = read(root / 'ADJUDICATIONS.json').get('items', {}) if (root / 'ADJUDICATIONS.json').exists() else {}
    accepted, missing, invalid, warnings, extras, diffs, shards = [], [], [], [], [], [], []
    for n in range(64):
        folder = root / 'shards' / f'{n:02d}'
        assignment = read(folder / 'assignment.json')['items']
        expected = {r['itemID'] for r in assignment}
        extras.extend(str(p) for p in (folder / 'review-items').glob('*.json') if p.stem not in expected)
        count = 0
        for source in assignment:
            item = source['itemID']
            path = folder / 'review-items' / (item + '.json')
            if not path.exists():
                missing.append(dict(shard=n, itemID=item))
                continue
            try:
                record = read(path)
                if isinstance(record.get('style'), dict):
                    record.update(record.pop('style'))
                rc = record.get('recheck', {})
                errors, issues = validate(record, source)
                errors.extend(recheck_errors(record))
                if item in corrections:
                    correction = corrections[item]
                    record.update(copy.deepcopy(correction['overrides']))
                    record['review'].setdefault('adjudications', []).append(correction['evidence'])
                    if any(semantic(record.get(f)) != semantic(before[item].get(f)) for f in FIELDS):
                        rc['decision'] = 'adjusted'
                        rc.setdefault('adjustmentReasons', []).append('Parent crop adjudication: ' + correction['evidence']['observation'])
                    errors, issues = validate(record, source)
                    errors.extend(recheck_errors(record))
                if errors:
                    invalid.append(dict(shard=n, itemID=item, errors=errors))
                    continue
                old = before[item]
                new = copy.deepcopy(old)
                for field in FIELDS:
                    new[field] = copy.deepcopy(record.get(field, [] if field == 'substyles' else {}))
                new['review'] = record['review']
                new['recheck'] = rc
                new['review'].update(agentID=dispatch[n]['agent_id'], agentNickname=dispatch[n].get('nickname'), shard=n, round=manifest['reviewRound'])
                for field in FIELDS[:4]:
                    rgb = new[field].get('rgb')
                    new[field]['hex'] = '#' + ''.join(f'{c:02X}' for c in rgb) if rgb is not None else None
                width = new['outline'].get('widthPx')
                new['outline']['widthRelativeToReferenceFont'] = width / source['fontPixels'] if numeric(width) else None
                for anchor in new['review']['anchors']:
                    anchor['imageXY'] = [source['cropBounds'][i] + anchor['xy'][i] for i in range(2)]
                changed = [f for f in FIELDS if semantic(old.get(f, [])) != semantic(new[f])]
                confidence = [f for f in FIELDS[:4] if old[f].get('confidence') != new[f].get('confidence')]
                if changed or confidence:
                    diffs.append(dict(itemID=item, changedFields=changed, confidenceOnly=not changed,
                                      before={f: old.get(f, []) for f in changed},
                                      after={f: new[f] for f in changed}, recheck=rc))
                if issues:
                    warnings.append(dict(itemID=item, warnings=issues))
                accepted.append(new)
                count += 1
            except Exception as error:
                invalid.append(dict(shard=n, itemID=item, errors=[str(error)]))
        shards.append(dict(shard=n, valid=count, expected=len(assignment)))
    by_id = {r['itemID']: r for r in accepted}
    accepted = [by_id[r['itemID']] for r in manifest['items'] if r['itemID'] in by_id]
    complete = len(accepted) == len(before) == manifest['itemCount'] and not missing and not invalid and not extras
    status = dict(expected=len(before), valid=len(accepted), complete=complete, missing=missing, invalid=invalid,
                  unexpectedItems=extras, warnings=warnings, completedShards=sum(s['valid'] == s['expected'] for s in shards), shards=shards)
    write(root / 'VALIDATION.json', status)
    write(root / 'CHANGES.json', dict(styleChanged=sum(not d['confidenceOnly'] for d in diffs),
        confidenceOnly=sum(d['confidenceOnly'] for d in diffs), unchanged=len(accepted)-len(diffs), items=diffs))
    groups = defaultdict(list)
    for r in accepted:
        groups[(r['cropSHA256'], json.dumps(r['mergedPolygonCrop'], sort_keys=True))].append(r)
    conflicts = []
    for rows in groups.values():
        if len(rows) < 2:
            continue
        for field in FIELDS[:4]:
            signatures = {json.dumps(semantic(r[field]), sort_keys=True) for r in rows}
            if len(signatures) > 1:
                conflicts.append(dict(itemIDs=[r['itemID'] for r in rows], field=field,
                                      values=[r[field] for r in rows]))
    write(root / 'DUPLICATE-CONSISTENCY.json', dict(reviewComplete=complete, conflicts=conflicts))
    if complete:
        source_errors = []
        for r in accepted:
            for field, digest in [('crop', 'cropSHA256'), ('ownershipMask', 'ownershipMaskSHA256')]:
                if hashlib.sha256(Path(r[field]).read_bytes()).hexdigest() != r[digest]:
                    source_errors.append(dict(itemID=r['itemID'], field=field))
        write(root / 'SOURCE-CONSISTENCY.json', dict(sourceHashErrors=source_errors, exactSourceStyleConflicts=conflicts))
        if source_errors:
            raise SystemExit('Source hashes changed; refusing final output')
        output = copy.deepcopy(baseline)
        output.update(items=accepted, reviewRound=manifest['reviewRound'], annotationOrigin='64-agent-independent-source-crop-review',
                      priorAppearanceGT=manifest['sourceStyleGT'], priorAppearanceGTSHA256=manifest['sourceStyleGTSHA256'],
                      priorSnapshot=str(root / 'before-appearance-gt.json'))
        output['uncertainItems'] = [r['itemID'] for r in accepted if r['review']['uncertainFields'] or any(r[f]['confidence'] < .75 for f in FIELDS[:4])]
        write(root / 'appearance-gt.json', output)
    elif not args.partial:
        raise SystemExit('Review incomplete; see VALIDATION.json')
    print(json.dumps({k: status[k] for k in ['expected', 'valid', 'complete', 'completedShards']}))
    print('invalid', len(invalid), 'missing', len(missing))


if __name__ == '__main__':
    main()
