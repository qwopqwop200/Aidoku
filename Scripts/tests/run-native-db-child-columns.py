#!/usr/bin/env python3
"""Bounded original DB child-column provenance, excluding erasure geometry.

Actual numeric DB fixture keeps its original detector/source transforms. Minimal
map/box carriers below have no OCR policy; the production extractor runs unchanged.
"""
from pathlib import Path
import subprocess
import sys
import tempfile
ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR/NativeOCRDBChildColumnEvidence.swift'
FIXTURE = ROOT / 'Scripts/tests/fixtures/native-db-child-0025'
MAIN = r'''

import CoreGraphics
import Foundation
struct NativeCoreMLDetectionMap {let width:Int;let height:Int;let values:[Float]}
struct NativeCoreMLDetectionBox {let polygon:[CGPoint]}
struct NativeCoreMLDetectionMapGeometry {let originX:Int;let originY:Int;let fullWidth:Int;let fullHeight:Int}
func rect(_ x:Double,_ y:Double,_ w:Double,_ h:Double)->[CGPoint]{[CGPoint(x:x,y:y),CGPoint(x:x+w,y:y),CGPoint(x:x+w,y:y+h),CGPoint(x:x,y:y+h)]}
let root=URL(fileURLWithPath:CommandLine.arguments[1]);let g=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("geometry.json"))) as! [String:Any]
let data=try Data(contentsOf:root.appendingPathComponent(g["raw"] as! String));let values=data.withUnsafeBytes{Array($0.bindMemory(to:Float.self))};let w=g["width"] as! Int,h=g["height"] as! Int
let boxes=(g["boxes"] as! [[String:Any]]).map{b in NativeCoreMLDetectionBox(polygon:(b["polygon"] as! [[String:Double]]).map{CGPoint(x:$0["x"]!,y:$0["y"]!)})}
let evidence=try NativeOCRDBChildColumnEvidence.extract(map:.init(width:w,height:h,values:values),boxes:boxes,sourceWidth:1250,sourceHeight:882,geometry:.init(originX:g["originX"] as! Int,originY:g["originY"] as! Int,fullWidth:g["fullWidth"] as! Int,fullHeight:g["fullHeight"] as! Int))
for i in evidence.indices {if let e=evidence[i]{print("actual",i,e.componentPixels,e.meanProbabilities,e.polygons)}}
precondition(evidence[17]?.componentPixels == [1235,1121])
let accepted=evidence[17]!
if CommandLine.arguments.count > 2 {
 try JSONEncoder().encode(accepted).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
}
precondition(zip(accepted.cellRuns,accepted.componentPixels).allSatisfy { runs,count in runs.reduce(0,{$0+$1.count})==count })
precondition(accepted.parentBoxIndex == 17 && accepted.threshold == 0.9)
precondition(accepted.recognitionClearance?.ownedComponentPixels == 3552)
precondition(accepted.recognitionClearance?.supportedCells == [1573,1991])
precondition(accepted.recognitionClearance?.maximumPaddingFractions == [0.24,0.6])
let proof = accepted.recognitionClearance!
let decodedProof = try JSONDecoder().decode(NativeOCRDBRecognitionClearance.Evidence.self,from:JSONEncoder().encode(proof))
precondition(decodedProof == proof)
var legacyObject = try JSONSerialization.jsonObject(with:JSONEncoder().encode(proof)) as! [String:Any]
legacyObject.removeValue(forKey:"maximumPaddingFractions")
let legacyProof = try JSONDecoder().decode(NativeOCRDBRecognitionClearance.Evidence.self,
 from:JSONSerialization.data(withJSONObject:legacyObject))
precondition(legacyProof.maximumPaddingFractions == nil)

let geometry=NativeCoreMLDetectionMapGeometry(originX:g["originX"] as! Int,originY:g["originY"] as! Int,
 fullWidth:g["fullWidth"] as! Int,fullHeight:g["fullHeight"] as! Int)
func clearance(_ a:[Float], evidence:NativeOCRDetectorColumnEvidence=accepted)->Bool {
 try! NativeOCRDBRecognitionClearance.prove(map:.init(width:w,height:h,values:a),parent:boxes[17].polygon,
 columns:evidence,foreign:boxes.indices.filter{$0 != 17}.map{boxes[$0].polygon},geometry:geometry) != nil
}
precondition(clearance(values))
// The wider right corridor contains 24 cells of the independent foreign CC.
// It must fall back to .24, while the left .6 remains independently clear.
let rightBounds = accepted.recognitionClearance!.polygons[0]
let leftBounds = accepted.recognitionClearance!.polygons[1]
precondition(abs(rightBounds[1].x - 996.7060810810812) < 1e-8)
precondition(abs(leftBounds[0].x - 942.3564189189188) < 1e-8)

func index(_ x:Int,_ y:Int)->Int {(y-geometry.originY)*w+x-geometry.originX}

var widerUnknown=values;widerUnknown[index(895,500)]=0.2
let narrowFallback = try NativeOCRDBRecognitionClearance.prove(map:.init(width:w,height:h,values:widerUnknown),
 parent:boxes[17].polygon,columns:accepted,foreign:boxes.indices.filter{$0 != 17}.map{boxes[$0].polygon},geometry:geometry)
precondition(narrowFallback?.maximumPaddingFractions == [0.24,0.24])
precondition(narrowFallback?.supportedCells == [1573,1991])
var unknown=values;unknown[index(944,440)]=0.2
precondition(!clearance(unknown)) // Fractional outer crop cell, beyond its centerline.
var foreignBridge=values;for x in 938...952 {foreignBridge[index(x,430)]=0.2}
precondition(!clearance(foreignBridge))
var openEdge=values;for y in 402...430 {openEdge[index(925,y)]=0.2}
precondition(!clearance(openEdge))
var stale=values;let seed=accepted.componentSeeds[0];stale[index(seed%1184,seed/1184)]=0.85
precondition(!clearance(stale))
var nonfinite=values;nonfinite[index(944,440)]=Float.nan
precondition(!clearance(nonfinite))
let crowdedForeign = Array(repeating:rect(926,413,3,3),count:65)
precondition(try! NativeOCRDBRecognitionClearance.prove(map:.init(width:w,height:h,values:values),
 parent:boxes[17].polygon,columns:accepted,foreign:crowdedForeign,geometry:geometry)==nil)
print("PASS bounded ambiguous peer-density veto")
print("PASS per-column .6/.24 original clearance, exact foreign wider veto, unknown wider fallback, legacy Codable")
print("PASS recognition-only clearance actual; unknown fractional-edge, foreign bridge, open component, stale strong support, nonfinite negatives")

func synthetic(joined:Bool=false,dense:Bool=false,foreign:Bool=false,one:Bool=false)->[NativeOCRDetectorColumnEvidence?]{
 var a=[Float](repeating:0,count:100*160)
 func band(_ x:Int){for y in 25..<135{for xx in x..<x+10 {if dense || y%8<6 {a[y*100+xx]=0.98}};if !dense {a[y*100+x+4]=0.98}}}
 band(25);if !one{band(55)}
 if joined {for x in 25..<65{a[80*100+x]=0.98}}
 var b=[NativeCoreMLDetectionBox(polygon:rect(10,10,70,140))]
 if foreign {b.append(.init(polygon:rect(50,15,20,130)))}
 return try! NativeOCRDBChildColumnEvidence.extract(map:.init(width:100,height:160,values:a),boxes:b,sourceWidth:100,sourceHeight:160,geometry:.init(originX:0,originY:0,fullWidth:100,fullHeight:160))
}
precondition(synthetic()[0] != nil)
precondition(synthetic(joined:true)[0] == nil)
precondition(synthetic(dense:true)[0] == nil)
precondition(synthetic(foreign:true)[0] == nil)
precondition(synthetic(one:true)[0] == nil)
print("PASS actual originalDBtwoindependentcolumns; joined/dense/foreign/single negatives")

'''
with tempfile.TemporaryDirectory(prefix='aidoku-db-child-') as temporary:
    directory = Path(temporary)
    source = directory / 'main.swift'
    source.write_text(MAIN)
    binary = directory / 'probe'
    subprocess.run(['swiftc', '-O', str(HELPER), str(HELPER.with_name('NativeOCRDBRecognitionClearance.swift')), str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(FIXTURE), *sys.argv[1:2]], check=True)
