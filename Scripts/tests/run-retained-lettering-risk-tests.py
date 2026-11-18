"""Focused pure-Swift checks; private incremental cache, no images/models/shared builds."""
from pathlib import Path
import hashlib
import json
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCES = [
    ROOT / "Aidoku/Core/Translation/NativeEngine/Ensemble/NativeRetainedLetteringRisk.swift",
    Path(__file__).with_name("NativeRetainedLetteringRiskTests.swift"),
]
OUT = ROOT / "build/r129-retained-lettering-risk-tests"
OUT.mkdir(parents=True, exist_ok=True)
BINARY = OUT / "checks"
STAMP = OUT / "SOURCE-SHA256"
identity = hashlib.sha256(b"".join(p.read_bytes() for p in SOURCES)).hexdigest()
build_seconds = 0.0
compiled = not BINARY.exists() or not STAMP.exists() or STAMP.read_text() != identity
command = ["xcrun", "swiftc", "-O", "-incremental", "-enable-batch-mode", "-j2", "-parse-as-library",
           "-module-name", "RetainedLetteringRiskTests", "-output-file-map", str(OUT / "output-file-map.json"),
           *map(str, SOURCES), "-o", str(BINARY)]
if compiled:
    mapping = {str(p): {"object": str(OUT / (p.stem + ".o")),
                        "swift-dependencies": str(OUT / (p.stem + ".swiftdeps"))} for p in SOURCES}
    mapping[""] = {"swift-dependencies": str(OUT / "master.swiftdeps")}
    (OUT / "output-file-map.json").write_text(json.dumps(mapping))
    start = time.monotonic()
    subprocess.run(command, check=True)
    build_seconds = time.monotonic() - start
    STAMP.write_text(identity)
start = time.monotonic()
result = subprocess.run([str(BINARY)], check=True, capture_output=True, text=True)
test_seconds = time.monotonic() - start
print(result.stdout, end="")
evidence = {"compiled": compiled, "build_seconds": build_seconds, "test_process_seconds": test_seconds,
            "exit_code": result.returncode, "stdout": result.stdout.strip(), "source_sha256": identity,
            "compile_command": command, "test_command": [str(BINARY)]}
(OUT / "test-evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
print(json.dumps(evidence, indent=2))
