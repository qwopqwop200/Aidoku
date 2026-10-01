#!/usr/bin/env python3
"""Compare all seven native caption/panel policies with frozen production JavaScript."""
import argparse
import hashlib
import json
import os
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/native-render-parity/caption-policy')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixtures_file, actual_file = output / 'fixtures.json', output / 'actual.json'
    reference = ROOT / 'Scripts/native-render-parity/reference-source/BrowserSourceTextColor.swift'
    overlay = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay'
    sources = [overlay / name for name in ['NativeTranslationPixelKernels.swift', 'NativeSourceColorSampler.swift', 'NativeCaptionSourcePalette.swift']]
    build_started = time.monotonic()
    subprocess.run(['python3', str(ROOT / 'Scripts/overlay-kernels/native/build.py')], check=True, cwd=ROOT,
                   env=dict(os.environ, PLATFORM_NAME='macosx', ARCHS='arm64', DERIVED_FILE_DIR=str(ROOT / 'build/native-overlay-kernels-host')))
    executable = output / 'policy-probe'
    subprocess.run(['xcrun', 'swiftc', '-O', '-I', str(ROOT / 'Scripts/overlay-kernels/native'), *map(str, sources),
                    str(DIRECTORY / 'Probe.swift'), str(ROOT / 'build/native-overlay-kernels-host/libAidokuOverlayKernels.a'), '-o', str(executable)], check=True, cwd=ROOT)
    build_seconds = time.monotonic() - build_started
    started = time.monotonic()
    with (output / 'frozen-regressions.log').open('w') as log:
        subprocess.run(['node', str(DIRECTORY / 'capture.cjs'), str(fixtures_file), '--source', str(reference)], check=True, cwd=ROOT, stdout=log)
    subprocess.run([str(executable), str(fixtures_file), str(actual_file)], check=True, cwd=ROOT)
    fixtures, actual = json.loads(fixtures_file.read_text()), json.loads(actual_file.read_text())
    assert len(fixtures) == len(actual), 'Native runner omitted captured calls'
    policy = {}
    details = []
    for index, (fixture, result) in enumerate(zip(fixtures, actual)):
        name = fixture['name']
        row = policy.setdefault(name, {'calls': 0, 'exact': 0, 'active': 0, 'mismatches': []})
        original = fixture['args'][3] if name == 'recoverOutlinedColor' else fixture['args'][4] if len(fixture['args']) > 4 else None
        active = result is not None and result != original
        exact = result == fixture['expected']
        row['calls'] += 1
        row['exact'] += int(exact)
        row['active'] += int(active)
        if not exact:
            row['mismatches'].append(index)
            details.append({'index': index, 'name': name, 'expected': fixture['expected'], 'actual': result})
    passed = len(policy) == 7 and all(row['calls'] == row['exact'] and row['active'] > 0 for row in policy.values())
    report = {'passed': passed, 'fixtureCount': len(fixtures), 'policies': policy, 'mismatches': details,
              'buildSeconds': build_seconds, 'testSeconds': time.monotonic() - started,
              'referenceSHA256': hashlib.sha256(reference.read_bytes()).hexdigest(),
              'sourceSHA256': {source.name: hashlib.sha256(source.read_bytes()).hexdigest() for source in sources},
              'fixtureSHA256': hashlib.sha256(fixtures_file.read_bytes()).hexdigest(),
              'comparison': 'All descriptor fields, array values, nested confidence/evidence, nullability and floating values compare exactly.'}
    (output / 'report.json').write_text(json.dumps(report, indent=2))
    lines = ['| Policy | Exact calls | Active updates | Result |', '|---|---:|---:|---|']
    for name, row in policy.items():
        status = 'PASS' if row['calls'] == row['exact'] and row['active'] else 'FAIL'
        lines.append(f"| {name} | {row['exact']}/{row['calls']} | {row['active']} | {status} |")
    (output / 'report.md').write_text('\n'.join(lines) + '\n')
    print('\n'.join(lines))
    print(f"{'PASS' if passed else 'FAIL'}: {len(fixtures)} policy calls; {output / 'report.json'}")
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
