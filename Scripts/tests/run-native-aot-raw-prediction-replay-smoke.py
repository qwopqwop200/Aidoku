#!/usr/bin/env python3
"""Model-free smoke of the production raw AOT prediction snapshot, archive and replay."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble'
files = [NATIVE / name for name in ['NativeAOTAlphaComposition.swift', 'NativeAOTBoundaryBias.swift',
                                    'NativeResidentAOT.swift', 'NativeAOTExactTensorCache.swift']]
files.append(Path(__file__).with_name('NativeAOTRawPredictionReplaySmoke.swift'))
with tempfile.TemporaryDirectory(prefix='aidoku-aot-raw-replay-') as temporary:
    temporary = Path(temporary)
    binary = temporary / 'smoke'
    subprocess.run(['xcrun', 'swiftc', '-O', '-parse-as-library', '-module-cache-path', str(temporary / 'modules'),
                    *map(str, files), '-o', str(binary)], check=True)
    work = temporary / 'work'
    work.mkdir()
    subprocess.run([str(binary), str(work)], check=True)
