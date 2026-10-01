#!/usr/bin/env python3
"""Compare all native observed source-palette policies to frozen JS values."""
import json
import math
from pathlib import Path
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / 'build/native-render-parity/observed-palettes'
OUT.mkdir(parents=True, exist_ok=True)
subprocess.run(['node', str(Path(__file__).with_name('oracle.cjs')), str(OUT / 'cases.json')], cwd=ROOT, check=True)
sources = [ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay' / name for name in
           ['NativeTranslationPixelKernels.swift', 'NativeObservedSourcePalette.swift']]
binary = OUT / 'native-observed-palettes'
started = time.monotonic()
subprocess.run(['swiftc', '-O', '-I', str(ROOT / 'Scripts/overlay-kernels/native'),
                '-L', str(ROOT / 'build/native-overlay-kernels-host'), '-lAidokuOverlayKernels',
                *map(str, sources), str(Path(__file__).with_name('main.swift')), '-o', str(binary)], cwd=ROOT, check=True)
build_seconds = time.monotonic() - started
cases = json.loads((OUT / 'cases.json').read_text())
payload = '\n'.join(json.dumps({k: v for k, v in case.items() if k != 'expected'}) for case in cases) + '\n'
started = time.monotonic()
result = subprocess.run([str(binary)], input=payload, text=True, capture_output=True, check=True)
run_seconds = time.monotonic() - started
rows = [json.loads(line) for line in result.stdout.splitlines()]
assert len(rows) == len(cases), (len(rows), len(cases), result.stderr)

def difference(expected, actual, path=''):
    if isinstance(expected, dict) and isinstance(actual, dict):
        if expected.keys() != actual.keys():
            return f'{path} keys expected={sorted(expected)} actual={sorted(actual)}'
        for key in expected:
            error = difference(expected[key], actual[key], f'{path}/{key}')
            if error:
                return error
        return None
    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            return f'{path} length expected={len(expected)} actual={len(actual)}'
        for index, (lhs, rhs) in enumerate(zip(expected, actual)):
            error = difference(lhs, rhs, f'{path}/{index}')
            if error:
                return error
        return None
    if isinstance(expected, (int, float)) and isinstance(actual, (int, float)):
        if math.isclose(expected, actual, rel_tol=0, abs_tol=1e-10):
            return None
    elif expected == actual:
        return None
    return f'{path} expected={expected!r} actual={actual!r}'

failures = []
for case, actual in zip(cases, rows):
    error = difference(case['expected'], actual)
    if error:
        failures.append({'id': case['id'], 'difference': error, 'expected': case['expected'], 'actual': actual})
report = {'cases': len(cases), 'matched': len(cases) - len(failures), 'failed': len(failures),
          'buildSeconds': build_seconds, 'runSeconds': run_seconds, 'numericTolerance': 1e-10,
          'scope': 'observed palette policies; identical bounded RGBA; frozen JS plus native Rust CPU loops', 'failures': failures}
(OUT / 'report.json').write_text(json.dumps(report, indent=2))
print(json.dumps({key: value for key, value in report.items() if key != 'failures'}))
for failure in failures[:20]:
    print(failure['id'], failure['difference'])
raise SystemExit(bool(failures))
