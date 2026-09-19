#!/usr/bin/env python3
"""Exercise each real blocking bridge without Swift await priority donation."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
harness = repo / 'Scripts/tests/blocking-priority-regression.swift'
implementations = [
    ('app', 'Aidoku/Core/Utilities/Concurrency/BlockingTask.swift', ['-DAPP_BLOCKING_THROWING_TESTS']),
    ('runner', 'Vendor/AidokuRunner/Sources/AidokuRunner/Utilities/BlockingTask.swift', []),
]
with tempfile.TemporaryDirectory(prefix='aidoku-blocking-priority-') as directory:
    for name, source, flags in implementations:
        executable = pathlib.Path(directory) / name
        subprocess.run(['xcrun', 'swiftc', '-parse-as-library', *flags,
                        str(repo / source), str(harness), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True)
