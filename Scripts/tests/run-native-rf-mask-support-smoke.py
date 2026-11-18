#!/usr/bin/env python3
"""Focused host check compiling the actual production RF mask ownership code."""
import hashlib
import json
from pathlib import Path
import subprocess
import time

REPO = Path(__file__).resolve().parents[2]


def main():
    layout = REPO/'Aidoku/Core/Translation/NativeEngine/Layout'
    sources = [layout/name for name in ('NativeRFDETRLayoutModels.swift', 'NativeRFDETRSemanticGrid.swift',
                                       'NativeRFDETRSourceSupportGrid.swift')]
    sources.append(REPO/'Scripts/tests/NativeRFMaskSupportSmoke.swift')
    output = REPO/'build/native-rf-mask-support-smoke'; output.mkdir(exist_ok=True)
    compiler = subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True)
    fingerprint = hashlib.sha256(compiler.encode()+b''.join(p.read_bytes() for p in sources)).hexdigest()
    receipt = output/'source-fingerprint'; binary = output/'smoke'
    build_seconds = 0
    if not binary.exists() or not receipt.exists() or receipt.read_text() != fingerprint:
        started = time.monotonic()
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', *map(str, sources), '-o', str(binary)], check=True)
        build_seconds = time.monotonic()-started
        receipt.write_text(fingerprint)
    started = time.monotonic(); process = subprocess.run([str(binary)], text=True, capture_output=True, check=True)
    result = json.loads(process.stdout)
    if result['checks'] <= 0 or result['failed'] != 0:
        raise RuntimeError('Zero/missing checks cannot pass')
    result.update(buildSeconds=build_seconds, testSeconds=time.monotonic()-started,
                  scope='host production Swift component, not iOS installation or phone benchmark')
    (output/'result.json').write_text(json.dumps(result, indent=2)+'\n'); print(json.dumps(result))


if __name__ == '__main__':
    main()
