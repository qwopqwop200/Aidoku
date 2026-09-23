"""Export frozen real-comics-20000 rotation regressions to simulator Documents.

Usage: python3 Scripts/tests/export-slanted-text-fixtures.py CONTAINER/Documents/SlantedText
Requires Pillow; keeps all unrelated simulator documents intact.
"""
import argparse
import base64
import hashlib
import json
import zlib
from pathlib import Path

from PIL import Image

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("destination", type=Path)
parser.add_argument("--corpus", type=Path, default=Path(__file__).resolve().parents[3] / "datasets/real-comics-20000")
args = parser.parse_args()
fixtures = json.loads((Path(__file__).parent / "fixtures/slanted-text.json").read_text())
args.destination.mkdir(parents=True, exist_ok=True)
captures = {}
original_pages = 0
rotated_pages = 0
for fixture in fixtures:
    if capture := fixture.get("capturedFixture"):
        if capture not in captures:
            captures[capture] = {f["id"]: f for f in json.loads((Path(__file__).parent / "fixtures" / capture).read_text())["cases"]}
        row = captures[capture][fixture["id"]]
        image = Image.frombytes("RGBA", (row["w"], row["h"]), zlib.decompress(base64.b64decode(row["rgba"])))
        image.save(args.destination / (fixture["id"] + ".png"))
        if full := fixture.get("fullSource"):
            # Fresh OCR uses the complete real page; tiny crops are reserved
            # for controlled mask/layout tests and lose detector context.
            if fixture["expectedAngle"] in [-25, 25]:
                source = args.corpus / full["source_path"]
                if hashlib.sha256(source.read_bytes()).hexdigest() != full["source_sha256"]:
                    raise ValueError(f"Full-page hash mismatch: {fixture['id']}")
                with Image.open(source) as opened:
                    opened.convert("RGB").rotate(-fixture["expectedAngle"], Image.Resampling.BICUBIC,
                        expand=True, fillcolor="white").save(args.destination / (fixture["id"] + "-full.png"))
                rotated_pages += 1
        continue
    source = args.corpus / fixture["source_path"]
    if hashlib.sha256(source.read_bytes()).hexdigest() != fixture["sha256"]:
        raise ValueError(f"Source hash mismatch: {fixture['id']}")
    with Image.open(source) as opened:
        image = opened.convert("RGB")
        cropped = image.crop(fixture["crop"])
        if augmentation := fixture.get("augmentation"):
            cropped = cropped.rotate(-augmentation["rotationDegrees"], Image.Resampling.BICUBIC,
                                     expand=True, fillcolor="white")
        if list(cropped.size) != fixture["size"]:
            raise ValueError(f"Transformed image dimensions do not match quad coordinates: {fixture['id']}")
        cropped.save(args.destination / (fixture["id"] + ".png"))
        if fixture.get("freshOCR"):
            image.save(args.destination / (fixture["id"] + "-full.png"))
            original_pages += 1
(args.destination / "fixtures.json").write_text(json.dumps(fixtures, ensure_ascii=False, indent=2) + "\n")
print(f"Exported {len(fixtures)} crops, {original_pages} original full pages and "
      f"{rotated_pages} rotated full-page inputs to {args.destination}")
