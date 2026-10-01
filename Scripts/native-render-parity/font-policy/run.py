#!/usr/bin/env python3
"""Differential policies against the frozen browser; no production JS execution."""
import json
import math
import pathlib
import os
import subprocess
import time

ROOT = pathlib.Path(__file__).resolve().parents[3]
BUILD = ROOT / 'build/native-render-parity/font-policy'
BUILD.mkdir(parents=True, exist_ok=True)
OVERLAY = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'
source = pathlib.Path(os.environ.get('NATIVE_TYPOGRAPHY_POLICY_SOURCE', str(OVERLAY / 'NativeTypographyPostPolish.swift'))).read_text()
# Policy/Core Text helpers are shared with production. Only application integration
# is excluded from this macOS host executable (it uses UIKit application models).
(BUILD / 'NativeTypographyPostPolish.swift').write_text(source.split('    /// Frozen inspectSurface range')[0] + '}\n')
start = time.monotonic()
subprocess.run(['swiftc', '-O', str(OVERLAY / 'NativeTranslationTypography.swift'),
                str(BUILD / 'NativeTypographyPostPolish.swift'), str(ROOT / 'Scripts/native-render-parity/font-policy/main.swift'),
                '-o', str(BUILD / 'policy')], cwd=ROOT, check=True)
compile_seconds = time.monotonic() - start
cases = json.loads(subprocess.check_output(['node', 'Scripts/native-render-parity/font-policy/oracle.cjs'], cwd=ROOT))
(BUILD / 'cases.json').write_text(json.dumps(cases, ensure_ascii=False))
start = time.monotonic()
response = subprocess.run([str(BUILD / 'policy')], input='\n'.join(json.dumps(c, ensure_ascii=False) for c in cases)+'\n',
                          text=True, capture_output=True, check=True)
run_seconds = time.monotonic() - start
actual = [json.loads(line) for line in response.stdout.splitlines()]
assert len(actual) == len(cases)

def equivalent(a, b):
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool) and not isinstance(b, bool):
        return math.isclose(a, b, rel_tol=0, abs_tol=1e-10)
    if isinstance(a, dict) and isinstance(b, dict):
        # Swift Codable omits nil optional edges; the oracle encodes null.
        a = {k:v for k,v in a.items() if v is not None}
        b = {k:v for k,v in b.items() if v is not None}
        return a.keys() == b.keys() and all(equivalent(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(equivalent(x,y) for x,y in zip(a,b))
    return type(a) is type(b) and a == b

failures = [{'id':case['id'], 'expected':case['expected'], 'actual':got}
            for case,got in zip(cases,actual) if not equivalent(case['expected'],got)]
report = {'cases':len(cases), 'passed':len(cases)-len(failures), 'failed':len(failures),
          'compileSeconds':compile_seconds, 'executionSeconds':run_seconds,
          'scope':'Frozen font clusters, kept source targets, page style groups, alignment/column links, cohort schedules, flow acceptance.',
          'failures':failures}
(BUILD / 'report.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
print(json.dumps({k:v for k,v in report.items() if k!='failures'}, ensure_ascii=False))
if failures:
    print(json.dumps(failures[:3], ensure_ascii=False))
    raise SystemExit(1)
