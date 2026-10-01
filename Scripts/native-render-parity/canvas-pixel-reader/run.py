#!/usr/bin/env python3
"""Compare production CGImage sampling with actual local WKWebView Canvas bytes."""
import argparse
import hashlib
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
DIRECTORY = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/native-render-parity/canvas-pixel-reader')
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    reader_file = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeSourceColorSamplingStage.swift'
    spatial_file = reader_file.with_name('NativeSpatialSourceCrop.swift')
    original = reader_file.read_text()
    reader_code = original[original.index('final class NativeSourcePixelReader {'):]
    reader = output / 'NativeSourcePixelReader.swift'
    reader.write_text('import CoreGraphics\nimport Foundation\n' + reader_code)
    original = spatial_file.read_text()
    # edgePixels is the final actual production method; the outer shell only removes
    # unrelated app types. Both raster algorithms compile verbatim, without shims.
    edge_code = original[original.index('    static func edgePixels('):]
    edge = output / 'NativeSpatialSourceCrop.swift'
    edge.write_text('import CoreGraphics\nimport Foundation\nenum NativeSpatialSourceCrop {\n' + edge_code)
    reference_file = ROOT / 'Scripts/native-render-parity/reference-source/BrowserSourceTextColor.swift'
    reference_hash = hashlib.sha256(reference_file.read_bytes()).hexdigest()
    frozen = json.loads((reference_file.parent / 'manifest.json').read_text())['files']
    assert reference_hash == frozen['Aidoku/Core/Translation/NativeEngine/Overlay/BrowserSourceTextColor.swift']
    assert 'context.drawImage(image, x, y, sw, sh, 0, 0, w, h);' in reference_file.read_text()
    started = time.monotonic()
    executable = output / 'canvas-probe'
    subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-strict-concurrency=complete',
                    str(reader), str(edge), str(DIRECTORY / 'Probe.swift'), '-o', str(executable)], check=True, cwd=ROOT)
    build_seconds = time.monotonic() - started
    started = time.monotonic()
    pairs_file = output / 'raster-pairs.json'
    process = subprocess.run([str(executable), str(pairs_file)], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (output / 'oracle.log').write_text(process.stdout)
    if process.returncode != 0:
        report = {'passed': False, 'oracleAvailable': False, 'exitCode': process.returncode, 'error': process.stdout}
        (output / 'report.json').write_text(json.dumps(report, indent=2))
        print(process.stdout, end='')
        return process.returncode
    pairs = json.loads(pairs_file.read_text())
    assert len(pairs['oracle']) == len(pairs['native']) == 46
    rows = []
    extraction_names = {'full', 'integer', 'cached-integer', 'corners'}
    for oracle, native in zip(pairs['oracle'], pairs['native']):
        assert oracle['name'] == native['name'] and len(oracle['rgba']) == len(native['rgba'])
        delta = [abs(a-b) for a,b in zip(oracle['rgba'],native['rgba'])]
        changed = [i for i,d in enumerate(delta) if d]
        rows.append({'name': oracle['name'], 'exact': not changed, 'bytes': len(delta),
                     'differingBytes': len(changed), 'differingPixels': len({i//4 for i in changed}),
                     'maxChannelDelta': max(delta), 'meanAbsoluteChannelDelta': sum(delta)/len(delta),
                     'firstDifferingByte': changed[0] if changed else None,
                     'channelMaximumDeltas': [max(delta[c::4]) for c in range(4)],
                     'cacheMatchesDirect': native['rgba'] == native['direct'],
                     'oracleSHA256': hashlib.sha256(bytes(oracle['rgba'])).hexdigest(),
                     'nativeSHA256': hashlib.sha256(bytes(native['rgba'])).hexdigest()})
    passed = all(row['exact'] for row in rows)
    extraction = [row for row in rows if row['name'].split('/')[1] in extraction_names]
    report = {'passed': passed, 'oracleAvailable': True, 'cases': len(rows), 'exact': sum(row['exact'] for row in rows),
              'integerSourceExtractionExact': all(row['exact'] for row in extraction), 'integerSourceExtractionCases': len(extraction),
              'readerCacheMatchesDirect': all(row['cacheMatchesDirect'] for row in rows if not row['name'].endswith('spatial-edge')),
              'webKitUserAgent': pairs['userAgent'], 'devicePixelRatio': pairs['devicePixelRatio'],
              'buildSeconds': build_seconds, 'testSeconds': time.monotonic()-started,
              'sources': {file.name: hashlib.sha256(file.read_bytes()).hexdigest() for file in [reader_file,spatial_file,DIRECTORY/'Probe.swift']},
              'frozenCanvasCallSourceSHA256': reference_hash,
              'scope': 'Actual CGImage/ImageIO source decoding and unchanged production reader/edgePixels versus live WebKit Canvas. All RGBA bytes compared without tolerance.',
              'rows': rows}
    (output / 'report.json').write_text(json.dumps(report, indent=2))
    lines = ['| Crop | Exact | Changed bytes | Maximum RGBA delta |', '|---|---|---:|---:|']
    lines += [f"| {r['name']} | {'PASS' if r['exact'] else 'MISMATCH'} | {r['differingBytes']}/{r['bytes']} | {r['maxChannelDelta']} |" for r in rows]
    (output / 'report.md').write_text('\n'.join(lines)+'\n')
    print(f"{'PASS' if passed else 'MISMATCH'}: {report['exact']}/{len(rows)} exact; integer source extraction {len(extraction)}/{len(extraction)} exact={report['integerSourceExtractionExact']}; cache={report['readerCacheMatchesDirect']}")
    print(output / 'report.json')
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
