#!/usr/bin/env python3
"""Audit verified balloon contours against exact-title, saved PDF paint footprints.

This is a geometric candidate audit, not a claim that a footprint belongs to
the nearest OCR region. Its JSON preserves the chosen footprint for review.
"""
import json
import math
import sys
from pathlib import Path


def rect_edges(rect):
    (x, y), (w, h) = rect
    return x, y, x + w, y + h


def native_contains(balloon, x, y):
    left, top, right, bottom = rect_edges(balloon['rect'])
    if not (left <= x <= right and top <= y <= bottom):
        return False
    spans = balloon['spans']
    row = min(len(spans) // 2 - 1, max(0, int((y - top) / max(bottom - top, 1e-9) * (len(spans) // 2))))
    lo, hi = spans[2 * row:2 * row + 2]
    return lo >= 0 and lo <= x <= hi


def union_coverage(rect_a, rect_b):
    ax0, ay0, ax1, ay1 = rect_a
    bx0, by0, bx1, by1 = rect_b
    overlap = max(0, min(ax1, bx1) - max(ax0, bx0)) * max(0, min(ay1, by1) - max(ay0, by0))
    area = max((ax1 - ax0) * (ay1 - ay0), 1e-9)
    return overlap / area


def main():
    corpus = Path(sys.argv[1])
    output = Path(sys.argv[2])
    mapping = json.loads((corpus / 'baseline-cached' / 'manifest.json').read_text())
    assert str(mapping['galleryID']) == '2842254' and mapping['renderedCount'] == len(mapping['samples'])
    results = []
    for page in mapping['samples']:
        number = page['page']
        source = json.loads((corpus / 'ocr-regions' / f'{number:04}.regions.json').read_text())
        translation_info = json.loads(Path(page['translationJSON']).read_text())
        translated_segments = translation_info.get('selectedSegments', [])
        asset = json.loads(Path(page['layoutAssetJSON']).read_text())
        (_, _), (display_w, display_h) = asset['displayRect']
        bounds = asset['layers']['paintBounds']
        # PDF may contain the same caption in both fill and outline passes.
        unique = []
        for x, y, w, h in bounds:
            edges = (x / display_w, y / display_h, (x + w) / display_w, (y + h) / display_h)
            if any(union_coverage(edges, old) > .75 and union_coverage(old, edges) > .75 for old in unique):
                continue
            unique.append(edges)
        for region in source:
            balloon = region.get('balloonInterior')
            if not balloon or not balloon.get('contourVerified'):
                continue
            (rx, ry), (rw, rh) = region['rect']
            source_center = (rx + rw / 2, ry + rh / 2)
            matching_segments = sorted(translated_segments, key=lambda segment: math.dist(source_center,
                (segment['bounds'][0] + segment['bounds'][2] / 2,
                 segment['bounds'][1] + segment['bounds'][3] / 2)))
            matched_segment = matching_segments[0] if matching_segments else None
            source_match_distance = (math.dist(source_center,
                (matched_segment['bounds'][0] + matched_segment['bounds'][2] / 2,
                 matched_segment['bounds'][1] + matched_segment['bounds'][3] / 2))
                if matched_segment else None)
            translated = bool(matched_segment and source_match_distance < .06 and
                matched_segment['source'] != matched_segment['translation'])
            cx, cy = balloon['center']
            candidates = []
            for footprint in unique:
                x0, y0, x1, y1 = footprint
                fx, fy = (x0 + x1) / 2, (y0 + y1) / 2
                distance = math.hypot(fx - cx, fy - cy)
                candidates.append({
                    'rect': [round(value, 5) for value in footprint],
                    'center': [round(fx, 5), round(fy, 5)],
                    'distance': round(distance, 5),
                    'insideContour': native_contains(balloon, fx, fy),
                })
            candidates.sort(key=lambda item: item['distance'])
            nearest = candidates[0] if candidates else None
            results.append({
                'page': number,
                'regionID': region['id'],
                'source': region['source'],
                'matchedTranslation': matched_segment['translation'] if matched_segment else None,
                'sourceMatchDistance': round(source_match_distance, 5) if source_match_distance is not None else None,
                'translatedCaptionCandidate': translated,
                'balloonCenter': balloon['center'],
                'balloonRect': balloon['rect'],
                'nearestPaint': nearest,
                'secondPaint': candidates[1] if len(candidates) > 1 else None,
                'layoutCache': page['layoutCacheName'],
                'layoutMatchF1': page['layoutMatchF1'],
            })
    summary = {
        'galleryID': mapping['galleryID'],
        'title': mapping['title'],
        'pagesWithMatchedSavedLayout': len(mapping['samples']),
        'verifiedContoursAudited': len(results),
        'translatedCaptionCandidates': sum(r['translatedCaptionCandidate'] for r in results),
        'translatedCandidatesOutsideContour': sum(r['translatedCaptionCandidate'] and
            not (r['nearestPaint'] and r['nearestPaint']['insideContour']) for r in results),
        'nearestPaintOutsideContour': sum(not (r['nearestPaint'] and r['nearestPaint']['insideContour']) for r in results),
        'nearestPaintDistanceOver0_1': sum(not r['nearestPaint'] or r['nearestPaint']['distance'] > .1 for r in results),
        'warning': 'Nearest paintBounds are candidate captions; ambiguous assignment requires text and image review.',
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({'summary': summary, 'rows': results}, ensure_ascii=False, indent=2))
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == '__main__':
    main()
