"""Audit a completed ReaderSlantedTextTests dataset replay, including positive controls.

Usage: python3 Scripts/tests/audit-slanted-artwork.py SIMULATOR/Documents/SlantedText/results
The directory must contain all current manifest cases; missing/skipped work fails.
"""
import argparse
import json
import math
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('results', type=Path)
parser.add_argument('--output', type=Path)
parser.add_argument('--test-summary', type=Path, help='xcresult summary JSON; reject artifacts older than this run')
args = parser.parse_args()
test_summary = json.loads(args.test_summary.read_text()) if args.test_summary else None
base = Path(__file__).resolve().parent
fixtures = json.loads((base / 'fixtures/slanted-text.json').read_text())
pixel_controls = json.loads((base / 'fixtures/slanted-artwork-pixels.json').read_text())['cases']
positive = {f['id'] for f in pixel_controls if f.get('renderExpectation', 'required') == 'required'}
negative = {f['id'] for f in json.loads((base / 'fixtures/slanted-artwork-rejections.json').read_text())['cases']}
summary = {'fixtures': len(fixtures), 'pairs': 0, 'restored': [], 'retained': [], 'geometryFallback': [],
           'pixelPositiveControls': len(pixel_controls), 'positiveControls': len(positive), 'negativeControls': len(negative),
           'minimumRestoredContrast': 100.0, 'failures': []}

def check(condition, fixture, message):
    if not condition:
        summary['failures'].append({'fixture': fixture, 'message': message})

for f in fixtures:
    for mode in ['colors-inpaint', 'colors-panel', 'white-inpaint', 'white-panel']:
        prefix = args.results / f"{f['id']}-{mode}"
        paths = [Path(str(prefix) + '-' + stage + ext)
                 for stage in ['before', 'after'] for ext in ['.json', '.png']]
        if not all(p.is_file() for p in paths):
            check(False, f['id'], f'missing {mode} replay artifacts')
            continue
        if test_summary:
            check(all(p.stat().st_mtime >= test_summary['startTime'] for p in paths),
                  f['id'], f'stale {mode} replay artifacts from an earlier run')
        summary['pairs'] += 1
        audit = json.loads(paths[2].read_text())['audit']
        check(audit['text'] == f['translation'], f['id'], 'changed translation text')
        check(not audit['overflow'], f['id'], 'text overflow')
        check(abs(math.degrees(audit['rotation']) - f['expectedAngle']) < .06, f['id'], 'rotation mismatch')
        if not f['expectedRotation']:
            check(paths[1].read_bytes() == paths[3].read_bytes(), f['id'], 'geometry fallback differs from ordinary control')
            if mode == 'colors-inpaint':
                summary['geometryFallback'].append(f['id'])
            continue
        check(audit.get('axisAlignedPanels') == 0, f['id'], 'separate upright readability plate')
        if mode != 'colors-inpaint':
            continue
        restored = audit.get('slantedSourceErased') == 'true'
        check(audit['background'] == 'rgba(0, 0, 0, 0)', f['id'], 'opaque rotated replacement plate')
        check(audit.get('slantedMasks') == int(restored), f['id'], 'erasure not committed atomically')
        check(audit.get('visibility') == ('visible' if restored else 'hidden'), f['id'], 'partial replacement')
        if restored:
            summary['restored'].append(f['id'])
            original_font = float(audit['slantedOriginalFont'])
            floor = min(original_font, max(8.5, min(18, original_font * .8), 5))
            check(audit['font'] >= floor - .01, f['id'], 'artwork fitting sacrificed readable font size')
            contrast = float(audit['sourceContrastAfter'])
            check(contrast >= 4.5, f['id'], 'insufficient restored-surface contrast')
            summary['minimumRestoredContrast'] = min(summary['minimumRestoredContrast'], contrast)
        else:
            summary['retained'].append(f['id'])
        if f['id'] in positive:
            check(restored, f['id'], 'reviewed recoverable positive control was silently omitted')
        if f['id'] in negative:
            check(not restored, f['id'], 'reviewed partial reconstruction was committed')
check(positive <= {f['id'] for f in fixtures}, 'manifest', 'positive control missing from replay manifest')
check(negative <= {f['id'] for f in fixtures}, 'manifest', 'negative control missing from replay manifest')
if test_summary:
    check(test_summary['failedTests'] == 0 and test_summary['passedTests'] > 0,
          'test-run', 'Release tests did not pass')
if args.output:
    args.output.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
print(json.dumps({k: (len(v) if isinstance(v, list) else v) for k, v in summary.items()}, indent=2))
if summary['failures']:
    print(json.dumps(summary['failures'], ensure_ascii=False, indent=2))
    raise SystemExit(1)
