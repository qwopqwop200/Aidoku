#!/usr/bin/env python3
"""Independently compare actual native forceSource with the immutable JS oracle."""
import argparse
import hashlib
import json
import subprocess
import time
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = Path(__file__).resolve().parent


def difference(expected, actual, path=''):
    if isinstance(expected, dict) and isinstance(actual, dict):
        for key in sorted(expected.keys() | actual.keys()):
            if key not in expected or key not in actual:
                return {'path': path + '.' + key, 'expected': expected.get(key, 'MISSING'), 'actual': actual.get(key, 'MISSING')}
            found = difference(expected[key], actual[key], path + '.' + key)
            if found:
                return found
        return None
    if isinstance(expected, list) and isinstance(actual, list):
        if len(expected) != len(actual):
            return {'path': path + '.length', 'expected': len(expected), 'actual': len(actual)}
        for index, (a, b) in enumerate(zip(expected, actual)):
            found = difference(a, b, path + '[' + str(index) + ']')
            if found:
                return found
        return None
    return None if expected == actual else {'path': path, 'expected': expected, 'actual': actual}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/native-render-parity/forced-source-policy')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    reference = ROOT / 'Scripts/native-render-parity/reference-source'
    names = ['BrowserSourceTextColor', 'BrowserSourcePanelRestoration', 'BrowserSourceGlyphSegmentation',
             'BrowserSourceGlyphConservative', 'BrowserForcedInpaintQuality', 'BrowserForcedSourceInpainting']
    manifest = json.loads((reference / 'manifest.json').read_text())['files']
    hashes = {}
    for name in names:
        file = reference / (name + '.swift')
        digest = hashlib.sha256(file.read_bytes()).hexdigest()
        expected = manifest['Aidoku/Core/Translation/NativeEngine/Overlay/' + file.name]
        assert digest == expected, 'Frozen oracle modified: ' + file.name
        hashes[file.name] = digest
    sources = [ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay' / (name + '.swift')
               for name in ['NativeTypedArrayFill', 'NativeResidualProof', 'NativeSourceGlyphSegmentation', 'NativeForcedSourceInpainting']]
    started = time.monotonic()
    executable = output / 'native-probe'
    subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-strict-concurrency=complete',
                    *map(str, sources), str(DIRECTORY / 'Probe.swift'), '-o', str(executable)], check=True, cwd=ROOT)
    build_seconds = time.monotonic() - started
    started = time.monotonic()
    fixtures_file, actual_file = output / 'fixtures.json', output / 'actual.json'
    with (output / 'oracle.log').open('w') as log:
        subprocess.run(['node', str(DIRECTORY / 'capture.cjs'), str(ROOT), str(fixtures_file)], check=True, cwd=ROOT, stdout=log)
    subprocess.run([str(executable), str(fixtures_file), str(actual_file)], check=True, cwd=ROOT)
    fixtures = json.loads(fixtures_file.read_text())
    actual = json.loads(actual_file.read_text())
    assert len(fixtures) == len(actual) == 45, 'Fixture omission'
    rows = []
    mismatches = []
    for fixture, observed in zip(fixtures, actual):
        mismatch = difference(fixture['expected'], observed)
        result = observed['result']
        row = {'name': fixture['name'], 'exact': mismatch is None, 'accepted': result is not None,
               'failure': observed['failure'], 'method': result['method'] if result else None,
               'maskMode': result['forcedMaskMode'] if result else None,
               'rgbaSHA256': hashlib.sha256(bytes(result['rgba'])).hexdigest() if result else None,
               'maskSHA256': hashlib.sha256(bytes(result['layoutSafe'])).hexdigest() if result else None}
        if mismatch:
            row['mismatch'] = mismatch
            mismatches.append(row)
        rows.append(row)
    by_name = {fixture['name']: fixture['expected'] for fixture in fixtures}
    assert by_name['glyph-flat-safe']['result']['forcedMaskMode'] == 'glyph'
    assert by_name['rect-single-component']['result']['forcedMaskMode'] == 'rect'
    assert by_name['rect-single-component']['result']['quality']['surface']['samples'] >= 64
    assert by_name['background-only-rect']['result']['sourceCorePixels'] == 0
    assert by_name['source-ink-only-safe']['result']['forcedMaskMode'] == 'glyph'
    assert by_name['source-ink-only-with-unowned-stroke']['result']['forcedMaskMode'] == 'glyph'
    assert by_name['incomplete-source-ink-object']['failure'] == 'display-mask-unverified'
    assert by_name['null-background-muted-display']['failure'] == 'display-mask-unverified'
    assert by_name['null-background-dark-glyph']['result']['forcedMaskMode'] == 'glyph'
    assert by_name['incomplete-safe']['failure'] == 'display-mask-unverified'
    assert by_name['incomplete-ordinary']['result']['forcedMaskMode'] == 'rect'
    assert by_name['donors-completely-blocked-safe']['failure'] == 'display-donors-unverified'
    assert by_name['donors-completely-blocked']['failure'] == 'uncertified-background-surface'
    assert by_name['cropped-edge']['result']['sourceTouchesCropEdge'] > 0
    assert any(f['expected']['result'] and f['expected']['result']['sourceOutlinePixels'] > 0 for f in fixtures)
    for name in ['overlapping-neighbor', 'donor-only-overlap', 'polygon-ownership', 'excluded-and-protected-masks', 'source-ink-hypothesis']:
        assert by_name[name]['result']['erased'] > 0, 'Inactive ownership fixture: ' + name
    passed = not mismatches
    report = {'passed': passed, 'fixtures': len(fixtures), 'exact': len(fixtures) - len(mismatches),
              'accepted': sum(row['accepted'] for row in rows),
              'methods': dict(Counter(row['method'] for row in rows if row['accepted'])),
              'failureReasons': dict(Counter(row['failure'] for row in rows if not row['accepted'])),
              'buildSeconds': build_seconds, 'testSeconds': time.monotonic() - started,
              'comparison': 'Exact every RGBA byte, ownership-mask byte, all result metadata, all serialized quality/surface fields, nullability and rejection reasons.',
              'hostShims': 'Palette RGB parsing and max-channel distance copied from production; no pixel, segmentation, donor or quality algorithm is mocked.',
              'sourceSHA256': {source.name: hashlib.sha256(source.read_bytes()).hexdigest() for source in sources},
              'oracleSHA256': hashes, 'rows': rows, 'mismatches': mismatches}
    (output / 'report.json').write_text(json.dumps(report, indent=2))
    lines = ['| Fixture | Exact | Outcome |', '|---|---|---|']
    for row in rows:
        outcome = (row['method'] + '/' + row['maskMode']) if row['accepted'] else row['failure']
        lines.append(f"| {row['name']} | {'PASS' if row['exact'] else 'FAIL'} | {outcome} |")
    (output / 'report.md').write_text('\n'.join(lines) + '\n')
    print(f"{'PASS' if passed else 'FAIL'}: {report['exact']}/{len(fixtures)} exact; {report['accepted']} successful reconstructions; {output / 'report.json'}")
    if mismatches:
        print(json.dumps(mismatches, indent=2))
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
