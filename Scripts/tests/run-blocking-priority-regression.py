#!/usr/bin/env python3
"""Check that the app's blocking bridge keeps the caller's task priority and QoS."""
import pathlib
import subprocess
import tempfile

repo = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='aidoku-blocking-priority-') as directory:
    executable = pathlib.Path(directory) / 'check'
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library',
                    str(repo / 'Aidoku/Core/Utilities/Concurrency/BlockingTask.swift'),
                    str(repo / 'Scripts/tests/blocking-priority-regression.swift'), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
