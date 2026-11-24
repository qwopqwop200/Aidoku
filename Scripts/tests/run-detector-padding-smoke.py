"""Exercise the actual production fill kernel without CoreML or app compilation."""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR/NativeCoreMLDetector.swift"
source = SOURCE.read_text()
kernel = source[source.index("    private static let boundedRowsPerPass"):
                source.index("    private struct ResizeCoordinateKey")]
prefix = """import Foundation
struct NativeOCRRGBAFrame {
    let width: Int; let height: Int; let bytesPerRow: Int; let bytes: [UInt8]
}
enum NativeCoreMLDetectorError: Error { case modelInputCreationFailed }
enum NativeCoreMLDetectionPreprocessor {
    private static let channelMean: [Float] = [0.485, 0.456, 0.406]
    private static let channelStandardDeviation: [Float] = [0.229, 0.224, 0.225]
"""
with tempfile.TemporaryDirectory(prefix="aidoku-detector-padding-") as temporary:
    folder = Path(temporary)
    extracted = folder / "ProductionFill.swift"
    extracted.write_text(prefix + kernel + "}\n")
    executable = folder / "padding-smoke"
    subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(folder / "modules"),
                    str(extracted), str(Path(__file__).with_name("NativeDetectorPaddingSmoke.swift")),
                    "-o", str(executable)], check=True)
    completed = subprocess.run([str(executable)], capture_output=True, text=True, check=True)
    result = json.loads(completed.stdout)
    assert result["passed"] and result["cases"] == 10
    print(completed.stdout, end="")
