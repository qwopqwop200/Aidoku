#!/usr/bin/env python3
"""Compare actual native helper gradient tile RGB and alpha with frozen PDF images."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import zlib

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--reference', type=Path, default=ROOT / 'build/native-render-parity/export-gradient-alpha')
args = parser.parse_args()
out = ROOT / 'build/native-render-parity/pdf-gradient-raster-check'
out.mkdir(parents=True, exist_ok=True)
subprocess.run(['swiftc', '-O', str(ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationPDFCapture.swift'),
                str(Path(__file__).parent / 'raster/main.swift'), '-o', str(out / 'probe')], check=True)
subprocess.run([str(out / 'probe'), str(out)], cwd=ROOT, check=True)

def image_buffers(path):
    result = []
    for match in re.finditer(rb'(\d+) 0 obj\b(.*?)endobj', path.read_bytes(), re.S):
        obj = match[2]
        if b'/Subtype /Image' not in obj:
            continue
        head, stream = obj.split(b'stream', 1)
        stream = stream.split(b'endstream')[0].strip(b'\r\n')
        if b'/Width 1 /Height 86' not in head:
            continue
        if b'/FlateDecode' in head:
            stream = zlib.decompress(stream)
        result.append(stream)
    return result

def pattern_matrix(path):
    for obj in re.findall(rb'\d+ 0 obj\b(.*?)endobj', path.read_bytes(), re.S):
        if b'/Type /Pattern' in obj:
            return list(map(float, re.search(rb'/Matrix \[([^]]+)\]', obj)[1].split()))
    return None

rows = []
for name, reference in [('light', 'horizontal-korean.pdf'), ('dark', 'dark-translucent.pdf')]:
    actual = image_buffers(out / (name + '.pdf'))
    expected = image_buffers(args.reference / reference)
    matrix = pattern_matrix(out / (name + '.pdf'))
    expected_matrix = pattern_matrix(args.reference / reference)
    exact = len(actual) == len(expected) == 2 and actual == expected and matrix == expected_matrix
    rows.append({'fixture': name, 'exact': exact, 'patternMatrix': matrix, 'expectedPatternMatrix': expected_matrix,
                 'bufferLengths': list(map(len, actual)),
                 'scope': 'Entire embedded 1x86 tile RGB, alpha mask and pattern transform/phase, from actual native helper and frozen PDF.'})
report = {'passed': all(row['exact'] for row in rows), 'fixtures': rows,
          'scope': 'Tile bytes only; this does not replace the final decoded RGBA image gate.'}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
raise SystemExit(0 if report['passed'] else 1)
