#!/usr/bin/env python3
"""Exercise the production dynamic recognizer store on real Core ML model handles."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR"
source = (OCR / "NativeCoreMLRecognizer.swift").read_text()
coordinator = (OCR / "NativeCoreMLOCRPipeline.swift").read_text()


def section(text, start, end):
    first = text.index(start)
    return text[first:text.index(end, first)]


# Keep the production actor private in the app. Give the stand-alone regression
# access to its model identities without introducing a production test hook.
store = section(source, "    private struct ModelHandle:", "    let modelName: String")
for declaration in ("struct ModelHandle:", "struct ModelAccess:", "struct LoadedModel:", "actor ModelStore"):
    store = store.replace("private " + declaration, declaration, 1)
variants = section(source, "struct NativeCoreMLRecognitionBucket:", "@available(iOS 18.0, *)\nprivate final class NativeCoreMLRecognitionGeneration")
loads = section(coordinator, "struct NativeCoreMLSharedLoadAccess<", "@available(iOS 18.0, *)\nprotocol NativeCoreMLDetecting")
fixture = ROOT / "Scripts/tests/recognition-dynamic-handles.swift"
package = ROOT / "Aidoku/Resources/Translation/PP-OCRv6-Manga-RecWidths.mlpackage"

with tempfile.TemporaryDirectory(prefix="rec-dynamic-handles-") as temp:
    folder = Path(temp)
    extracted = folder / "Store.swift"
    extracted.write_text("import Foundation\nimport CoreML\n" + variants + loads + "enum Predictor {\n" + store + "}\n")
    test = folder / "regression"
    subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", str(extracted), str(fixture), "-o", str(test)], check=True)
    subprocess.run([str(test), str(package)], check=True, timeout=150)
