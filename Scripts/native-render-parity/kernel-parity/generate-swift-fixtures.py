#!/usr/bin/env python3
"""Generate app-hosted Swift ABI fixtures from the frozen WASM corpus."""
import json
import struct
import zlib
from pathlib import Path
ROOT = Path(__file__).resolve().parents[3]
source = ROOT / 'build/native-render-parity/kernel-parity'
manifest = json.loads((source / 'fixtures.json').read_text())
reports = {row['id']: row for row in json.loads((source / 'wasm/results.json').read_text())}
for case in manifest['cases']:
    import base64
    case['expectedData'] = base64.b64encode((source / 'wasm' / (case['id'] + '.bin')).read_bytes()).decode()
    case['expectedReturns'] = reports[case['id']]['returns']
    case.pop('seed', None)
    case.pop('variant', None)
report = json.loads((source / 'report.json').read_text())
data = json.dumps({'version': 1, 'frozenWASMSHA256': report['frozenWASMSHA256'],
                   'kernelSourceSHA256': report['nativeSourceSHA256'], 'cases': manifest['cases']}, separators=(',', ':')).encode()
compressor = zlib.compressobj(level=9, wbits=-15)
encoded = compressor.compress(data) + compressor.flush()
output = ROOT / 'AidokuTests/Translation/NativeEngine/Fixtures/native-kernel-bridge-fixtures.json.deflate'
output.parent.mkdir(parents=True, exist_ok=True)
output.write_bytes(struct.pack('<Q', len(data)) + encoded)
print(f'{len(manifest["cases"])} fixtures, {len(data)} JSON bytes -> {len(encoded)} compressed bytes: {output}')
