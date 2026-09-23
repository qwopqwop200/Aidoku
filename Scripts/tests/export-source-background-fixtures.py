#!/usr/bin/env python3
"""Export exact captured RGBA and a baseline script for the iOS background replay.

python3 Scripts/tests/export-source-background-fixtures.py /simulator/Documents/MangaQuality \
    --baseline /path/to/BrowserSourceTextColor.swift
No imaging dependencies; the PNGs retain the fixture's sRGB sample bytes.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import struct
import zlib


def chunk(tag, data):
    return struct.pack('!I', len(data)) + tag + data + struct.pack('!I', zlib.crc32(tag + data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--labels', type=Path)
    parser.add_argument('--captures', type=Path)
    parser.add_argument('--candidate', type=Path, help='Optional exact production Swift script snapshot for WebKit replay')
    args = parser.parse_args()
    fixture_dir = Path(__file__).parent / 'fixtures'
    captures = {f['id']: f for f in json.loads((args.captures or fixture_dir / 'source-color-diversity.json').read_text())['fixtures']}
    labels = json.loads((args.labels or fixture_dir / 'source-color-background.json').read_text())['fixtures']
    args.destination.mkdir(parents=True, exist_ok=True)
    manifest = []
    for label in labels:
        source = captures[label['id']]
        width, height = source['width'], source['height']
        rgba = zlib.decompress(base64.b64decode(source['rgba']))
        assert len(rgba) == width * height * 4
        assert hashlib.sha256(rgba).hexdigest() == source['pixelSHA256']
        scanlines = b''.join(b'\0' + rgba[y * width * 4:(y + 1) * width * 4] for y in range(height))
        png = b'\x89PNG\r\n\x1a\n'
        png += chunk(b'IHDR', struct.pack('!2I5B', width, height, 8, 6, 0, 0, 0))
        png += chunk(b'sRGB', b'\0')
        png += chunk(b'IDAT', zlib.compress(scanlines)) + chunk(b'IEND', b'')
        image = 'background-' + label['id'] + '.png'
        (args.destination / image).write_bytes(png)
        manifest.append({**label, 'image': image, 'source': source['source'], 'bounds': source['bounds'], 'snapshot': True})
    (args.destination / 'background-replay.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    script = re.search(r'static let script = """\n([\s\S]*?)\n    """', args.baseline.read_text())
    if not script:
        raise ValueError('Baseline must contain BrowserSourceTextColor.script')
    (args.destination / 'background-baseline.js').write_text(script.group(1))
    candidate_path = args.destination / 'background-candidate.js'
    if args.candidate:
        candidate = re.search(r'static let script = """\n([\s\S]*?)\n    """', args.candidate.read_text())
        if not candidate:
            raise ValueError('Candidate must contain BrowserSourceTextColor.script')
        candidate_path.write_text(candidate.group(1))
    else:
        candidate_path.unlink(missing_ok=True)
    print(f'Exported {len(manifest)} backgrounds to {args.destination}')


if __name__ == '__main__':
    main()
