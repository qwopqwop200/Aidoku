#!/usr/bin/env python3
"""Synthetic oracle checks of the production segmentation connected-weak gate."""
from pathlib import Path
import json
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
files = [ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeSegmentationFinalPolicy.swift',
         Path(__file__).with_name('NativeSegmentationConnectedWeakSmoke.swift')]
with tempfile.TemporaryDirectory(prefix='aidoku-connected-weak-') as temporary:
    temporary = Path(temporary)
    binary = temporary / 'smoke'
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-module-cache-path', str(temporary / 'modules'),
                    *map(str, files), '-o', str(binary)], check=True)
    output = subprocess.run([str(binary)], check=True, capture_output=True, text=True).stdout
    print(output, end='')
    report = json.loads(output.strip().splitlines()[-1])
    if report.get('passed') is not True or report.get('syntheticCases', 0) <= 0:
        raise SystemExit(f'connected-weak smoke failed: {report}')
