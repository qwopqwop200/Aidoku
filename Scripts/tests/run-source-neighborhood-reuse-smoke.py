"""Compare current source feature matrices to a supplied pre-change snapshot.

CPU/OpenCV only; reads existing static archives and uses a private module cache.
No models, main builds, API requests or image display.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile


def declaration(text, anchor):
    start = text.index(anchor)
    opening = text.index("{", start)
    depth = 1
    for end in range(opening + 1, len(text)):
        depth += (text[end] == "{") - (text[end] == "}")
        if depth == 0:
            return text[start:end + 1]
    raise ValueError(anchor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    engine = repo / "Aidoku/Core/Translation/NativeEngine/Ensemble"
    names = ["NativePixelRFBoundaryFeatures.swift", "NativeSegmentationFinalFeatures.swift"]
    args.output.mkdir(parents=True, exist_ok=True)
    pixel = (engine / "NativePixelRFFeatures.swift").read_text()
    support = "import Foundation\nenum NativePixelRFFeatures {\n"
    support += declaration(pixel, "struct Matrix") + "\n"
    support += declaration(pixel, "static func boxMean(") + "\n"
    support += declaration(pixel, "static func distance(") + "\n}\n"
    support += "enum NativePixelRFBoundarySegmentation {\n"
    support += declaration((engine / "NativePixelRFBoundarySegmentation.swift").read_text(), "static func uniformDistances(") + "\n}\n"
    library = repo / "build/native-source-cv-host"
    archives = [library / name for name in ["libAidokuSourceCV.a", "libAidokuOpenCV.a", "libAidokuFreeType.a"]]
    digest = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
    archive_hashes = {str(p): digest(p) for p in archives}
    with tempfile.TemporaryDirectory(prefix="probe-", dir=args.output) as temporary:
        scratch = Path(temporary)
        (scratch / "Support.swift").write_text(support)
        baselines = []
        for name in names:
            path = scratch / ("Baseline" + name)
            path.write_text((args.baseline_dir / name).read_text()
                            .replace("NativePixelRFBoundaryFeatures", "BaselineBoundaryFeatures")
                            .replace("NativeSegmentationFinalFeatures", "BaselineFinalFeatures"))
            baselines.append(path)
        sources = [scratch / "Support.swift", *baselines, *[engine / n for n in names],
                   engine / "NativeSegmentationOpenCVOperations.swift",
                   repo / "Scripts/tests/NativeSourceNeighborhoodReuseSmoke.swift"]
        binary = scratch / "smoke"
        subprocess.run(["xcrun", "swiftc", "-O", "-parse-as-library", "-module-cache-path", str(args.output / "module-cache"),
                        "-I", str(repo / "Vendor/NativeSourceCV/include"), "-L", str(library),
                        *map(str, sources), "-lAidokuSourceCV", "-lAidokuOpenCV", "-lAidokuFreeType", "-lc++", "-lz",
                        "-o", str(binary)], check=True)
        result = subprocess.run([str(binary)], check=True, capture_output=True, text=True)
    receipt = json.loads(result.stdout)
    assert archive_hashes == {str(p): digest(p) for p in archives}
    receipt.update(baselineSHA256={n: digest(args.baseline_dir / n) for n in names},
                   candidateSHA256={n: digest(engine / n) for n in names},
                   modelCalls=0, mainBuilds=0, sharedArchivesUnchanged=True)
    (args.output / "RESULT.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt, indent=2))


if __name__ == "__main__":
    main()
