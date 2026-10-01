"""Read-only same-input realization comparisons. Never adjusts captured pixels."""
from pathlib import Path
import argparse, hashlib, json
ROOT = Path(__file__).resolve().parents[4]
SHA = "47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d"
def sha(path): return hashlib.sha256(path.read_bytes()).hexdigest()
def compare(a, b):
    if len(a) != len(b) or len(a) % 4: return {"byteCountsEqual": False, "byteCounts": [len(a), len(b)]}
    changed = maximum = 0
    for i in range(0, len(a), 4):
        deltas = [abs(a[i+c] - b[i+c]) for c in range(4)]
        changed += bool(max(deltas)); maximum = max(maximum, *deltas)
    return {"exactRGBA": changed == 0, "changedPixels": changed, "maxChannelDelta": maximum}
parser = argparse.ArgumentParser()
parser.add_argument("--producer", type=Path, default=ROOT/"build/native-render-parity/verify-source-canvas-producer-build53-snapshot")
parser.add_argument("--native", type=Path)
parser.add_argument("--out", type=Path, default=ROOT/"build/native-render-parity/source-canvas-realization")
args = parser.parse_args(); args.out.mkdir(parents=True, exist_ok=True)
source = args.producer/"immutable-actual44-mask0.rgba"
producer = []
for background in ["transparent", "opaque"]:
    folder = args.producer/background
    original = (folder/"A-draw-before.rgba").read_bytes()
    for mode in ["A-draw-before", "B-draw-after", "C-put-before"]:
        record = json.loads((folder/(mode+"-capture.json")).read_text())
        assert record["sourceCanonicalRGBAEqual"]
        assert sha(folder/(mode+"-source-canvas.png")) == SHA
        assert (folder/(mode+"-source-canvas.rgba")).read_bytes() == source.read_bytes()
        result = compare(original, (folder/(mode+".rgba")).read_bytes())
        producer.append({"background": background, "mode": mode, "sourcePNGHash": SHA,
            "sourceRGBAHash": sha(source), "size": [record["width"], record["height"]], "versusA": result})
report = {"scope": "Public realization hypothesis; no fitted kernel or pixel modification.",
    "producerSnapshot": str(args.producer), "producer": producer,
    "backendSwitchEstablished": False, "nativeExecuted": args.native is not None, "native": []}
if args.native:
    doc = json.loads((args.native/"report.json").read_text())
    assert doc["fixturePNGHash"] == SHA
    for record in doc["reports"]:
        folder = args.native/record["name"]
        same = record["sourceCanonicalRGBAEqual"] and (folder/"source-realized.rgba").read_bytes() == source.read_bytes()
        result = {"name": record["name"], "sameSource": same, "size": record["captureSize"],
            "sourceMetadata": record["sourceMetadata"], "comparisons": []}
        if same:
            data = (folder/"capture.rgba").read_bytes()
            for mode in ["A-draw-before", "B-draw-after", "C-put-before"]:
                webRecord = json.loads((args.producer/record["background"]/(mode+"-capture.json")).read_text())
                dimensions = record["captureSize"] == [webRecord["width"], webRecord["height"]]
                result["comparisons"].append({"webMode": mode, "dimensionsEqual": dimensions,
                    **(compare(data, (args.producer/record["background"]/(mode+".rgba")).read_bytes()) if dimensions else {})})
        report["native"].append(result)
    report["nativeControlReport"] = {k: doc[k] for k in ["expectedCount", "count", "complete", "sourceAndCaptureControlsPassed", "os", "timingComparisons", "filterComparisons", "failures"] if k in doc}
(args.out/"comparison.json").write_text(json.dumps(report, indent=2))
print(json.dumps({"report": str(args.out/"comparison.json"), "producerControls": len(producer), "nativeControls": len(report["native"])}))
