#!/usr/bin/env python3
"""Isolated source ROI probability upper-bound and provenance contracts."""
from pathlib import Path
import subprocess,tempfile
root=Path(__file__).resolve().parents[2]
SWIFT=r'''
import Foundation
var checks=0
func check(_ b:Bool){precondition(b);checks += 1}
typealias E = NativeOCRSourceROIProbabilityEvidence
let digest=String(repeating:"a",count:64)
let d=E.Detector(originX:0,originY:0,width:4,height:4,fullWidth:4,fullHeight:4)
let e=E.capture(sourceWidth:2,sourceHeight:2,sourceDigest:digest,roi:.init(x:0,y:0,width:2,height:2),detector:d, probabilities:(0..<16).map { $0 == 5 ? 0.9 : 0.000257 })!
check(Array(e.upperBounds)==[230,1,1,1]);check(e.isValid)
check(try JSONDecoder().decode(E.self,from:JSONEncoder().encode(e)) == e)
for bad: Float in [.infinity, .nan, -1, 2] {
 let q=E.capture(sourceWidth:4,sourceHeight:4,sourceDigest:digest,roi:.init(x:0,y:0,width:1,height:1),
                 detector:d,probabilities:[Float](repeating:bad,count:16))!
 check(q.upperBounds.first==255)
}
check(E.capture(sourceWidth:4,sourceHeight:4,sourceDigest:digest,roi:.init(x:0,y:0,width:1,height:1),
                detector:d,probabilities:[])==nil)
let dirty=E.Detector(originX:1,originY:1,width:2,height:2,fullWidth:4,fullHeight:4)
let q=E.capture(sourceWidth:4,sourceHeight:4,sourceDigest:digest,roi:.init(x:0,y:0,width:2,height:2),detector:dirty,probabilities:[0,0,0,0])!
check(Array(q.upperBounds)==[255,255,255,0])
check(E.capture(sourceWidth:4,sourceHeight:4,sourceDigest:"wrong",roi:.init(x:0,y:0,width:1,height:1),detector:d,probabilities:[Float](repeating:0,count:16))==nil)
check(E.capture(sourceWidth:1024,sourceHeight:1024,sourceDigest:digest,roi:.init(x:0,y:0,width:1024,height:1024),detector:d,probabilities:[Float](repeating:0,count:16))==nil)
let packed:[UInt8]=[1,2,3,4,5,6,7,8],padded:[UInt8]=[1,2,3,4,9,9,5,6,7,8,0,0]
let a=packed.withUnsafeBufferPointer{E.sourceIdentity(rgba:$0,width:1,height:2,bytesPerRow:4)}
let b=padded.withUnsafeBufferPointer{E.sourceIdentity(rgba:$0,width:1,height:2,bytesPerRow:6)}
check(a==b && a != nil)
let up=E.capture(sourceWidth:8,sourceHeight:8,sourceDigest:digest,roi:.init(x:1,y:1,width:2,height:2),detector:d,probabilities:(0..<16).map { $0 == 5 ? 1 : 0 })!
check(Array(up.upperBounds)==[0,0,0,255])
let fractional=E.capture(sourceWidth:4,sourceHeight:4,sourceDigest:digest,roi:.init(x:0,y:0,width:2,height:2),detector:d,probabilities:[Float](repeating:0.000257,count:16))!
check(Array(fractional.upperBounds)==[1,1,1,1])
// One destination cell covers five detector columns and three rows; a
// central maximum or invalid cell must survive both projection passes.
let wide = E.Detector(originX:0,originY:0,width:10,height:3,fullWidth:10,fullHeight:3)
var values = [Float](repeating:0,count:30)
values[12] = 0.75
values[17] = .nan
let projected = E.capture(sourceWidth:2,sourceHeight:1,sourceDigest:digest,
                          roi:.init(x:0,y:0,width:2,height:1),detector:wide,probabilities:values)!
check(Array(projected.upperBounds) == [192,255])
let truncated=E(version:1,sourceWidth:4,sourceHeight:4,sourceDigest:digest,roi:fractional.roi,detector:d,upperBounds:fractional.upperBounds.dropLast())
check(!truncated.isValid)
check(E.capture(sourceWidth:1,sourceHeight:1,sourceDigest:digest,roi:.init(x:0,y:0,width:1,height:1),detector:.init(originX:0,originY:0,width:32768,height:32768,fullWidth:32768,fullHeight:32768),probabilities:[])==nil)
print("PASS",checks)
'''
with tempfile.TemporaryDirectory(prefix="aidoku-roi-evidence-") as work:
 p=Path(work); (p/"main.swift").write_text(SWIFT)
 subprocess.run(["xcrun","swiftc","-O",str(root/"Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRSourceROIProbabilityEvidence.swift"),str(p/"main.swift"),"-o",str(p/"test")],check=True)
 subprocess.run([str(p/"test")],check=True)
