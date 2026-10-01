#!/usr/bin/env python3
"""Compare native scalar policy boxes with captured iOS DOM Range boxes."""
import json, os, pathlib, subprocess, time
root = pathlib.Path(__file__).resolve().parents[3]
build = root / 'build/native-render-parity/scalar-ranges'
build.mkdir(parents=True, exist_ok=True)
source = os.environ.get('NATIVE_TYPOGRAPHY_SOURCE', str(root / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationTypography.swift'))
t0 = time.monotonic()
subprocess.run(['swiftc', '-O', source, str(root / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTextPaintGeometry.swift'), str(pathlib.Path(__file__).with_name('main.swift')), '-o', str(build / 'probe')], check=True)
compile_seconds = time.monotonic() - t0
cases = json.loads(pathlib.Path(__file__).with_name('captured-dom-ranges.json').read_text())
t0 = time.monotonic()
response = subprocess.run([str(build / 'probe')], input=''.join(json.dumps(c, ensure_ascii=False) + '\n' for c in cases), text=True, capture_output=True, check=True)
execution_seconds = time.monotonic() - t0
comparisons = []
for case, result in zip(cases, response.stdout.splitlines()):
    result = json.loads(result)
    actual = [[r[0] + case['origin'][0], r[1] + case['origin'][1], r[2], r[3]] for r in result['ranges']]
    assert len(actual) == len(case['expected'])
    deltas = [max(abs(a-b) for a,b in zip(native, expected)) for native, expected in zip(actual, case['expected'])]
    if 'expectedLines' in case:
        native_lines = [''.join(row.split()) for row in result['text'].split('\n')]
        assert native_lines == case['expectedLines'], (case['id'], native_lines, case['expectedLines'])
    comparisons.append({'id': case['id'], 'scalarCount': len(actual), 'maximumCoordinateDelta': max(deltas), 'actual': actual, 'expected': case['expected']})
report = {'cases': len(cases), 'scalars': sum(c['scalarCount'] for c in comparisons),
          'allScalarsWithinOneCSSLayoutUnit': all(c['maximumCoordinateDelta'] <= 1/64 for c in comparisons),
          'maximumCoordinateDelta': max(c['maximumCoordinateDelta'] for c in comparisons),
          'compileSeconds': compile_seconds, 'executionSeconds': execution_seconds,
          'scope': 'Actual iOS DOM scalar ranges for seven fixtures and eleven cards, including vertical Japanese. Matching CSS-used geometry and fonts are supplied; this isolates the range adapter and does not establish whole-page or raster equality.', 'comparisons': comparisons}
(build / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps({k:v for k,v in report.items() if k != 'comparisons'}, ensure_ascii=False))
assert report['allScalarsWithinOneCSSLayoutUnit']
