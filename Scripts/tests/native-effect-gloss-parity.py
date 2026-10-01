#!/usr/bin/env python3
"""Frozen final effect gloss DOM policy vs actual native grouping/placement policy.

The fixture gives both versions identical deterministic text metrics and white
source pixels. Browser execution uses Node only, with no WebKit or OCR provider.
"""
from __future__ import annotations
import argparse
import copy
import json
import math
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]
OVERLAY = ROOT / "Aidoku/Core/Translation/NativeEngine/Overlay"
FIXTURES = ROOT / "Scripts/tests/fixtures/native-effect-gloss"
REFERENCE = ROOT / "Scripts/native-render-parity/reference-source"


def fixtures() -> list[dict]:
    output = []
    def main(id="effect", text="찰칵", role="sfx", source=None):
        source = source or [100, 200, 80, 30]
        return dict(id=id, text=text, role=role, source=source, ink=source, fontSize=15, glyph=30,
                    fill=[20, 20, 20], background=[255, 255, 255],
                    plates=[dict(rect=[source[0]-6, source[1]-6, source[2]+12, source[3]+12], colour=[0, 0, 0])])
    for name in ["single", "joined-pieces", "repeated-copies", "repeated-syllable", "vertical",
                 "tilted", "steep-tilt", "near-vertical-tilt", "multicolour-title", "weak-alone", "balloon", "replaced-glyphs", "inpainting-title", "blocked", "source-cut",
                 "partial-note-rollback", "swapped-outline", "different-effect-colours"]:
        records = [main()]
        if name == "joined-pieces":
            records = [main(text="카", source=[100, 200, 30, 30]), main("piece", "파앗", "piece", [133, 200, 34, 30])]
        elif name == "repeated-copies":
            records += [main("copy", "찰칵", source=[100, 267, 80, 30])]
        elif name == "repeated-syllable":
            records = [main(text="아아", source=[100, 200, 50, 30]), main("copy", "아", source=[100, 260, 50, 30])]
        elif name == "vertical":
            records[0]["vertical"] = True
        elif name in ["tilted", "steep-tilt", "near-vertical-tilt"]:
            records[0]["quad"] = [140, 215, 80, 30, {"tilted": math.pi / 9, "steep-tilt": math.pi / 4, "near-vertical-tilt": math.pi * .45}[name]]
        elif name == "multicolour-title":
            records = [main(text="구세주", role="title"), main("subtitle", "《메시아》", "title", [113, 232, 54, 12])]
            records[1]["glyph"] = 12; records[1]["fill"] = [220, 20, 20]
        elif name == "weak-alone":
            records[0]["role"] = "piece"
        elif name == "balloon":
            records[0]["balloon"] = True
        elif name == "replaced-glyphs":
            records[0]["glyphReplacement"] = True
        elif name == "inpainting-title":
            records[0]["role"] = "title"
        elif name == "blocked":
            records += [dict(id="blocker", text="장벽", source=[0, 0, 320, 520], ink=[0, 0, 320, 520], fontSize=12, glyph=10, plates=[])]
        elif name == "source-cut":
            records += [dict(id="cut", text="작은", source=[174, 205, 12, 20], ink=[290, 460, 12, 20], fontSize=12, glyph=10, hidden=True, plates=[])]
        elif name == "partial-note-rollback":
            records += [main("copy", "찰칵", source=[100, 267, 80, 30]),
                        dict(id="blocker", text="장벽", source=[0, 245, 320, 130], ink=[0, 245, 320, 130], fontSize=12, glyph=10, plates=[])]
        elif name in ["swapped-outline", "different-effect-colours"]:
            records = [main(text="카", source=[100, 200, 30, 30]), main("joined", "파앗", "sfx", [133, 200, 34, 30])]
            if name == "swapped-outline":
                records[0]["stroke"] = [250, 250, 250]
                records[1]["fill"] = [250, 250, 250]; records[1]["stroke"] = [20, 20, 20]
            else:
                records[1]["fill"] = [200, 20, 120]
        for i in range(5):
            records.append(dict(id=f"body{i}", text="본문", source=[10+i*35, 480, 20, 15],
                                ink=[10+i*35, 480, 20, 15], fontSize=12, glyph=10, plates=[]))
        output.append(dict(name=name, frame=[0, 0, 320, 520], records=copy.deepcopy(records), inpainting=name == "inpainting-title"))
    return output


