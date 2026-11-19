#!/usr/bin/env python3
"""Compile the production quoted-stack grouper with its focused host smoke; no models or app build."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [ROOT / 'Aidoku/Core/Translation/ReaderTranslationQuotedStack.swift',
           ROOT / 'Scripts/tests/ReaderTranslationQuotedStackSmoke.swift']

with tempfile.TemporaryDirectory(prefix='aidoku-quoted-stack-') as folder:
    binary = Path(folder) / 'smoke'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', *map(str, SOURCES), '-o', str(binary)],
                   check=True, cwd=ROOT)
    process = subprocess.run([str(binary)], check=True, cwd=ROOT, capture_output=True, text=True)
    print(process.stdout, end='')
    if not process.stdout.startswith('PASS'):
        raise SystemExit('quoted-stack smoke did not report PASS')
