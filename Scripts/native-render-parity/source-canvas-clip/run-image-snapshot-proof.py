#!/usr/bin/env python3
"""Stage/capture image destinations independently of the live clip controls."""
from pathlib import Path
import json,hashlib,subprocess,sys
ROOT=Path(__file__).resolve().parents[3];HERE=Path(__file__).resolve().parent
OUT=ROOT/'build/native-render-parity/source-canvas-clip/image-snapshot';OUT.mkdir(parents=True,exist_ok=True)
original=json.loads((HERE/'inputs.json').read_text());ids=['positive-captured','negative-captured','half-positive','half-negative','sub-layout-unit-insets','used-width-exhausted']
(OUT/'inputs.json').write_text(json.dumps([next(c for c in original if c['id']==id) for id in ids],indent=2))
source=HERE/'capture-image-snapshots.swift';binary=OUT/'capture'
subprocess.run(['xcrun','swiftc','-O',str(source),'-o',str(binary)],check=True)
(OUT/'capture-manifest.json').write_text(json.dumps(dict(compiler='xcrun swiftc -O',hashes={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in [source,binary,OUT/'inputs.json']}),indent=2))
subprocess.run([str(binary),str(OUT/'inputs.json'),str(OUT)],check=True)
subprocess.run([sys.executable,str(HERE/'analyze-image-snapshots.py')],check=True)