def same(a, b) -> bool:
    if isinstance(a, (float, int)) and isinstance(b, (float, int)):
        return math.isclose(a, b, rel_tol=0, abs_tol=1e-8)
    if isinstance(a, dict) and isinstance(b, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    if isinstance(a, list) and isinstance(b, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    return a == b


def run(directory: pathlib.Path, reference: pathlib.Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    inputs = directory / "input.json"
    inputs.write_text(json.dumps(fixtures(), ensure_ascii=False))
    main = directory / "main.swift"; shutil.copyfile(FIXTURES / "main.swift", main)
    executable = directory / "native-effect-gloss"
    # The production image convenience initializer now shares its pixel reader
    # with palette sampling. Compile that exact helper even though these policy
    # fixtures supply their own deterministic readSource closure.
    sampling = (OVERLAY / "NativeSourceColorSamplingStage.swift").read_text()
    protocol_start = sampling.index("protocol NativeSourcePixelReading:")
    protocol_end = sampling.index("/// Per-page sampling admission", protocol_start)
    protocol = sampling[protocol_start:protocol_end]
    marker = "final class NativeSourcePixelReader: NativeSourcePixelReading {"
    assert sampling.count(marker) == 1
    reader = directory / "NativeSourcePixelReader.swift"
    reader.write_text("import CoreGraphics\nimport Foundation\n" + protocol + marker + sampling.split(marker, 1)[1])
    # The retained-caption adapter carries the production typography Style.
    # Copy its complete metadata declarations and initializer, preserving their
    # behavior without pulling unrelated platform font/layout code into this
    # deterministic grouping/placement-policy fixture.
    typography_source = (OVERLAY / "NativeTranslationTypography.swift").read_text()
    metadata_start = "    enum HorizontalAlignment {"
    metadata_end = "    struct Layout {"
    assert typography_source.count(metadata_start) == 1
    assert typography_source.count(metadata_end) == 1
    metadata = typography_source[typography_source.index(metadata_start):typography_source.index(metadata_end)]
    typography = directory / "NativeTranslationTypographyMetadata.swift"
    typography.write_text("import CoreGraphics\nimport Foundation\nenum NativeTranslationTypography {\n" + metadata + "}\n")
    subprocess.run(["xcrun", "swiftc", str(OVERLAY / "NativeTranslationGlossPlacement.swift"),
                    str(OVERLAY / "NativeTranslationEffectGloss.swift"), str(reader), str(typography),
                    str(main), "-o", str(executable)], check=True)
    native, browser = directory / "native.json", directory / "browser.json"
    subprocess.run([str(executable), str(inputs), str(native)], check=True)
    subprocess.run(["node", str(FIXTURES / "oracle.cjs"), str(inputs), str(reference), str(browser)], check=True)
    actual, expected = json.loads(native.read_text()), json.loads(browser.read_text())
    differences = []
    for a, b in zip(actual, expected, strict=True):
        fields = [k for k in a if not same(a[k], b[k])]
        print(f"{a['name']}: {'DIFFERENT ' + ', '.join(fields) if fields else 'EXACT'}, units={a['units']}, notes={len(a['notes'])}")
        if fields: differences.append(dict(name=a["name"], fields=fields))
    by_name = {a["name"]: a for a in actual}
    positive = all(by_name[n]["units"] > 0 for n in ["single", "joined-pieces", "repeated-copies", "repeated-syllable", "tilted", "multicolour-title", "partial-note-rollback"])
    undo = len(by_name["partial-note-rollback"]["notes"]) == 1 and len(by_name["repeated-copies"]["notes"]) == 2
    report = dict(exact=not differences and positive and undo, fixtures=len(actual), positive=positive, multiNoteRollback=undo,
                  scope="Final unit admission/grouping/placement/source-zone policy; deterministic text metrics and white source raster",
                  finalImagePixelParity=False, differences=differences)
    (directory / "report.json").write_text(json.dumps(report, indent=2)+"\n")
    if not report["exact"]: raise SystemExit("Effect gloss policy parity failed; inspect saved outputs.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reference-overlay", type=pathlib.Path, default=REFERENCE)
    parser.add_argument("--output-dir", type=pathlib.Path)
    args = parser.parse_args()
    if args.output_dir: run(args.output_dir.resolve(), args.reference_overlay.resolve())
    else:
        with tempfile.TemporaryDirectory(prefix="aidoku-native-effect-gloss-") as directory: run(pathlib.Path(directory), args.reference_overlay.resolve())


if __name__ == "__main__": main()
