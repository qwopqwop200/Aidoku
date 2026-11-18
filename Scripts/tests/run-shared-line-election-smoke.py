#!/usr/bin/env python3
"""Focused native election behavior checks; no GT, model inference or source RGB."""
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / 'build/shared-line-election-tests'
CACHE.mkdir(parents=True, exist_ok=True)
OCR = ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR'
FILES = [Path(__file__).with_name('SharedLineElectionSmoke.swift'),
         OCR.parent / 'Layout/NativeRFDETRSemanticGrid.swift', OCR / 'NativeOCRGeometryDeduplication.swift',
         OCR / 'NativeOCRGeometryRepresentativeSelection.swift', OCR / 'NativeOCRLineAgreementFeatures.swift',
         OCR / 'NativeOCRPhysicalPaintSupport.swift', OCR / 'NativeOCRSharedLineElection.swift']
fingerprint = hashlib.sha256(b''.join(p.read_bytes() for p in FILES)).hexdigest()
binary, stamp = CACHE / 'smoke', CACHE / 'fingerprint'
if not binary.exists() or not stamp.exists() or stamp.read_text() != fingerprint:
    mapping = {'': {'swift-dependencies': str(CACHE / 'master.swiftdeps')}}
    for p in FILES:
        mapping[str(p)] = {'object': str(CACHE / (p.stem + '.o')), 'swift-dependencies': str(CACHE / (p.stem + '.swiftdeps'))}
    path = CACHE / 'output-map.json'
    path.write_text(json.dumps(mapping))
    subprocess.run(['xcrun', 'swiftc', '-O', '-incremental', '-enable-batch-mode', '-j2', '-parse-as-library',
                    '-module-name', 'SharedLineElectionSmoke', '-output-file-map', str(path),
                    *map(str, FILES), '-o', str(binary)], check=True)
    stamp.write_text(fingerprint)
subprocess.run([str(binary)], check=True)
