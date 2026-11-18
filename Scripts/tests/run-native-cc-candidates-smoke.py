#!/usr/bin/env python3
"""Verify full detector CC candidates retain ambiguity; no erasure authorization."""
from pathlib import Path
import subprocess
import sys
import tempfile
ROOT=Path(__file__).resolve().parents[2]
SUPPORT=r'''
import CoreGraphics
import Foundation
struct NativeCoreMLDetectionMap: Equatable, Sendable {
    let width: Int
    let height: Int
    let values: [Float]

    init(width: Int, height: Int, values: [Float]) {
        precondition(width > 0 && height > 0)
        let count = width.multipliedReportingOverflow(by: height)
        precondition(!count.overflow && values.count == count.partialValue)
        self.width = width
        self.height = height
        self.values = values
    }
}

struct NativeCoreMLDetectionMapGeometry: Equatable, Sendable {
    let originX: Int
    let originY: Int
    let fullWidth: Int
    let fullHeight: Int

    init(originX: Int, originY: Int, fullWidth: Int, fullHeight: Int) {
        precondition(originX >= 0 && originY >= 0)
        precondition(fullWidth > 0 && fullHeight > 0)
        precondition(originX < fullWidth && originY < fullHeight)
        self.originX = originX
        self.originY = originY
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
    }
}

struct NativeCoreMLDetectionBox: Equatable, Sendable {
    let polygon: [CGPoint]
    let score: Double
    /// Probability-supported ink belongs to erasure only, never recognition geometry.
    let erasurePolygons: [[CGPoint]]
    /// Map- and neighbor-supported fine print may sample a little more context
    /// for recognition. It never enlarges detection or erasure ownership.
    let recognitionPolygon: [CGPoint]?
    let isThinFinePrintRecovery: Bool
    let finePrintRetryPolygons: [[CGPoint]]

    init(polygon: [CGPoint], score: Double, erasurePolygons: [[CGPoint]] = [],
         recognitionPolygon: [CGPoint]? = nil, isThinFinePrintRecovery: Bool = false,
         finePrintRetryPolygons: [[CGPoint]] = []) {
        self.polygon = polygon
        self.score = score
        self.erasurePolygons = erasurePolygons
        self.recognitionPolygon = recognitionPolygon
        self.isThinFinePrintRecovery = isThinFinePrintRecovery
        self.finePrintRetryPolygons = finePrintRetryPolygons
    }
}
'''
HARNESS=r'''
import Foundation
import CoreGraphics
func box(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat)->NativeCoreMLDetectionBox {.init(polygon:[.init(x:x,y:y),.init(x:x+w,y:y),.init(x:x+w,y:y+h),.init(x:x,y:y+h)],score:0.99)}
let geometry=NativeCoreMLDetectionMapGeometry(originX:0,originY:0,fullWidth:32,fullHeight:32)
func collect(_ values:[Float],_ boxes:[NativeCoreMLDetectionBox]) throws->[NativeOCRDetectorSeedEvidence?] {try NativeOCRDBOwnershipCandidates.collect(map:.init(width:32,height:32,values:values),boxes:boxes,sourceWidth:32,sourceHeight:32,geometry:geometry)}
var pixels=[Float](repeating:0,count:1024)
for y in 10..<15 {for x in 10..<13 {pixels[y*32+x]=0.95}}
let single=try collect(pixels,[box(4,4,20,20)])
precondition(single[0]!.components[0].pixelCount==15 && single[0]!.completeCCScan==true)
let partial=try collect(pixels,[box(4,4,7,20),box(9,9,6,8)])
precondition(partial[0]!.components.isEmpty && partial[0]!.ambiguousComponents!.count==1)
let candidate=partial[1]!.candidateComponents![0]
precondition(candidate.outsideCompetingCells==[10])
precondition(candidate.component==partial[0]!.ambiguousComponents![0])
precondition(candidate.competingOwnerIDs==[partial[0]!.ownerID])
let ambiguous=try collect(pixels,[box(4,4,20,20),box(9,9,6,8)])
precondition(ambiguous.allSatisfy{$0!.candidateComponents!.isEmpty && $0!.ambiguousComponents!.count==1})
var nan=pixels;nan[0] = .nan
let n=try collect(nan,[box(4,4,20,20)]);precondition(n == [nil])
// An invalid neighbor must fail during the component walk, not during a
// pre-scan or after the later cells are visited in the outer scan.
enum Cancel: Error { case requested }
var invalidNeighbor=pixels;invalidNeighbor[12*32+13] = .infinity
var callbackCount=0
let invalid=try NativeOCRDBOwnershipCandidates.collect(
    map:.init(width:32,height:32,values:invalidNeighbor),boxes:[box(4,4,20,20)],
    sourceWidth:32,sourceHeight:32,geometry:geometry,cancellationCheck:{callbackCount+=1})
precondition(invalid == [nil] && callbackCount==2)
callbackCount=0
do {
    _=try NativeOCRDBOwnershipCandidates.collect(
        map:.init(width:32,height:32,values:invalidNeighbor),boxes:[box(4,4,20,20)],
        sourceWidth:32,sourceHeight:32,geometry:geometry,cancellationCheck:{
            callbackCount+=1
            if callbackCount==2 {throw Cancel.requested}
        })
    preconditionFailure("The component cancellation must win over the invalid neighbor")
} catch Cancel.requested {precondition(callbackCount==2)}
var edge=pixels;for x in 0..<10 {edge[12*32+x]=0.95}
let e=try collect(edge,[box(4,4,20,20)]);precondition(e == [nil])
let multiple=try collect(pixels,[box(4,4,7,20),box(11,4,10,20),box(9,9,6,8)])
let multiCandidate=multiple[2]!.candidateComponents![0]
precondition(multiCandidate.competingOwnerIDs.count==2)
precondition(Set(multiCandidate.outsideCompetingCells)==Set([5,10]))
precondition(multiple[0]!.ambiguousComponents![0]==multiCandidate.component && multiple[1]!.ambiguousComponents![0]==multiCandidate.component)
// Two arms connected at the top form separate runs on the same row.
// The sloped boundary passes through cell centres; its right edge is strict.
var fork=[Float](repeating:0,count:1024)
for y in 5...12 {
    for x in 5...12 where y == 5 || x < 7 || x >= 11 { fork[y*32+x] = 0.95 }
}
let diagonal = NativeCoreMLDetectionBox(polygon: [
    CGPoint(x: 5.5, y: 5.5), CGPoint(x: 12.5, y: 12.5),
    CGPoint(x: 5.5, y: 12.5)
], score: 1)
let forked = try collect(fork, [box(3,3,12,12), diagonal])
let measured = forked[0]!.candidateComponents![0]
let interior = (5...12).flatMap { y in (5...12).filter { x in
    fork[y*32+x] != 0 && y < 12 && x < y
} }
precondition(measured.component.runs.count == 15)
precondition(measured.outsideCompetingCells == [measured.component.pixelCount-interior.count])
// A connected comb with >4096 runs must invalidate its own evidence while
// allowing the other, independent owner on the page to survive.
let largeWidth=176, largeHeight=160
var comb=[Float](repeating:0,count:largeWidth*largeHeight)
for y in 2..<140 {
    for x in 2..<130 where y == 2 || x.isMultiple(of: 2) { comb[y*largeWidth+x]=0.96 }
}
comb[150*largeWidth+155]=1
let combOwners = try NativeOCRDBOwnershipCandidates.collect(
    map:.init(width:largeWidth,height:largeHeight,values:comb),boxes:[box(1,1,140,142),box(150,145,12,12)],
    sourceWidth:largeWidth,sourceHeight:largeHeight,
    geometry:.init(originX:0,originY:0,fullWidth:largeWidth,fullHeight:largeHeight))
precondition(combOwners[0] == nil && combOwners[1]?.components.first?.pixelCount == 1)
let tileGeometry=NativeCoreMLDetectionMapGeometry(originX:8,originY:4,fullWidth:64,fullHeight:64)
let tiled=try NativeOCRDBOwnershipCandidates.collect(map:.init(width:32,height:32,values:pixels),boxes:[box(12,8,20,20)],sourceWidth:64,sourceHeight:64,geometry:tileGeometry)
precondition(tiled[0]!.components[0].seed==14*64+18)
precondition(tiled[0]!.components[0].runs[0] == .init(y:14,x:18,count:3))
precondition(tiled[0]!.ownerID=="db:64x64:8,4:0")
let huge=try NativeOCRDBOwnershipCandidates.collect(map:.init(width:32,height:32,values:pixels),boxes:[box(4,4,20,20)],sourceWidth:32,sourceHeight:32,geometry:.init(originX:0,originY:0,fullWidth:Int.max,fullHeight:Int.max))
precondition(huge == [nil])
let roundtrip=try JSONDecoder().decode([NativeOCRDetectorSeedEvidence?].self,from:JSONEncoder().encode(partial))
precondition(roundtrip==partial)
print("PASS v2 independent, partial/full candidate, all-shared ambiguity, invalid/cancellation order, clipped, multi-competitor, tile identity, overflow and Codable contracts")
if CommandLine.arguments.count>1 {
 let dir=URL(fileURLWithPath:CommandLine.arguments[1]);let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
 func stage(_ name:String)throws->[String:Any] {let file=files.filter{$0.lastPathComponent.hasSuffix("-\(name).json")}.sorted{$0.lastPathComponent<$1.lastPathComponent}.last!;return (try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any])["value"] as! [String:Any]}
 let metadata=try stage("detector-probability-map"),native=try stage("detector-output")
 let raw=try Data(contentsOf:dir.appendingPathComponent(metadata["raw"] as! String));let values=raw.withUnsafeBytes{Array($0.bindMemory(to:Float.self))}
 let width=metadata["width"] as! Int,height=metadata["height"] as! Int
 let lines=native["boxes"] as! [[String:Any]];let boxes=lines.map { line in NativeCoreMLDetectionBox(polygon:(line["polygon"] as! [[String:Double]]).map{CGPoint(x:$0["x"]!,y:$0["y"]!)},score:line["score"] as! Double) }
 let result=try NativeOCRDBOwnershipCandidates.collect(map:.init(width:width,height:height,values:values),boxes:boxes,sourceWidth:native["width"] as! Int,sourceHeight:native["height"] as! Int,geometry:.init(originX:0,originY:0,fullWidth:width,fullHeight:height))
 let data=try JSONEncoder().encode(result);try data.write(to:URL(fileURLWithPath:CommandLine.arguments[2]));print("Actual saved detector-box replay (not live production hook):",result.compactMap{$0}.count,"of",result.count,"owners; bytes",data.count)
}
'''
with tempfile.TemporaryDirectory(prefix="aidoku-cc-candidates-") as directory:
    work=Path(directory)
    (work/"support.swift").write_text(SUPPORT)
    (work/"main.swift").write_text(HARNESS)
    ocr=ROOT/"Aidoku/Core/Translation/NativeEngine/OCR"
    sources=[ocr/(name+".swift") for name in ["NativeOCRSpatialIndex","NativeOCRDetectorSeedEvidence","NativeOCRSourceROIProbabilityEvidence","NativeOCRDBOwnershipCandidates"]]
    subprocess.run(["xcrun","swiftc","-O",str(work/"support.swift"),*map(str,sources),str(work/"main.swift"),"-o",str(work/"check")],check=True)
    subprocess.run([str(work/"check"),*sys.argv[1:]],check=True)
