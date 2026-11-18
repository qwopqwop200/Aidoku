#!/usr/bin/env python3
"""Focused real DB producer-to-recovery geometry checks; no OCR model inference."""
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
OCR = ROOT / 'Aidoku/Core/Translation/NativeEngine/OCR'
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

@available(iOS 18.0, *)
struct NativeCoreMLRecognitionRegion: Equatable, Sendable {
    let sourceIndex: Int
    let polygon: [CGPoint]
    let samplingPolygon: [CGPoint]?
    let isThinFinePrintRecovery: Bool
    let finePrintRetryPolygons: [[CGPoint]]
    let useProvidedOrder: Bool
    let minimumSequenceWidth: Int
    let recognitionColumnEvidence: NativeOCRDetectorColumnEvidence?

    init(
        sourceIndex: Int, polygon: [CGPoint], samplingPolygon: [CGPoint]? = nil,
        isThinFinePrintRecovery: Bool = false, finePrintRetryPolygons: [[CGPoint]] = [],
        useProvidedOrder: Bool = false, minimumSequenceWidth: Int = 0,
        recognitionColumnEvidence: NativeOCRDetectorColumnEvidence? = nil
    ) {
        self.sourceIndex = sourceIndex
        self.polygon = polygon
        self.samplingPolygon = samplingPolygon
        self.isThinFinePrintRecovery = isThinFinePrintRecovery
        self.finePrintRetryPolygons = finePrintRetryPolygons
        self.useProvidedOrder = useProvidedOrder
        self.minimumSequenceWidth = minimumSequenceWidth
        self.recognitionColumnEvidence = recognitionColumnEvidence
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLRecognizedRegion: Equatable, Sendable {
    let sourceIndex: Int
    let polygon: [CGPoint]
    let text: String
    let confidence: Double
}


let roundtrip = try JSONDecoder().decode(NativeOCRDetectorColumnEvidence.self, from: JSONEncoder().encode(accepted))
precondition(roundtrip == accepted)
let actualRead = NativeCoreMLRecognizedRegion(sourceIndex:17,polygon:boxes[17].polygon,text:"のです",confidence:0.426385502020518)
let frame = CGRect(x:0,y:0,width:1250,height:882)
let peers=boxes.enumerated().map{NativeCoreMLRecognitionRegion(sourceIndex:$0.offset,polygon:$0.element.polygon)}
func proposal(_ e:NativeOCRDetectorColumnEvidence)->NativeOCRMultilineColumnRecovery.Proposal? {
 NativeOCRMultilineColumnRecovery.proposal(region:.init(sourceIndex:17,polygon:boxes[17].polygon,recognitionColumnEvidence:e),read:actualRead,frame:frame,peers:peers)
}
let result=proposal(roundtrip)!
precondition(result.crops.count == 4)
precondition(accepted.recognitionClearance?.maximumPaddingFractions == [0.24,0.6])
let children=accepted.polygons.map{p in CGRect(x:p.map(\.x).min()!,y:p.map(\.y).min()!,width:p.map(\.x).max()!-p.map(\.x).min()!,height:p.map(\.y).max()!-p.map(\.y).min()!)}
let parent=CGRect(x:925,y:411,width:92,height:202)
func corridor(_ index:Int,_ fraction:Double)->[CGPoint]{
 let c=children[index], left=index+1<children.count ? (c.minX+children[index+1].maxX)/2 : parent.minX
 let right=index>0 ? (c.maxX+children[index-1].minX)/2 : parent.maxX
 let pad=max(1,c.width*fraction), x=max(left,c.minX-pad), end=min(right,c.maxX+pad)
 return rect(x,parent.minY,end-x,parent.height)
}
for (index,fraction) in [0.12,0.24,0.4,0.6].enumerated(){precondition(result.crops[index].polygon == corridor(index/2,fraction))}
var legacy=accepted
legacy.recognitionClearance = .init(polygons:[corridor(0,0.24),corridor(1,0.24)],provenance:proof.provenance,threshold:proof.threshold,ownedComponentPixels:proof.ownedComponentPixels,supportedCells:proof.supportedCells,parentBoxIndex:proof.parentBoxIndex)
let legacyData=try JSONEncoder().encode(legacy)
precondition(!String(decoding:legacyData,as:UTF8.self).contains("maximumPaddingFractions"))
let decodedLegacy=try JSONDecoder().decode(NativeOCRDetectorColumnEvidence.self,from:legacyData)
precondition(proposal(decodedLegacy)!.crops[3].polygon == corridor(1,0.24))
var invalid=accepted
invalid.recognitionClearance!.maximumPaddingFractions=[0.6,0.6]
precondition(proposal(invalid)==nil) // right certificate remains narrow, cannot silently enlarge.
invalid=accepted;invalid.recognitionClearance!.maximumPaddingFractions=[0.24]
precondition(proposal(invalid)==nil)
invalid=accepted;invalid.recognitionClearance!.maximumPaddingFractions=[0.24,0.5]
precondition(proposal(invalid)==nil)
invalid=accepted;invalid.recognitionClearance!.maximumPaddingFractions=nil
precondition(proposal(invalid)==nil) // wide geometry cannot impersonate legacy .24.
let texts=["これは本物","これは本物","なのです","なのです"]
func reads(_ confidence:Double)->[NativeCoreMLRecognizedRegion]{zip(result.crops,texts).map{.init(sourceIndex:17,polygon:$0.0.polygon,text:$0.1,confidence:confidence)}}
precondition(NativeOCRMultilineColumnRecovery.accepted(proposal:result,reads:reads(0.99))?.polygon==boxes[17].polygon)
precondition(NativeOCRMultilineColumnRecovery.accepted(proposal:result,reads:reads(0.94))==nil)
let actualTexts=["もっと見て","もっと見て","ほしい…です♡","ほしい…です♡"]
let actualHigh=zip(result.crops,actualTexts).map{NativeCoreMLRecognizedRegion(sourceIndex:17,polygon:$0.0.polygon,text:$0.1,confidence:0.99)}
precondition(NativeOCRMultilineColumnRecovery.accepted(proposal:result,reads:actualHigh)==nil)
print("PASS actual producer→JSON→consumer four crops (.12/.24,.4/.6); legacy decode, forged maxima, unchanged confidence/order/parent gates. No model inference claimed.")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-multiline-columns-') as temporary:
    directory = Path(temporary)
    source = directory / 'main.swift'
    source.write_text(MAIN)
    binary = directory / 'probe'
    subprocess.run(['swiftc', '-O', *[str(OCR / name) for name in ['NativeOCRDBChildColumnEvidence.swift', 'NativeOCRDBRecognitionClearance.swift', 'NativeOCRMultilineColumnRecovery.swift']], str(source), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(FIXTURE)], check=True)
