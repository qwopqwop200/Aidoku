#!/usr/bin/env python3
"""Focused native detector geometry regression, with optional saved-run audit."""
from pathlib import Path
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix="aidoku-detector-fine-print-") as temporary:
    executable = Path(temporary) / "detector-regression"
    build_start = time.perf_counter()
    subprocess.run([
        "swiftc", "-O", "-parse-as-library",
        str(root / "Aidoku/Core/Translation/NativeEngine/OCR/NativeCoreMLDBPostprocessor.swift"),
        str(root / "Aidoku/Core/Translation/NativeEngine/OCR/NativeCoreMLDBErasureSupport.swift"),
        str(root / "Scripts/tests/detector-fine-print-regression.swift"), "-o", str(executable),
    ], check=True)
    print(f"Focused compile seconds: {time.perf_counter() - build_start:.3f}; temporary executable bytes: {executable.stat().st_size}", flush=True)
    arguments = sys.argv[1:]
    measure = "--measure" in arguments
    arguments = [argument for argument in arguments if argument != "--measure"]
    compare_rss = "--compare-rss" in arguments
    arguments = [argument for argument in arguments if argument != "--compare-rss"]
    if compare_rss:
        for mode in ("--baseline-only", "--recovery-only"):
            subprocess.run(["/usr/bin/time", "-l", str(executable), *arguments, mode], check=True)
    else:
        command = (["/usr/bin/time", "-l"] if measure else []) + [str(executable), *arguments]
        subprocess.run(command, check=True)
