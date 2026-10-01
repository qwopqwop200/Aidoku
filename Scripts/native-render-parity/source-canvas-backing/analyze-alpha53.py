#!/usr/bin/env python3
"""Read-only actual iOS alpha gate region isolation, with literal captured geometry."""
import argparse
import hashlib
import json
import math
from pathlib import Path
import numpy as np
from PIL import Image

parser = argparse.ArgumentParser()
parser.add_argument('snapshot', type=Path)
parser.add_argument('output', type=Path)
args = parser.parse_args()
results = []
for background in ['transparent', 'opaque']:
    folder = args.snapshot / background
    document = json.loads((folder / 'web-dom-and-saved-masks.json').read_text())
    metadata = json.loads((folder / 'native-live-backing-capture.json').read_text())
    records = document['records']
    for requested in [160, 320]:
        native_path, web_path = folder / f'native-live-{requested}.rgba', folder / f'web-live-{requested}.rgba'
        size = Image.open(folder / f'web-live-{requested}.png').size
        width, height = size
        native = np.frombuffer(native_path.read_bytes(), dtype=np.uint8).reshape(height, width, 4)
        web = np.frombuffer(web_path.read_bytes(), dtype=np.uint8).reshape(height, width, 4)
        delta = np.abs(native.astype(np.int16) - web.astype(np.int16))
        changed = np.any(delta != 0, axis=2)
        output_scale = width / document['innerWidth']
        backing_scale = metadata['screenScale']
        minified = np.zeros((height, width), dtype=bool)
        regions = []
        for record in records:
            x, y, w, h = record['used']
            # Production liveFrame rounds the two CSS edges independently.
            left, top = math.floor(x + .5), math.floor(y + .5)
            right, bottom = math.floor(x + w + .5), math.floor(y + h + .5)
            bounds = [max(0, math.floor(left * output_scale)), max(0, math.floor(top * output_scale)),
                      min(width, math.ceil(right * output_scale)), min(height, math.ceil(bottom * output_scale))]
            x0, y0, x1, y1 = bounds
            is_minified = (right - left) * backing_scale < record['width'] or (bottom - top) * backing_scale < record['height']
            if is_minified:
                minified[y0:y1, x0:x1] = True
            regions.append({'id': record['id'], 'sourceSize': [record['width'], record['height']],
                            'literalUsedRect': record['used'], 'roundedLiveCSSBounds': [left, top, right, bottom],
                            'outputPixelBounds': bounds, 'minifiedAtBacking': is_minified,
                            'differentRGBApixels': int(changed[y0:y1, x0:x1].sum()),
                            'maxChannelDelta': int(delta[y0:y1, x0:x1].max(initial=0))})
        outside = changed & ~minified
        result = {'background': background, 'requestedWidth': requested, 'size': list(size),
                  'canonicalBackingAccepted': metadata['CGContext'].get('canonicalBackingAccepted'),
                  'differentRGBApixels': int(changed.sum()), 'maxChannelDelta': int(delta.max(initial=0)),
                  'outsideActualMinifiedMasksDifferentRGBApixels': int(outside.sum()),
                  'outsideActualMinifiedMasksMaxChannelDelta': int(delta[~minified].max(initial=0)),
                  'regions': regions,
                  'sha256': {str(p.relative_to(args.snapshot)): hashlib.sha256(p.read_bytes()).hexdigest()
                             for p in [native_path, web_path, folder / 'web-dom-and-saved-masks.json', folder / 'native-live-backing-capture.json']}}
        results.append(result)
        print(background, requested, result['differentRGBApixels'], 'max', result['maxChannelDelta'], 'outside-minified', result['outsideActualMinifiedMasksDifferentRGBApixels'])
        assert result['canonicalBackingAccepted'] is True
        assert result['outsideActualMinifiedMasksDifferentRGBApixels'] == 0
        assert all(r['differentRGBApixels'] == 0 for r in regions if not r['minifiedAtBacking'])
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps({'scope': 'actual iOS53 immutable RGBA, no rendering rerun; original WK oracle unchanged',
                                  'results': results, 'conclusion': 'Expansion/identity and overlap match all RGBA outside the actual minified source mask. Whole alpha capture remains unequal inside that mask.'}, indent=2) + '\n')
