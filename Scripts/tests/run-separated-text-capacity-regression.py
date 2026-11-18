#!/usr/bin/env python3
"""Run the native renderer on neutral, source-displaced text fixtures; no OCR/API."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "build/image-translation-host/image-translation"


def item(id, text, x, y, width, height, owner, kept=False):
    return {"id": id, "text": text, "x": x, "y": y, "width": width, "height": height,
            "fontSize": 8, "lineHeight": 9.6, "paddingLeft": 1, "paddingRight": 1,
            "paddingTop": 1, "paddingBottom": 1, "sourceFontSize": 7,
            "sourceBounds": [owner[0] / 120, owner[1] / 100, owner[2] / 120, owner[3] / 100],
            "sourceFrame": [0, 0, 120, 100], "sourceVertical": True, "vertical": False,
            "sourceTextOnly": False, "keptLettering": kept, "rotation": 0,
            "fontScript": "korean", "wrappingScript": "korean"}


def main():
    with tempfile.TemporaryDirectory(prefix="aidoku-separated-capacity-") as temporary:
        run = Path(temporary) / "input"
        for number, (gap, protected) in enumerate(((0, False), (4, False), (8, False), (0, True)), 1):
            directory = run / f"{number:04d}"
            directory.mkdir(parents=True)
            # Open, textured source: no balloon is invented from a uniform canvas.
            image = Image.new("RGB", (1200, 1000))
            draw = ImageDraw.Draw(image)
            for x in range(0, 1200, 20):
                for y in range(0, 1000, 20):
                    draw.rectangle((x, y, x + 19, y + 19), fill=(
                        110 + (x * 13 + y * 7) % 120, 100 + (x * 3 + y * 11) % 120,
                        120 + (x * 17 + y * 5) % 100))
            for y in range(110, 680, 85):
                draw.rectangle((465 + gap * 10, y, 505 + gap * 10, y + 45),
                               fill=(30, 30, 30), outline=(245, 245, 245), width=5)
            image.save(directory / "input.png")
            target = item("shifted", "같은 폭을 유지", 20 + gap, 10, 24, 60,
                          [45 + gap, 10, 20, 60])
            kept = item("kept", "", 15 + gap, 10, 20, 60, [15 + gap, 10, 20, 60], True)
            items = [target, kept]
            if protected:
                items.append(item("protected", "", 40, 8, 30, 66, [40, 8, 30, 66], True))
            payload = {"stage": "render-payload", "value": {
                "hostViewport": [120, 100],
                "nativeLayout": {"version": 1, "imageSize": [1200, 1000],
                    "viewport": [120, 100], "sourceRect": [[0, 0], [120, 100]],
                    "sourceObjectFit": "contain", "items": items},
                "nativeSettings": {"visible": True, "mode": "translateOnly",
                    "textPlacement": "replace", "opacity": 1, "inpaintingEnabled": False,
                    "preserveSourceTextColor": True, "preserveSourceBackgroundColor": True}}}
            (directory / "001-render-payload.json").write_text(json.dumps(payload, ensure_ascii=False))
            (directory / "final.json").write_text('{"mode":"translation"}')
        env = dict(os.environ)
        env["AIDOKU_PIPELINE_ROOT"] = str(ROOT)
        dest = Path(temporary) / "rendered"
        result = subprocess.run([str(BINARY), "--render-run", str(run), str(dest)],
                                cwd=ROOT, env=env, capture_output=True, text=True)
        assert result.returncode == 0, result.stdout + result.stderr
        recovered = 0
        for directory in sorted(dest.glob("[0-9][0-9][0-9][0-9]")):
            data = json.loads((directory / "001-native-render-diagnostics.json").read_text())["value"]
            assert not data.get("omittedInputs"), data.get("omittedInputs")
            card = next(c for c in data["cards"] if c["id"] == "shifted")
            if directory.name == "0004":
                assert card.get("separatedTextCapacityRecovered") is not True
                assert card["fits"] is False
                assert card["textFrame"][2] < 4
                assert card["separatedTextCapacityRejections"].get("ink-clip-or-protection", 0) > 0
                continue
            assert card["fits"] is True, (directory.name, card.get("separatedTextCapacityRejections"))
            assert card["panelShape"] == "rectangle" and card["backgroundClip"] == []
            assert card["inputUTF16Length"] == len("같은 폭을 유지".encode("utf-16-le")) // 2
            assert card["textFrame"][2] > card["initialRequestedPanelIntersection"][2]
            recovered += card.get("separatedTextCapacityRecovered") is True
            audit = data["finalTextClipAudits"]["shifted"]
            assert audit["status"] == "measured-within-allocation", audit
            assert all(m["clipLossPixels"] == 0 for m in audit["modes"]), audit
        assert recovered > 0, "The synthetic displacement must exercise capacity recovery"
        print(json.dumps({"neutral_fixtures": 4, "capacity_recoveries": recovered,
                          "complete_fit": 3, "clip_loss": 0, "OCR_API_calls": 0}))


if __name__ == "__main__":
    main()
