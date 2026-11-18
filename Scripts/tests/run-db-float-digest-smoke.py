"""Actual pure shared DB Float32 digest vs frozen canonical copying algorithm."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Ensemble/NativeMainEnsembleDBCapability.swift'
with tempfile.TemporaryDirectory(prefix='aidoku-db-float-digest-') as temporary:
    folder = Path(temporary)
    executable = folder / 'digest-smoke'
    started = time.monotonic()
    subprocess.run(['xcrun', 'swiftc', '-O', '-module-cache-path', str(folder / 'modules'),
                    str(SOURCE), str(Path(__file__).with_name('NativeDBFloatDigestSmoke.swift')),
                    '-o', str(executable)], check=True)
    build_seconds = time.monotonic() - started
    started = time.monotonic()
    completed = subprocess.run([str(executable)], capture_output=True, text=True, check=True)
    result = json.loads(completed.stdout)
    assert result['passed'] and result['cases'] >= 14
    result.update(sourceSHA256=hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
                  buildSeconds=build_seconds, testSeconds=time.monotonic() - started)
    print(json.dumps(result, indent=2))
