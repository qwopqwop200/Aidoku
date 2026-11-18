#!/usr/bin/env python3
"""Focused captured-raster to declared-original transport; no image edits/network."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeSourceLetteringScale.swift'
CALLER = (ROOT / 'Aidoku/Core/Translation/NativeEngine/Overlay/NativeTranslationRenderer+TextBoxes.swift').read_text()
assert 'logicalTransport(record: originalScaleRecord,' in CALLER
assert 'capturedWidth: Double(source?.width ?? 0)' in CALLER
harness = r'''import Foundation
func check(_ yes: Bool) { precondition(yes) }
func close(_ a: Double, _ b: Double) { check(abs(a-b) < 1e-8) }
let raw: [String: Any] = ["supported": true, "sourceVertical": true,
    "originalPixelCrossSpan": 40.0, "sampleToOriginalCrossScale": 2.0,
    "originalAlongInkStart": 258.0, "originalUnits": "original-source-pixels",
    "croppedOriginalOrigin": [1591.0,223.0], "croppedOriginalDimensions": [186.0,441.0],
    "originalLaneEvidence": [["crossStart":1653.0,"crossEnd":1694.0,
        "bodyInkAlongStart":258.0,"bodyInkAlongEnd":548.0]]]
let sx = 2600.0/2309.0, sy = 1950.0/1732.0
let mapped = NativeSourceLetteringScale.restorationTransport(record: raw, sourceVertical: true,
    capturedWidth:2309,capturedHeight:1732,originalWidth:2600,originalHeight:1950)
check(mapped["supported"] as? Bool == true)
close(mapped["originalPixelCrossSpan"] as! Double,40*sx)
close(mapped["originalAlongInkStart"] as! Double,258*sy)
let lane = (mapped["originalLaneEvidence"] as! [[String:Any]])[0]
close(lane["crossStart"] as! Double,1653*sx)
close(lane["bodyInkAlongEnd"] as! Double,548*sy)
let logical = NativeSourceLetteringScale.logicalTransport(record:mapped,sourceVertical:true,
    originalCrossLength:2600,logicalCrossLength:430)
close(logical["logicalCrossSpan"] as! Double,40*430/2309)
// No double scaling and no original forecast mutation in the caller.
close(raw["originalAlongInkStart"] as! Double,258)
let same = NativeSourceLetteringScale.restorationTransport(record:raw,sourceVertical:true,
    capturedWidth:2600,capturedHeight:1950,originalWidth:2600,originalHeight:1950)
close(same["originalPixelCrossSpan"] as! Double,40)
var horizontal = raw; horizontal["sourceVertical"] = false
let h = NativeSourceLetteringScale.restorationTransport(record:horizontal,sourceVertical:false,
    capturedWidth:1000,capturedHeight:500,originalWidth:2000,originalHeight:2000)
close(h["originalPixelCrossSpan"] as! Double,160)
close(h["originalAlongInkStart"] as! Double,516)
for width in [0.0, -1.0, Double.nan, Double.infinity, Double.leastNonzeroMagnitude] {
    let bad=NativeSourceLetteringScale.restorationTransport(record:raw,sourceVertical:true,
        capturedWidth:width,capturedHeight:1732,originalWidth:2600,originalHeight:1950)
    check(bad["supported"] as? Bool == false)
}
var unknown=raw;unknown["supported"]=false;unknown["unknownReason"]="no evidence"
let u=NativeSourceLetteringScale.restorationTransport(record:unknown,sourceVertical:true,
    capturedWidth:2309,capturedHeight:1732,originalWidth:2600,originalHeight:1950)
check(u["supported"] as? Bool == false && u["unknownReason"] as? String == "no evidence")
print("PASS: restoration/original/logical coordinates, orientation, identity, unknown and overflow")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-lettering-coordinate-') as folder:
    path=Path(folder)
    (path/'main.swift').write_text(harness)
    subprocess.run(['xcrun','swiftc','-O','-module-cache-path',str(path/'modules'),
                    str(SOURCE),str(path/'main.swift'),'-o',str(path/'probe')],check=True)
    subprocess.run([str(path/'probe')],check=True)
