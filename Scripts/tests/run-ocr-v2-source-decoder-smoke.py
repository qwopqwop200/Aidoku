"""Compile only the production source decoder and check synthetic RGBA parity."""
import json
from pathlib import Path
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRV2SourcePixelDecoder.swift"
with tempfile.TemporaryDirectory(prefix="aidoku-v2-decoder-") as temporary:
    folder = Path(temporary)
    executable = folder / "decoder-smoke"
    started = time.monotonic()
    subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(folder / "modules"),
                    str(SOURCE), str(Path(__file__).with_name("NativeOCRV2SourceDecoderSmoke.swift")),
                    "-o", str(executable)], check=True)
    build_seconds = time.monotonic() - started
    started = time.monotonic()
    completed = subprocess.run([str(executable)], capture_output=True, text=True, check=True)
    result = json.loads(completed.stdout)
    assert result["passed"] and result["cases"] == 16
    result.update(buildSeconds=build_seconds, testSeconds=time.monotonic() - started)
    print(json.dumps(result, indent=2))
