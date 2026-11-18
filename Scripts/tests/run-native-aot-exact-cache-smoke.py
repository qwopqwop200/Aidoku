#!/usr/bin/env python3
"""Model-free focused smoke of the production AOT tensor cache and compositor."""
from pathlib import Path
import os
import subprocess

ROOT=Path(__file__).resolve().parents[2]
NATIVE=ROOT/'Aidoku/Core/Translation/NativeEngine/Ensemble'
CACHE=ROOT/'build/native-aot-exact-cache-smoke'
CACHE.mkdir(parents=True,exist_ok=True)
files=[NATIVE/name for name in ['NativeAOTAlphaComposition.swift','NativeAOTBoundaryBias.swift',
                              'NativeResidentAOT.swift','NativeAOTExactTensorCache.swift']]
files.append(Path(__file__).with_name('NativeAOTExactTensorCacheSmoke.swift'))
binary=CACHE/'smoke'
if not binary.exists() or any(p.stat().st_mtime_ns>binary.stat().st_mtime_ns for p in files):
    subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(CACHE/'module-cache'),
                    *map(str,files),'-o',str(binary)],check=True)
for enabled in ['0','1']:
    subprocess.run([str(binary)],check=True,env=dict(os.environ,AIDOKU_AOT_TENSOR_CACHE=enabled))
