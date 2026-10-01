"""Compare immutable iOS checkpoints before repeating the full PDF/RGBA proof."""
from pathlib import Path
import argparse
import hashlib
import json

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument("--previous", type=Path, default=ROOT / "build/native-render-parity/verify-han-build41-snapshot")
parser.add_argument("--current", type=Path, default=ROOT / "build/native-render-parity/verify-han-build42-snapshot")
parser.add_argument("--output", type=Path, default=ROOT / "build/native-render-parity/han-ios-position-proof/build42-metrics.json")
args = parser.parse_args()

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

result = []
for case in json.loads((args.current / "report.json").read_text())["reports"]:
    tracking = case["tracking"]
    previous, current = args.previous / str(tracking), args.current / str(tracking)
    files = ("native.rgba", "web.rgba", "native-font-0-FontFile.bin", "web-font-0-FontFile.bin",
             "native-font-0-unicode.txt", "web-font-0-unicode.txt")
    hashes = {name: {"previous": digest(previous / name), "current": digest(current / name)} for name in files}
    equality = {name: value["previous"] == value["current"] for name, value in hashes.items()}
    layout_path = current / "native-layout.json"
    layout = json.loads(layout_path.read_text())
    rows = []
    for row in layout["coreTextRows"]:
        fields = {key: row[key] for key in ("text", "frameSize", "origin", "layoutOffset")}
        fields["runs"] = [{key: run[key] for key in ("fontName", "fontSize", "fontAscent", "fontDescent",
            "fontLeading", "textMatrix", "positions", "advances", "verticalTranslations")} for run in row["runs"]]
        rows.append(fields)
    result.append(dict(tracking=tracking, identicalToPrevious=equality, sourceSHA256=hashes,
        nativeLayoutSHA256=digest(layout_path), rows=rows))
args.output.parent.mkdir(parents=True, exist_ok=True)
args.output.write_text(json.dumps(dict(scope="Actual-iOS immutable checkpoint identity and actual oriented CoreText run metrics; named-font lookup is not substituted.",
    previous=str(args.previous), current=str(args.current), scriptSHA256=digest(Path(__file__)), cases=result), ensure_ascii=False, indent=2))
print(json.dumps([{key: row[key] for key in ("tracking", "identicalToPrevious")} for row in result], indent=2))
