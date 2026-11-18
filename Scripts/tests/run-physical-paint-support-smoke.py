#!/usr/bin/env python3
"""Focused tests for the production physical-support selector."""
import hashlib
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / 'build/physical-paint-tests'
CACHE.mkdir(parents=True, exist_ok=True)
FILES = [ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRPhysicalPaintSupport.swift',
         Path(__file__).with_name('PhysicalPaintSupportSmoke.swift')]
fingerprint = hashlib.sha256(b''.join(p.read_bytes() for p in FILES)).hexdigest()
stamp, binary = CACHE / 'fingerprint', CACHE / 'smoke'
if not binary.exists() or not stamp.exists() or stamp.read_text() != fingerprint:
    output_map = {'': {'swift-dependencies': str(CACHE / 'master.swiftdeps')}}
    for path in FILES:
        output_map[str(path)] = {'object': str(CACHE / (path.stem + '.o')),
                                'swift-dependencies': str(CACHE / (path.stem + '.swiftdeps'))}
    mapping = CACHE / 'output-map.json'
    mapping.write_text(json.dumps(output_map))
    subprocess.run(['xcrun', 'swiftc', '-O', '-incremental', '-enable-batch-mode', '-j2',
                    '-parse-as-library', '-module-name', 'PhysicalPaintSupportSmoke',
                    '-output-file-map', str(mapping), *map(str, FILES), '-o', str(binary)], check=True)
    stamp.write_text(fingerprint)
subprocess.run([str(binary)], check=True)
