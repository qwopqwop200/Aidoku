#!/usr/bin/env python3
"""Exact native/frozen-JavaScript connected-lettering byte and layout-safety proof."""
from __future__ import annotations
import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay"
FIXTURES = ROOT / "Scripts/tests/fixtures/native-connected-lettering"


def fixtures() -> list[dict]:
    output = []
    for name in ["flat", "gradient", "two-paper-colors", "adjacent-excluded", "vertical",
                 "long-rule", "nonflat-ring", "few-exemplar", "excess-connected-ink", "far-art"]:
        w, h = 88, 62
        rgba = [250, 247, 240, 255] * (w * h)
        restored, safe = [0] * len(rgba), [0] * (w * h)

        def paint(x: int, y: int, width: int, height: int, rgb: list[int], erase=False) -> None:
            for yy in range(y, y + height):
                for xx in range(x, x + width):
                    i = yy * w + xx
                    rgba[i * 4:i * 4 + 3] = rgb
                    if erase:
                        restored[i * 4:i * 4 + 4] = [250, 247, 240, 255]
                        safe[i] = 1

        if name in ["gradient", "two-paper-colors", "nonflat-ring"]:
            for y in range(h):
                for x in range(w):
                    rgb = ([220 + x // 4, 217 + x // 4, 210 + x // 4] if name == "gradient" else
                           ([250, 247, 240] if y < 29 else [210, 230, 215]) if name == "two-paper-colors" else
                           [70 + (x * 17 + y * 11) % 170, 75 + (x * 13 + y * 3) % 170, 80 + (x * 7 + y * 19) % 170])
                    rgba[(y * w + x) * 4:(y * w + x) * 4 + 3] = rgb
        paint(20, 22, 8, 14, [12, 15, 18], erase=True)
        paint(31, 22, 6, 14, [12, 15, 18])
        paint(36, 22, 5, 3, [12, 15, 18])
        paint(36, 28, 4, 3, [12, 15, 18])
        paint(36, 33, 5, 3, [12, 15, 18])
        excluded = [[30, 20, 14, 18]] if name == "adjacent-excluded" else []
        if name == "long-rule":
            paint(0, 28, w, 3, [12, 15, 18])
        if name == "few-exemplar":
            restored, safe = [0] * len(rgba), [0] * (w * h)
            paint(20, 22, 3, 3, [12, 15, 18], erase=True)
        if name == "excess-connected-ink":
            for x in [44, 54]:
                paint(x, 22, 7, 14, [12, 15, 18])
        if name == "far-art":
            paint(31, 22, 10, 14, [250, 247, 240])
            paint(65, 22, 6, 14, [12, 15, 18])
        box = [14, 15, 61, 29]
        if name == "vertical":
            # Transpose the complete source and erasure so the column profile
            # certifies an actual vertical repair, rather than a rejected row.
            rgba = [v for x in range(w) for y in range(h) for v in rgba[(y * w + x) * 4:(y * w + x) * 4 + 4]]
            restored = [v for x in range(w) for y in range(h) for v in restored[(y * w + x) * 4:(y * w + x) * 4 + 4]]
            safe = [safe[y * w + x] for x in range(w) for y in range(h)]
            w, h = h, w
            box = [15, 14, 29, 61]
        output.append(dict(name=name, width=w, height=h, rgba=rgba, restored=restored, safe=safe,
                           box=box, excluded=excluded, vertical=name == "vertical"))
    return output


def run(directory: pathlib.Path, reference: pathlib.Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    inputs = directory / "input.json"
    inputs.write_text(json.dumps(fixtures()))
    main = directory / "main.swift"
    shutil.copyfile(FIXTURES / "main.swift", main)
    executable = directory / "native-connected"
    subprocess.run(["xcrun", "swiftc", str(OVERLAY / "NativeResidualProof.swift"),
                    str(OVERLAY / "NativeConnectedLettering.swift"), str(main), "-o", str(executable)], check=True)
    native, browser = directory / "native.json", directory / "browser.json"
    subprocess.run([str(executable), str(inputs), str(native)], check=True)
    subprocess.run(["node", str(FIXTURES / "oracle.cjs"), str(inputs), str(reference), str(browser)], check=True)
    actual, expected = json.loads(native.read_text()), json.loads(browser.read_text())
    differences = []
    for a, b in zip(actual, expected, strict=True):
        fields = [key for key in a if a[key] != b[key]]
        print(f"{a['name']}: {'DIFFERENT ' + ', '.join(fields) if fields else 'EXACT'}, painted={a['painted']}")
        if fields:
            differences.append(dict(name=a["name"], fields=fields))
    by_name = {a["name"]: a for a in actual}
    positive = all(by_name[n]["painted"] > 0 for n in ["flat", "gradient", "two-paper-colors", "vertical"])
    rejected = all(by_name[n]["painted"] == 0 for n in ["adjacent-excluded", "few-exemplar", "far-art"])
    report = dict(exact=not differences and positive and rejected, fixtures=len(actual),
                  positiveRepairBranches=positive, rejectionBranches=rejected, differences=differences)
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report["exact"]:
        raise SystemExit("Connected-lettering parity failed; inspect saved byte outputs.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-overlay", type=pathlib.Path, default=ROOT / "Scripts/native-render-parity/reference-source")
    parser.add_argument("--output-dir", type=pathlib.Path)
    args = parser.parse_args()
    if args.output_dir:
        run(args.output_dir.resolve(), args.reference_overlay.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="aidoku-native-connected-lettering-") as directory:
            run(pathlib.Path(directory), args.reference_overlay.resolve())


if __name__ == "__main__":
    main()
