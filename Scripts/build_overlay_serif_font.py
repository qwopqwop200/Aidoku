#!/usr/bin/env python3
"""Rebuild Aidoku/Resources/Translation/AidokuSerifKR-Bold.woff2.

Input: the official OFL release of Nanum Myeongjo Bold
(https://github.com/google/fonts/raw/main/ofl/nanummyeongjo/NanumMyeongjo-Bold.ttf).
Output: a renamed WOFF2 subset (OFL Reserved Font Names are not used by
Modified Versions). Requires fontTools with brotli.

Usage: python3 Scripts/build_overlay_serif_font.py NanumMyeongjo-Bold.ttf [output.woff2]
"""
import hashlib
import os
import sys
import tempfile

from fontTools import subset
from fontTools.ttLib import TTFont

SOURCE_SHA256 = 'bc9ed8e60d93fe6db054b8fb988481b625f2eef8cb2317ad0e9834681b8fe3f3'
UNICODES = ('U+0020-007E,U+00A0-00FF,U+2010-2027,U+2030-203B,U+2190-2193,U+2460-2473,U+25A0-25CF,U+2605-2606,'
            'U+2661-2665,U+266A-266C,U+3000-303F,U+3131-318E,U+AC00-D7A3,U+FF01-FF5E,U+FFE0-FFE6')
NAMES = {
    1: 'Aidoku Serif KR', 2: 'Bold', 3: '1.0;AIDOKU;AidokuSerifKR-Bold', 4: 'Aidoku Serif KR Bold',
    5: 'Version 2.032-aidoku-subset-1', 6: 'AidokuSerifKR-Bold',
    10: 'Subset of Nanum Myeongjo Bold (Copyright 2010 NHN Corporation), renamed for Aidoku translation overlays '
        'under the SIL Open Font License 1.1; no Reserved Font Name is used.',
    13: 'This Font Software is licensed under the SIL Open Font License, Version 1.1. '
        'This license is available with a FAQ at: https://openfontlicense.org',
    14: 'https://openfontlicense.org',
}


def main():
    source = sys.argv[1]
    here = os.path.dirname(os.path.abspath(__file__))
    output = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
        here, '..', 'Aidoku', 'Resources', 'Translation', 'AidokuSerifKR-Bold.woff2')
    with open(source, 'rb') as handle:
        digest = hashlib.sha256(handle.read()).hexdigest()
    if digest != SOURCE_SHA256:
        sys.exit(f'unexpected source SHA-256 {digest}')
    with tempfile.TemporaryDirectory() as work:
        subset_path = os.path.join(work, 'subset.ttf')
        subset.main([source, '--unicodes=' + UNICODES, '--layout-features=kern,liga', '--no-hinting',
                     '--drop-tables+=DSIG', '--name-IDs=0', '--output-file=' + subset_path])
        font = TTFont(subset_path)
    name = font['name']
    # Keep only the original copyright notice, then name the Modified Version.
    name.names = [record for record in name.names if record.nameID == 0]
    for name_id, value in NAMES.items():
        name.setName(value, name_id, 3, 1, 0x409)
        name.setName(value, name_id, 1, 0, 0)
    # Apple's system copy of the same design uses these line metrics; the
    # overlay's 91% size-adjust and vertical centring were validated with them.
    font['hhea'].ascent, font['hhea'].descent, font['hhea'].lineGap = 942, -236, 0
    font['OS/2'].sTypoLineGap = 0
    # Reproducible output: keep the source's timestamps.
    font.recalcTimestamp = False
    font['head'].modified = font['head'].created
    font.flavor = 'woff2'
    font.save(output)
    with open(output, 'rb') as handle:
        print(output, os.path.getsize(output), hashlib.sha256(handle.read()).hexdigest())


if __name__ == '__main__':
    main()
