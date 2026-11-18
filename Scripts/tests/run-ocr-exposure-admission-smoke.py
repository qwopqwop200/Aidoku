#!/usr/bin/env python3
"""Compile the actual exposure-admission block with synthetic returned rows only.

Use --source-root when auditing a newer parent checkout. No models, images,
labels, host build, shared cache, or pipeline writes. Source drift fails closed.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args()
    ocr = args.source_root / "Aidoku/Core/Translation/NativeEngine/OCR"
    source = (ocr / "NativeCoreMLOCRPipeline.swift").read_text()
    start = source.index("                    var directlyAdmitted: [[String: Any]] = []")
    end = source.index("                    diagnostics = diagnostics.addingRecovery(exposed.diagnostics", start)
    admission = source[start:end]
    assert "acceptedIDs.insert" in admission and "read.polygon == original.polygon" in admission
    recognizer = (ocr / "NativeCoreMLRecognizer.swift").read_text()
    carriers = recognizer[recognizer.index("@available(iOS 18.0, *)"):
                          recognizer.index("/// Explicit in-memory diagnostic")]
    harness = r'''
import Foundation
import CoreGraphics
struct NativeOCRDetectorColumnEvidence: Equatable, Sendable {}
''' + carriers + r'''
func quad(_ x: CGFloat) -> [CGPoint] {
    [.init(x:x,y:10),.init(x:x+20,y:10),.init(x:x+20,y:90),.init(x:x,y:90)]
}
let missing = [NativeCoreMLRecognitionRegion(sourceIndex:1,polygon:quad(40)),
               NativeCoreMLRecognitionRegion(sourceIndex:3,polygon:quad(120))]
let incumbent = NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:quad(0),text:"既存",confidence:0.99)
func read(_ id: Int = 1, _ confidence: Double = 0.96, _ polygon: [CGPoint]? = nil,
          _ text: String = "「あう……」") -> NativeCoreMLRecognizedRegion {
    .init(sourceIndex:id,polygon:polygon ?? quad(CGFloat(id*40)),text:text,confidence:confidence)
}
struct Result { let regions: [NativeCoreMLRecognizedRegion] }
func admit(_ rows: [NativeCoreMLRecognizedRegion], threshold: Double = 0.75) -> [NativeCoreMLRecognizedRegion] {
    let requestID = "synthetic-exposure"
    let exposed = Result(regions:rows)
    var selected = [incumbent]
    var acceptedIDs = Set(selected.map(\.sourceIndex))
''' + admission + r'''
    return selected
}
@main struct Check {
    static func main() {
        let strong = read()
        let result = admit([strong])
        precondition(result == [incumbent,strong])
        precondition(result[1].sourceIndex == missing[0].sourceIndex && result[1].polygon == missing[0].polygon)
        precondition(admit([read(1,0.75)]).count == 2)
        precondition(admit([read(1,0.749)]).count == 1)
        precondition(admit([read(1,0.95)],threshold:0.96).count == 1)
        for invalid in [read(1,.nan),read(1,.infinity),read(1,-0.1),read(1,0.99,nil,""),
                        read(1,0.99,nil," \n"),read(1,0.99,quad(41)),
                        read(1,0.99,Array(quad(40).reversed())),read(99,0.99,quad(40)),
                        read(0,0.99,incumbent.polygon),read(2,0.99,quad(80))] {
            precondition(admit([invalid]) == [incumbent], "Invalid/out-of-scope returned row admitted")
        }
        precondition(admit([strong,strong]) == [incumbent,strong])
        let second = read(3,0.97)
        precondition(Set(admit([strong,second,strong]).map(\.sourceIndex)) == [0,1,3])
        precondition(admit([strong,second,strong]).count == 3)
        // Source-index metadata selection is unchanged: no retry quad becomes
        // a removal polygon, and the old accepted source is never replaced.
        let masks = [0:[quad(2)],1:[quad(43)],3:[quad(123)]]
        let owners = [0:"owner-zero",1:"owner-one",3:"owner-three"]
        precondition(masks[result[1].sourceIndex] == masks[missing[0].sourceIndex])
        precondition(owners[result[1].sourceIndex] == "owner-one")
        precondition(result[0] == incumbent)
        print("PASS exact exposure admission: original ID/quad, unchanged caller floor, incumbent, duplicate, malformed and ownership controls")
    }
}
'''
    with tempfile.TemporaryDirectory(prefix="aidoku-exposure-smoke-") as directory:
        folder = Path(directory)
        (folder / "Harness.swift").write_text(harness)
        started = time.monotonic()
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(folder / "modules"),
                        str(folder / "Harness.swift"), "-o", str(folder / "check")], check=True)
        print(f"Focused compilation seconds: {time.monotonic() - started:.3f}")
        result = subprocess.run([str(folder / "check")], check=True, text=True, capture_output=True)
        events = [json.loads(line.split(" ", 1)[1]) for line in result.stderr.splitlines()
                  if line.startswith("causal_low_raw_exposure ")]
        assert len(events) == 17, len(events)
        assert events[0]["ordinaryThreshold"] == 0.75
        assert len(events[0]["directlyAdmitted"]) == 1
        assert len(events[-2]["directlyAdmitted"]) == 2
        assert all(row["originalGeometryBound"] for event in events for row in event["directlyAdmitted"])
        print(result.stdout.strip())
        print(f"PASS {len(events)} actual exposure-audit records; no renderer/pixel-quality claim")


if __name__ == "__main__":
    main()
