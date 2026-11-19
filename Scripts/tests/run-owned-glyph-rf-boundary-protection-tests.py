#!/usr/bin/env python3
"""Synthetic checks of the production owned-glyph RF boundary protection helper."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
files = [ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeOwnedGlyphRFBoundaryProtection.swift',
         Path(__file__).with_name('NativeOwnedGlyphRFBoundaryProtectionTests.swift')]
with tempfile.TemporaryDirectory(prefix='aidoku-owned-glyph-rf-') as temporary:
    temporary = Path(temporary)
    binary = temporary / 'tests'
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-module-cache-path', str(temporary / 'modules'),
                    *map(str, files), '-o', str(binary)], check=True)
    output = subprocess.run([str(binary)], check=True, capture_output=True, text=True).stdout
    print(output, end='')
    report = json.loads(output.strip().splitlines()[-1])
    if report.get('failed') != 0 or report.get('checks', 0) <= 0:
        raise SystemExit(f'owned-glyph RF boundary protection failed: {report}')
