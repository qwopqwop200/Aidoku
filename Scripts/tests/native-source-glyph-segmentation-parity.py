#!/usr/bin/env python3
"""Compare actual native source-glyph policies against the frozen JavaScript byte outputs.

This uses Core Graphics on macOS and never starts WebKit or the production OCR/provider.
An explicit --reference-overlay permits comparison with a saved pre-migration source tree.
"""
from __future__ import annotations

import argparse
import json
import pathlib
import shutil
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay"
FIXTURE_TOOLS = ROOT / "Scripts/tests/fixtures/native-source-glyph-segmentation"


def fixtures() -> list[dict]:
    output = []
    colors = [
        ("black-plain", [20, 20, 20], [255, 255, 255], None),
        ("magenta-outline", [210, 20, 150], [255, 255, 255], [255, 255, 255]),
        ("muted-cream", [110, 85, 85], [225, 215, 190], None),
        ("dark-outline-on-art", [20, 20, 70], [130, 140, 155], [255, 255, 255]),
        ("few-independent", [20, 20, 20], [255, 255, 255], None),
    ]
    for name, foreground, background, stroke in colors:
        width, height = 80, 110
        rgba = (background + [255]) * (width * height)

        def paint(x: int, y: int, color: list[int]) -> None:
            rgba[(y * width + x) * 4:(y * width + x) * 4 + 3] = color

        for index in range(1 if name == "few-independent" else 5):
            x, y = 22, 15 + index * 16
            if stroke:
                for yy in range(y - 4, y + 15):
                    for xx in range(x - 4, x + 13):
                        paint(xx, yy, stroke)
            for yy in range(y, y + 11):
                for xx in range(x, x + 9):
                    if name == "magenta-outline" and x + 2 <= xx <= x + 6 and y + 2 <= yy <= y + 8:
                        continue
                    paint(xx, yy, foreground)
        output.append(dict(name=name, width=width, height=height, rgba=rgba, box=[17, 11, 20, 85],
                           foreground=foreground, background=background, stroke=stroke,
                           backgroundConfidence=0.9, strokeConfidence=0.9 if stroke else 0,
                           glyphSize=12, polygons=[], excluded=[]))
    geometry = dict(output[0], name="geometry-excluded",
                    polygons=[[[17, 11], [37, 11], [37, 96], [17, 96]]],
                    excluded=[[[38, 8], [60, 8], [60, 100], [38, 100]]])
    output.append(geometry)
    for name in ["grid", "grid-neighbor", "ruby", "row-end", "adjacent-dots"]:
        width, height, background, foreground = 150, 150, [250, 250, 250], [20, 20, 20]
        rgba = (background + [255]) * (width * height)
        box = [20, 15, 30, 115]

        def rect(x: int, y: int, w: int, h: int, color: list[int]) -> None:
            for yy in range(y, y + h):
                for xx in range(x, x + w):
                    rgba[(yy * width + xx) * 4:(yy * width + xx) * 4 + 3] = color

        if name.startswith("grid"):
            box = [20, 20, 110, 100]
            for y in range(20, 130, 20):
                rect(12, y, 130, 1, [110, 150, 200])
            for x in range(20, 140, 20):
                rect(x, 12, 1, 128, [110, 150, 200])
            for index in range(4):
                x, y = 27 + index * 20, 27 + index * 20
                rect(x, y, 8, 2, foreground)
                rect(x, y + 2, 2, 8, foreground)
                rect(x + 2, y + 8, 7, 2, foreground)
            if name == "grid-neighbor":
                rect(18, 45, 9, 3, foreground)
        elif name == "ruby":
            box = [20, 15, 20, 115]
            for y in [34, 60]:
                rect(45, y, 6, 2, foreground)
                rect(45, y + 2, 2, 5, foreground)
                rect(49, y + 2, 2, 5, foreground)
        elif name == "row-end":
            box = [20, 15, 30, 90]
            rect(29, 110, 4, 4, foreground)
            rect(29, 121, 4, 4, foreground)
        else:
            box = [20, 40, 30, 60]
            for y in range(25, 111, 12):
                rect(63, y, 4, 4, foreground)
        output.append(dict(name=name, width=width, height=height, rgba=rgba, box=box,
                           foreground=foreground, background=background, stroke=None,
                           backgroundConfidence=0.9, strokeConfidence=0, glyphSize=24,
                           polygons=[], excluded=[]))
    return output


def run(directory: pathlib.Path, reference: pathlib.Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    source = directory / "main.swift"
    shutil.copyfile(FIXTURE_TOOLS / "main.swift", source)
    inputs = directory / "input.json"
    inputs.write_text(json.dumps(fixtures()))
    executable = directory / "native-segmentation"
    subprocess.run(["xcrun", "swiftc", str(OVERLAY / "NativeSourceGlyphSegmentation.swift"),
                    str(source), "-o", str(executable)], check=True)
    native_path, browser_path = directory / "native.json", directory / "browser.json"
    subprocess.run([str(executable), str(inputs), str(native_path)], check=True)
    subprocess.run(["node", str(FIXTURE_TOOLS / "oracle.cjs"), str(inputs), str(reference), str(browser_path)], check=True)
    native, browser = json.loads(native_path.read_text()), json.loads(browser_path.read_text())
    differences = []
    for actual, expected in zip(native, browser, strict=True):
        keys = [key for key in actual if actual[key] != expected[key]]
        print(f"{actual['name']}: {'DIFFERENT ' + ', '.join(keys) if keys else 'EXACT'}")
        if keys:
            differences.append(dict(name=actual["name"], fields=keys))
    # Positive branches must run; matching null rejections alone cannot verify an algorithm.
    by_name = {item["name"]: item for item in native}
    positive = bool(by_name["grid"]["grid"] and by_name["grid-neighbor"]["grid"] and
                    by_name["ruby"]["ruby"] and by_name["row-end"]["ends"]["rects"] and
                    by_name["adjacent-dots"]["dots"])
    report = dict(exact=not differences and positive, fixtures=len(native),
                  positiveAnnotationAndGridBranches=positive, differences=differences)
    (directory / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    if differences or not positive:
        raise SystemExit("Source-glyph primitive parity failed; inspect saved native/browser outputs.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-overlay", type=pathlib.Path, default=ROOT / "Scripts/native-render-parity/reference-source")
    parser.add_argument("--output-dir", type=pathlib.Path)
    args = parser.parse_args()
    if args.output_dir:
        run(args.output_dir.resolve(), args.reference_overlay.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="aidoku-native-source-glyph-parity-") as temp:
            run(pathlib.Path(temp), args.reference_overlay.resolve())


if __name__ == "__main__":
    main()
