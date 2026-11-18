#!/usr/bin/env python3
"""Compile exact shared packet builder against metadata carriers; models0."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
helper = (ROOT / "Aidoku/Core/Translation/NativeEngine/OCR/NativeSimpleOCRBoundaryExpansionRuntime.swift").read_text()
program = '''import Foundation
import CoreGraphics
enum NativeSimpleOCRBoundaryExpansion { struct Configuration:Sendable {} }
enum NativeOCRRawCanonicalPolicy { enum SourceAnchorMode {case noPreRecognition,fixedPreRecognition,disabled,noPreRecognitionTerminalRecovery} }
struct NativeCoreMLRecognizedRegion { let sourceIndex:Int;let polygon:[CGPoint];let text:String;let confidence:Double }
struct NativeCoreMLDetectionBox {let polygon:[CGPoint];let score:Float;let erasurePolygons:[[CGPoint]];let detectorSeedEvidence:Int?}
enum NativeOCRIndividualGeometryHypotheses {
 struct Point:Equatable {let x:Double;let y:Double}
 struct Record {let sourceParent:Int;let sourceIndex:Int;let sourceMembers:Set<Int>;let originalDetectorIndex:Int?;let polygon:[Point]}
 struct Individual {let polygon:[Point];let provenance:[Record]}
 struct Output {let individuals:[Individual]}
}
enum NativeOCRPremergeCandidateFeatures {
 struct Point {let x:Double;let y:Double}
 struct DetectorBox {let polygon:[Point];let score:Double}
}
enum NativePostLLMContentReclassifier {
 static func detectorSignals(polygon:[NativeOCRPremergeCandidateFeatures.Point],baseline:[Double]?,originalDetectors:[NativeOCRPremergeCandidateFeatures.DetectorBox],recognitionConfidence:Double)->[Double] {
  [polygon[0].x,polygon[0].y,recognitionConfidence,Double(originalDetectors.count)]+Array(repeating:0,count:11)
 }
}
struct NativeOCRSourceMetadata {let detectorSignals:[Double]?}
struct NativeCoreMLOCRLine {
 let polygon:[CGPoint];let text:String;let score:Double;let orientation:Int;let orientationIsEstimated:Bool
 let erasurePolygons:[[CGPoint]];let detectorSeedEvidence:[Int]?;let acceptedSource:NativeOCRSourceMetadata
}
enum NativeCoreMLOCRPipeline {static func orientation(for:[CGPoint])->Int {0}}
''' + helper + '''
typealias G=NativeOCRIndividualGeometryHypotheses
typealias R=NativeSimpleOCRBoundaryExpansionRuntime
let a:[CGPoint]=[.init(x:0,y:0),.init(x:10,y:0),.init(x:10,y:10),.init(x:0,y:10)]
let b=a.map {CGPoint(x:$0.x+30,y:$0.y)}
func row(_ polygon:[CGPoint],_ parent:Int,_ sourceIndex:Int?=nil)->G.Individual {
 let p=polygon.map {G.Point(x:Double($0.x),y:Double($0.y))}
 return .init(polygon:p,provenance:[.init(sourceParent:parent,sourceIndex:sourceIndex ?? 2+parent,sourceMembers:[],originalDetectorIndex:nil,polygon:p)])
}
let originals=[NativeCoreMLDetectionBox(polygon:a,score:0.2,erasurePolygons:[a],detectorSeedEvidence:11),
 NativeCoreMLDetectionBox(polygon:b,score:0.4,erasurePolygons:[b],detectorSeedEvidence:22)]
let reads=[NativeCoreMLRecognizedRegion(sourceIndex:0,polygon:a.map {CGPoint(x:$0.x-2.5,y:$0.y)},text:"actual-A",confidence:0.8),
 NativeCoreMLRecognizedRegion(sourceIndex:1,polygon:b.map {CGPoint(x:$0.x+2.5,y:$0.y)},text:"actual-B",confidence:0.9)]
let input=G.Output(individuals:[row(b,1),row(a,0)])
let packets=try R.packets(reads:reads,originalAnchors:input,source165Indices:[1,0],originals:originals,preserveOriginalMetadata:true)
precondition(packets[0].polygon==reads[0].polygon && packets[0].score==0.8 && packets[0].text=="actual-A")
precondition(packets[0].detectorSeedEvidence==[11] && packets[1].detectorSeedEvidence==[22])
precondition(packets[0].erasurePolygons==[a] && packets[1].erasurePolygons==[b])
precondition(packets[0].acceptedSource.detectorSignals!.count==15)
precondition(packets[0].acceptedSource.detectorSignals![0] == -2.5 && packets[1].acceptedSource.detectorSignals![0] == 32.5)
precondition(packets[0].acceptedSource.detectorSignals![2]==0.8 && packets[0].acceptedSource.detectorSignals![3]==2)
let off=try R.packets(reads:reads,originalAnchors:.init(individuals:[]),source165Indices:[],originals:originals,preserveOriginalMetadata:false)
precondition(off.allSatisfy {$0.detectorSeedEvidence==nil && $0.erasurePolygons.isEmpty})
for invalid in [G.Output(individuals:[row(b,1),row(a,0,55)]),G.Output(individuals:[row(b,1),row(reads[0].polygon,0)])] {
 do { _=try R.packets(reads:reads,originalAnchors:invalid,source165Indices:[1,0],originals:originals,preserveOriginalMetadata:true);preconditionFailure("invalid ancestry accepted") }
 catch R.Failure.invalidSourceBinding {}
}
print("PASS exact shared packet seam:newquad/newconfidence drives15,explicit reversed parent mapping,provided erasure/seed,defaultOFFnil,bad ancestrythrows;models0")
'''
with tempfile.TemporaryDirectory(prefix="boundary-packet-seam-") as folder:
    path = Path(folder)
    (path / "main.swift").write_text(program)
    subprocess.run(["xcrun", "swiftc", str(path / "main.swift"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
