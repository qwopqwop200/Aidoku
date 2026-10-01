#!/usr/bin/env python3
"""Compare native source-color/donor policies with immutable pre-migration JavaScript descriptors and pixels."""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import time

DIRECTORY = Path(__file__).resolve().parent
ROOT = DIRECTORY.parents[2]
OVERLAY = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay"


def command(arguments: list[str | Path], log: Path, *, env: dict[str, str] | None = None) -> float:
    started = time.monotonic()
    result = subprocess.run([str(value) for value in arguments], cwd=ROOT, env=env, capture_output=True, text=True)
    log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); inspect {log}")
    return time.monotonic() - started


def equivalent(expected, actual, tolerance=0):
    if type(expected) is dict and type(actual) is dict:
        return expected.keys() == actual.keys() and all(equivalent(expected[k], actual[k], tolerance) for k in expected)
    if type(expected) is list and type(actual) is list:
        return len(expected) == len(actual) and all(equivalent(a, b, tolerance) for a, b in zip(expected, actual))
    if type(expected) in (float, int) and type(actual) in (float, int):
        return abs(expected - actual) <= tolerance
    return expected == actual


def compare(name: str, output: Path) -> dict:
    source = DIRECTORY / name
    destination = output / name
    destination.mkdir(parents=True, exist_ok=True)
    fixtures = destination / "fixtures.json"
    actual = destination / "native.json"
    environment = dict(os.environ, AIDOKU_POLICY_FIXTURES=str(fixtures))
    capture = ["node", source / "capture.cjs"]
    if name == "source-sampler":
        capture += ["--source", ROOT / "Scripts/native-render-parity/reference-source/BrowserSourceTextColor.swift"]
    capture_seconds = command(capture, destination / "capture.log", env=environment)
    executable = destination / "native-policy-probe"
    compile_arguments: list[str | Path] = ["xcrun", "swiftc", "-O", "-parse-as-library"]
    if name == "source-sampler":
        library = ROOT / "build/native-overlay-kernels-host/libAidokuOverlayKernels.a"
        if not library.exists():
            command(["python3", ROOT / "Scripts/overlay-kernels/native/build.py"], destination / "kernel-build.log")
        compile_arguments += ["-Xcc", "-fmodule-map-file=Scripts/overlay-kernels/native/module.modulemap",
            OVERLAY / "NativeTranslationPixelKernels.swift", OVERLAY / "NativeSourceColorSampler.swift",
            "-Lbuild/native-overlay-kernels-host", "-lAidokuOverlayKernels"]
    elif name == "gloss-placement":
        # Extract the unchanged production Canvas reader, avoiding unrelated
        # high-level source-sampling dependencies in this pure-policy probe.
        reader_source = (OVERLAY / "NativeSourceColorSamplingStage.swift").read_text()
        reader = destination / "NativeSourcePixelReader.swift"
        reader.write_text("import Foundation\nimport CoreGraphics\n" + reader_source[reader_source.index("final class NativeSourcePixelReader {"):])
        compile_arguments += [OVERLAY / "NativeTranslationGlossPlacement.swift", reader]
    else:
        # Only the production clamp utility is isolated; both donor policies and their parent helper enum are production sources.
        compile_arguments += [source / "clamp-isolation.swift", OVERLAY / "NativeObservedRestorationHelpers.swift",
                              OVERLAY / "NativeObservedRestorationDonors.swift"]
    compile_arguments += [source / "main.swift", "-o", executable]
    build_seconds = command(compile_arguments, destination / "build.log")
    execution_seconds = command([executable, fixtures, actual], destination / "execution.log")
    cases, values = json.loads(fixtures.read_text()), json.loads(actual.read_text())
    mismatches = []
    for index, (case, value) in enumerate(zip(cases, values)):
        expected = case["expected"]
        actual_value = value["actual"] if name == "source-sampler" else value
        if not equivalent(expected, actual_value, tolerance=1e-9 if name == "gloss-placement" else 0):
            mismatches.append({"index": index, "expected": expected, "actual": actual_value})
    passed = bool(cases) and len(cases) == len(values) and not mismatches
    report = {"policy": name, "passed": passed, "fixtureCount": len(cases), "outputCount": len(values),
              "exactCount": len(cases) - len(mismatches), "mismatches": mismatches,
              "captureSeconds": capture_seconds, "hostBuildSeconds": build_seconds, "executionSeconds": execution_seconds,
              "numericTolerance": 1e-9 if name == "gloss-placement" else 0,
              "scope": "Pure source policy; this does not establish Core Text, image sampling rasterization, or final page pixel parity."}
    (destination / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / "build/native-render-parity/policy-parity")
    parser.add_argument("--policy", choices=["source-sampler", "donor-front", "gloss-placement", "all"], default="all")
    arguments = parser.parse_args()
    output = arguments.output.resolve()
    names = ["source-sampler", "donor-front", "gloss-placement"] if arguments.policy == "all" else [arguments.policy]
    results = [compare(name, output) for name in names]
    output.mkdir(parents=True, exist_ok=True)
    report = {"passed": all(item["passed"] for item in results), "policies": results}
    (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    lines = ["# Native source policy differential", "", "These checks compare frozen pre-migration policies with native production policies.", ""]
    for item in results:
        lines.append(f"- {item['policy']}: {item['exactCount']}/{item['fixtureCount']} matched (numeric tolerance {item['numericTolerance']}); host build {item['hostBuildSeconds']:.3f}s; execution {item['executionSeconds']:.3f}s.")
    lines += ["", "Pure policy evidence only; full-page image comparison remains a separate acceptance gate."]
    (output / "report.md").write_text("\n".join(lines) + "\n")
    print(f"{'PASS' if report['passed'] else 'FAIL'}: {sum(item['fixtureCount'] for item in results)} policy fixtures; {output / 'report.json'}")
    raise SystemExit(0 if report["passed"] else 1)


if __name__ == "__main__":
    main()
