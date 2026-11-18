#!/usr/bin/env python3
"""Pure native RF tensor/cache parity; zero model loads, prediction or dataset IO."""
from pathlib import Path
import subprocess
import os

ROOT = Path(__file__).resolve().parents[2]
LAYOUT = ROOT / 'Aidoku/Core/Translation/NativeEngine/Layout'
CACHE = ROOT / 'build/native-rf-shared-cache-smoke'
CACHE.mkdir(parents=True, exist_ok=True)
files = [LAYOUT / name for name in [
    'NativeRFDETRLayoutModels.swift', 'NativeRFDETRSemanticGrid.swift',
    'NativeRFDETRSourceSupportGrid.swift', 'NativeRFDETRLayoutDetector.swift',
    'NativeRFSharedRawCache.swift']]
files.append(Path(__file__).with_name('NativeRFSharedRawCacheSmoke.swift'))
binary = CACHE / 'smoke'
if not binary.exists() or any(path.stat().st_mtime_ns > binary.stat().st_mtime_ns for path in files):
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(CACHE / 'module-cache'),
                    *map(str, files), '-o', str(binary)], check=True)
for enabled in [None, '0', '1']:
    environment = dict(os.environ)
    if enabled is None:
        environment.pop('AIDOKU_RF_RAW_CACHE', None)
    else:
        environment['AIDOKU_RF_RAW_CACHE'] = enabled
    subprocess.run([str(binary)], check=True, env=environment)
