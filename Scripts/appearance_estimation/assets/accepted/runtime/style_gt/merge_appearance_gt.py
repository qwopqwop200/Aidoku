"""Validate visually authored appearance labels and merge source-bound GT JSON."""
import argparse
from collections import Counter, defaultdict
import hashlib
import json
import math
import copy
from pathlib import Path
from PIL import Image


def load(path):
    return json.loads(path.read_text())


def rgb(value):
    return isinstance(value, list) and len(value) == 3 and all(type(c) is int and 0 <= c <= 255 for c in value)


def numeric(value):
    return type(value) in [int, float] and math.isfinite(value)


def validate(record, source):
    errors, warnings = [], []
    item = source['itemID']
    review = record.get('review', {})
    if record.get('itemID') != item:
        errors.append('itemID mismatch')
    if review.get('reviewed') is not True:
        errors.append('not visually reviewed')
    if review.get('viewedImagePath') != source['crop']:
        errors.append('viewedImagePath does not match original crop')
    if review.get('cropSHA256') != source['cropSHA256']:
        errors.append('view receipt crop SHA mismatch')
    if not isinstance(review.get('observations'), str) or len(review['observations'].strip()) < 12:
        errors.append('missing individual technical observation')
    if not isinstance(review.get('uncertainFields'), list):
        errors.append('uncertainFields must be a list')
    for field in ['fill', 'outline', 'shadow', 'background']:
        value = record.get(field)
        if not isinstance(value, dict):
            errors.append(field + ' missing')
            continue
        if value.get('rgb') is not None and not rgb(value['rgb']):
            errors.append(field + '.rgb invalid')
        confidence = value.get('confidence')
        if not numeric(confidence) or not 0 <= confidence <= 1:
            errors.append(field + '.confidence invalid')
        if value.get('rgb') is None and field in ['fill', 'background'] and not review.get('uncertainFields'):
            errors.append(field + ' unknown without explanation')
    fill = record.get('fill', {})
    if fill.get('mode') not in ['solid', 'gradient', 'multicolor', 'unknown']:
        errors.append('fill.mode invalid')
    if any(not rgb(c) for c in fill.get('colors', [])):
        errors.append('fill.colors invalid')
    outline = record.get('outline', {})
    if outline.get('present') not in [True, False, None]:
        errors.append('outline.present invalid')
    width = outline.get('widthPx')
    if width is not None and (not numeric(width) or width < 0):
        errors.append('outline.widthPx invalid')
    bounds = outline.get('widthRangePx')
    if bounds is not None:
        if not isinstance(bounds, list) or len(bounds) != 2 or not all(numeric(n) and n >= 0 for n in bounds) or bounds[0] > bounds[1]:
            errors.append('outline.widthRangePx invalid')
        elif numeric(width) and not bounds[0] <= width <= bounds[1]:
            errors.append('outline width outside stated interval')
    if outline.get('present') is False and (width not in [0, None] or outline.get('rgb') is not None or outline.get('layers')):
        errors.append('absent outline has paint/width')
    if outline.get('present') is True and width == 0:
        errors.append('visible outline has zero width')
    if numeric(width) and width > source['fontPixels'] * .35:
        warnings.append('outline width unusually large relative to source text')
    shadow = record.get('shadow', {})
    if shadow.get('present') not in [True, False, None]:
        errors.append('shadow.present invalid')
    offset = shadow.get('offsetPx')
    if offset is not None and (not isinstance(offset, list) or len(offset) != 2 or not all(numeric(c) for c in offset)):
        errors.append('shadow.offsetPx invalid')
    opacity = shadow.get('opacity')
    if opacity is not None and (not numeric(opacity) or not 0 <= opacity <= 1):
        errors.append('shadow.opacity invalid')
    if record.get('background', {}).get('mode') not in ['flat', 'gradient', 'textured', 'mixed', 'unknown']:
        errors.append('background.mode invalid')
    anchors = review.get('anchors', [])
    if len(anchors) < 2:
        errors.append('fewer than two source pixel anchors')
    roles = {a.get('role') for a in anchors if isinstance(a, dict)}
    if 'fill' not in roles or 'background' not in roles:
        errors.append('fill/background anchors missing')
    image = None
    for a in anchors:
        xy = a.get('xy', [])
        if not isinstance(xy, list) or len(xy) != 2 or not all(type(n) is int for n in xy):
            errors.append('invalid pixel anchor coordinates')
            continue
        if not 0 <= xy[0] < source['cropSize'][0] or not 0 <= xy[1] < source['cropSize'][1]:
            errors.append('pixel anchor outside crop')
            continue
        if not rgb(a.get('rgb')):
            errors.append('pixel anchor RGB invalid')
            continue
        if image is None:
            image = Image.open(source['crop']).convert('RGB')
        actual = list(image.getpixel(tuple(xy)))
        if a['rgb'] != actual:
            errors.append(f"anchor {a.get('role')} {xy}: RGB {a['rgb']} != source {actual}")
    if fill.get('rgb') == record.get('background', {}).get('rgb') and outline.get('present') is False and record.get('background', {}).get('mode') == 'flat':
        warnings.append('fill equals flat background without a visible outline')
    for substyle in record.get('substyles', []):
        rect = substyle.get('rectCrop')
        if (not isinstance(rect, list) or len(rect) != 4 or not all(numeric(n) for n in rect)
                or min(rect[:2]) < 0 or min(rect[2:]) <= 0 or rect[0] + rect[2] > source['cropSize'][0]
                or rect[1] + rect[3] > source['cropSize'][1]):
            errors.append('substyle rectangle invalid or outside crop')
        for field in ['fill', 'outline', 'shadow', 'background']:
            if field in substyle and substyle[field].get('rgb') is not None and not rgb(substyle[field]['rgb']):
                errors.append('substyle ' + field + ' RGB invalid')
    return errors, warnings


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, required=True)
    parser.add_argument('--partial', action='store_true')
    args = parser.parse_args()
    root = args.root
    manifest = load(root / 'input-manifest.json')
    dispatch = {r['shard']: r for r in load(root / 'dispatch.json')['dispatch'] if 'agent_id' in r}
    source_index = {r['itemID']: r for r in manifest['items']}
    adjudication_path = root / 'ADJUDICATIONS.json'
    adjudications = load(adjudication_path)['items'] if adjudication_path.exists() else {}
    accepted, missing, invalid, warnings, shards = [], [], [], [], []
    extras = []
    for shard in range(64):
        folder = root / 'shards' / f'{shard:02d}'
        assignment = load(folder / 'assignment.json')
        expected = {r['itemID'] for r in assignment['items']}
        found = {p.stem for p in (folder / 'review-items').glob('*.json')}
        extras += [dict(shard=shard, itemID=i) for i in sorted(found - expected)]
        complete = 0
        for item in assignment['items']:
            id = item['itemID']
            path = folder / 'review-items' / (id + '.json')
            if not path.exists():
                missing.append(dict(shard=shard, itemID=id))
                continue
            try:
                record = load(path)
                if isinstance(record.get('style'), dict):
                    record = dict(record, **record['style'])
                errors, issues = validate(record, item)
                if not errors and id in adjudications:
                    record = copy.deepcopy(record)
                    correction = adjudications[id]
                    for field, value in correction['overrides'].items():
                        record[field] = value
                    record['review']['adjudications'] = [correction['evidence']]
                    if correction.get('uncertainFields'):
                        record['review']['uncertainFields'] = sorted(set(record['review']['uncertainFields'] + correction['uncertainFields']))
                    errors, issues = validate(record, item)
            except Exception as error:
                invalid.append(dict(shard=shard, itemID=id, errors=[str(error)]))
                continue
            if errors:
                invalid.append(dict(shard=shard, itemID=id, errors=errors))
                continue
            if issues:
                warnings.append(dict(shard=shard, itemID=id, warnings=issues))
            source = {k: v for k, v in item.items() if k != 'suggestions'}
            record = {k: record[k] for k in ['fill', 'outline', 'shadow', 'background', 'review', 'substyles'] if k in record}
            record['review']['agentID'] = dispatch.get(shard, {}).get('agent_id')
            record['review']['agentNickname'] = dispatch.get(shard, {}).get('nickname')
            record['review']['shard'] = shard
            for field in ['fill', 'outline', 'shadow', 'background']:
                value = record[field].get('rgb')
                record[field]['hex'] = '#' + ''.join(f'{v:02X}' for v in value) if value is not None else None
            width = record['outline'].get('widthPx')
            record['outline']['widthRelativeToReferenceFont'] = width / item['fontPixels'] if numeric(width) else None
            for anchor in record['review']['anchors']:
                anchor['imageXY'] = [item['cropBounds'][0] + anchor['xy'][0], item['cropBounds'][1] + anchor['xy'][1]]
            accepted.append(dict(**source, **record))
            complete += 1
        shards.append(dict(shard=shard, expected=len(expected), valid=complete, found=len(found),
                           agentID=dispatch.get(shard, {}).get('agent_id')))
    by_id = {r['itemID']: r for r in accepted}
    accepted = [by_id[r['itemID']] for r in manifest['items'] if r['itemID'] in by_id]
    uncertain = [r['itemID'] for r in accepted if r['review']['uncertainFields'] or
                 any(r[f].get('confidence', 0) < .75 for f in ['fill', 'outline', 'shadow', 'background'])]
    field_counts = Counter()
    for r in accepted:
        for field in ['fill', 'outline', 'shadow', 'background']:
            if r[field].get('confidence', 0) < .75:
                field_counts[field] += 1
    complete = len(accepted) == len(manifest['items']) and not missing and not invalid and not extras
    status = dict(expected=len(manifest['items']), valid=len(accepted), complete=complete,
        requestedAgents=64, dispatchedAgents=len(dispatch), completedShards=sum(s['valid'] == s['expected'] for s in shards),
        missing=missing, invalid=invalid, unexpectedItems=extras, warnings=warnings,
        uncertainItems=uncertain, lowConfidenceFieldCounts=dict(field_counts), shards=shards)
    (root / 'VALIDATION.json').write_text(json.dumps(status, ensure_ascii=False, indent=2) + '\n')
    if complete:
        segmentation = load(Path(manifest['inputGT']))
        merged_path = Path(manifest['inputGT']).parent / segmentation['sourceMergedGT']
        merged = load(merged_path)
        items_by_page = defaultdict(list)
        for r in accepted:
            items_by_page[r['page']].append(r['itemID'])
        pages = [dict(page=p['page'], width=p.get('width'), height=p.get('height'),
                      sourceImageSHA256=p.get('imageSha256'), itemIDs=items_by_page[p['page']],
                      itemCount=len(items_by_page[p['page']])) for p in merged['pages']]
        output = dict(schema='aidoku-original-text-appearance-gt-v1', annotationOrigin='64-agent-individual-source-crop-visual-annotation',
            userConfirmed=False, sourceGT=manifest['inputGT'], sourceGTSHA256=manifest['inputGTSHA256'],
            scope='original source appearance, not translated display choices', coordinateSystem='original-crop-pixels RGB sRGB',
            itemCount=len(accepted), sourceCropContextMaxEachSide=.15, wholePagesVisuallyOpened=False,
            sourceImagesAndSegmentationGTChanged=False, agentCount=64, everyItemVisuallyReviewed=True,
            pixelAnchorsVerified=True, approximatePhysicalMeasurements=True, uncertainItems=uncertain,
            sourceMergedGT=str(merged_path.resolve()), pages=pages, sourceDatasetPageCount=len(pages),
            pagesWithAppearanceItems=sum(bool(p['itemIDs']) for p in pages), items=accepted)
        (root / 'appearance-gt.json').write_text(json.dumps(output, ensure_ascii=False, indent=2) + '\n')
    elif not args.partial:
        raise SystemExit('Annotation set incomplete or invalid; see VALIDATION.json')
    print(json.dumps({k: status[k] for k in ['expected', 'valid', 'complete', 'dispatchedAgents', 'completedShards']}, ensure_ascii=False))
    print('invalid', len(invalid), 'missing', len(missing), 'warnings', len(warnings))


if __name__ == '__main__':
    main()
