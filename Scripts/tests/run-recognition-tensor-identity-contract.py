#!/usr/bin/env python3
"""Production fingerprint/accessor versus independently packed SHA256; no models."""
from pathlib import Path
import hashlib
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / "Aidoku/Core/Translation/NativeEngine/OCR/NativeCoreMLRecognizer.swift").read_text()
fingerprint = source[source.index("private struct NativeCoreMLRecognitionCropFingerprint:"):source.index("@available(iOS 18.0, *)\nprivate struct NativeCoreMLCachedRecognition:")]
accessor = source[source.index("/// Read-only replay identity;"):]
tensor = source[source.index("struct NativeCoreMLPreparedTensor:"):source.index("@available(iOS 18.0, *)\nenum NativeCoreMLRecognitionPreprocessor")]
cases = [(37, 48, False, False), (38, 48, False, False), (37, 96, False, False),
         (37, 48, True, False), (37, 48, False, True)]
expected = []
for width, bucket, rotated, contrast in cases:
    metadata = [width, bucket, int(rotated)] + ([1] if contrast else [])
    expected.append(hashlib.sha256(struct.pack("<" + "Q" * len(metadata), *metadata)
                                  + struct.pack("<4f", 0.0, -0.0, 0.25, -1.5)).hexdigest())
swift = """import Foundation
import CryptoKit
enum NativeCoreMLRecognitionPhotometricMode { case original, luminanceContrast }
struct NativeCoreMLRecognitionBucket: Equatable, Sendable { let width: Int }
enum NativeCoreMLRecognitionPreprocessor {}
""" + tensor + fingerprint + accessor
for case, digest in zip(cases, expected):
    width, bucket, rotated, contrast = case
    swift += f'''precondition(NativeCoreMLRecognitionPreprocessor.tensorIdentityForReplay(
        .init(values: [0.0, -0.0, 0.25, -1.5], resizedWidth: {width},
        bucket: .init(width: {bucket}), rotatedCounterClockwise: {str(rotated).lower()},
        photometricMode: .{'luminanceContrast' if contrast else 'original'})) == "{digest}")\n'''
swift += 'print("PASS production fingerprint+accessor: 5 independent SHA256 metadata/tensor vectors; no models")\n'
with tempfile.TemporaryDirectory(prefix="rec-tensor-identity-") as folder:
    path = Path(folder)
    (path / "main.swift").write_text(swift)
    subprocess.run(["xcrun", "swiftc", str(path / "main.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
