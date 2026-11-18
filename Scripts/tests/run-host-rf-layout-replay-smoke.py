#!/usr/bin/env python3
"""Exact full-result RF replay checks without running detector inference."""
import hashlib
import json
from pathlib import Path
import subprocess
import time

REPO = Path(__file__).resolve().parents[2]


def main():
    sources = [REPO/'Aidoku/Core/Translation/NativeEngine/Layout/NativeRFDETRLayoutModels.swift',
               REPO/'Scripts/image-translation/HostRFLayoutReplay.swift',
               REPO/'Scripts/tests/HostRFLayoutReplaySmoke.swift']
    output = REPO/'build/rf-layout-replay-smoke-tests'; output.mkdir(exist_ok=True)
    compiler = subprocess.check_output(['xcrun', 'swiftc', '--version'], text=True)
    fingerprint = hashlib.sha256(compiler.encode()+b''.join(p.read_bytes() for p in sources)).hexdigest()
    receipt = output/'source-fingerprint'; binary = output/'smoke'
    build_seconds = 0
    if not binary.exists() or not receipt.exists() or receipt.read_text() != fingerprint:
        started = time.monotonic()
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-O', *map(str, sources), '-o', str(binary)], check=True)
        build_seconds = time.monotonic()-started
        receipt.write_text(fingerprint)
    started = time.monotonic(); process = subprocess.run([str(binary), str(REPO)], text=True, capture_output=True, check=True)
    import re
    match = re.search(r'(\d+) checks passed', process.stdout)
    if not match or int(match[1]) <= 0:
        raise RuntimeError('Zero/missing checks cannot pass')
    result = dict(checks=int(match[1]), failed=0, buildSeconds=build_seconds,
                  testSeconds=time.monotonic()-started, scope='host exact RF replay with synthetic full masks; no detector calls')
    (output/'result.json').write_text(json.dumps(result, indent=2)+'\n'); print(json.dumps(result))


if __name__ == '__main__':
    main()
