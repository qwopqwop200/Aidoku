#!/usr/bin/env python3
"""Neutral production-layout regression; no OCR models, images or provider calls.

This verifies the host uses the production planner and typography inputs. It
does not claim identical macOS/iPhone font metrics or final device pixels.
"""
import argparse
import json
import math
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def rotated_region():
    center = (800, 1400)
    angle = math.radians(15)
    polygon = []
    for x, y in [(-250, -70), (250, -70), (250, 70), (-250, 70)]:
        polygon.append([(center[0] + x * math.cos(angle) - y * math.sin(angle)) / 1600,
                        (center[1] + x * math.sin(angle) + y * math.cos(angle)) / 2400])
    xs, ys = zip(*polygon)
    return {"id": 2, "rect": [min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)],
            "source": "斜めの文章です", "translation": "기울어진 문장이야.",
            "sourceOrientation": "horizontal", "polygon": polygon}


def fixture(mode="translateOnly", target="ko", translated="안녕, 만나서 반가워."):
    return {"imageWidth": 1600, "imageHeight": 2400,
            "viewportWidth": 430, "viewportHeight": 645, "target": target,
            "overlay": {"mode": mode, "textPlacement": "replace", "colorMode": "white",
                        "opacity": 1, "preserveSourceTextColor": True,
                        "preserveSourceBackgroundColor": True, "inpaintingEnabled": True},
            "regions": [{"id": 1, "rect": [.1, .12, .3, .12],
                         "source": "こんにちは、元気ですか。", "translation": translated,
                         "sourceOrientation": "horizontal", "polygon": []}, rotated_region()]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reuse-built", action="store_true",
                        help="Use a successfully built current host without invoking its launcher.")
    arguments = parser.parse_args()
    command = ([str(ROOT / "build/image-translation-host/image-translation")]
               if arguments.reuse_built else ["swift", str(ROOT / "Scripts/image-translation.swift")])
    # Never read .env or inherit provider credentials into this neutral check.
    environment = {key: value for key, value in os.environ.items() if not key.startswith("AIDOKU_")}
    environment["AIDOKU_PIPELINE_ROOT"] = str(ROOT)

    with tempfile.TemporaryDirectory(prefix="aidoku-layout-parity-") as temporary:
        path = Path(temporary) / "fixture.json"

        def run(value):
            path.write_text(json.dumps(value, ensure_ascii=False))
            result = subprocess.run([*command, "--layout-fixture", str(path)], env=environment,
                                    cwd=ROOT, capture_output=True, text=True, check=True)
            # Keep compiler diagnostics separate; fixture stdout is JSON only.
            return json.loads(result.stdout)

        normal = run(fixture())
        items = normal["items"]
        assert len(items) == 2, "Production layout dropped a neutral caption"
        assert normal["appearance"]["sourceLetterFonts"].get("serif") is True, \
            "Bundled source serif typography must be available on the host"
        assert all(item["sourceFrame"] == [0, 0, 430, 645] for item in items), \
            "Source geometry must use reader viewport points, not image pixels"
        rotated = next(item for item in items if "기울어진" in item["text"])
        assert math.isclose(rotated["rotation"], math.radians(15), abs_tol=.002), \
            "Production rotation was replaced with an upright estimate"
        plain = next(item for item in items if "안녕" in item["text"])
        assert plain["paddingLeft"] > 1 and plain["paddingTop"] > 1, \
            "Planner padding must replace fixed host 1px insets"
        assert plain["fontScript"] == "korean" and plain["wrappingScript"] == "korean"
        assert plain["lineHeight"] >= plain["fontSize"] > 0

        latin = run(fixture(translated="Hello, friend!"))
        english = next(item for item in latin["items"] if "Hello" in item["text"])
        assert english["fontScript"] == "word" and english["wrappingScript"] == "word", \
            "Typography must follow actual translated text, not the target language setting"

        # The reader normalizes saved overlay settings through the production
        # enforceSourceReplacement policy before planning. A stale dual-mode
        # preference must therefore render the same replacement as the app.
        dual = run(fixture(mode="originalAndTranslation"))
        assert dual["items"] == normal["items"] and dual["appearance"] == normal["appearance"], \
            "Saved overlay modes must use the reader's source-replacement normalization"
        print("Production layout parity regression passed: viewport, rotation, padding, script, reader settings normalization and bundled serif support.")


if __name__ == "__main__":
    main()
