#!/usr/bin/env python3
"""Compile and run standalone Swift contract tests against unchanged production helpers.

No models, images, app build or shared caches; each program is built in a private
temporary directory.
"""
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
TESTS = ROOT / "Scripts/tests"
ENSEMBLE = ROOT / "Aidoku/Core/Translation/NativeEngine/Ensemble"

PROGRAMS = {
    "evidence-lease": ([], [TESTS / "NativeMainEnsembleEvidenceLeaseTests.swift",
                            ENSEMBLE / "NativeMainEnsembleEvidenceLease.swift"]),
    "original-mask-fringe": (["-D", "MASK_FRINGE_STANDALONE"],
                             [TESTS / "NativeOriginalMaskFringeCompletionTests.swift",
                              ENSEMBLE / "NativeOriginalMaskFringeCompletion.swift"]),
}

with tempfile.TemporaryDirectory(prefix="aidoku-standalone-native-") as folder:
    work = Path(folder)
    for name, (flags, sources) in PROGRAMS.items():
        started = time.monotonic()
        binary = work / name
        subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", *flags,
                        "-module-cache-path", str(work / "module-cache"),
                        *map(str, sources), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
        print(f"PASS {name} ({time.monotonic() - started:.1f}s)")
