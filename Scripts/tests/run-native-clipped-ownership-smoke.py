#!/usr/bin/env python3
"""Check conservative DB-component alias ownership with native geometry."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import CoreGraphics
import Foundation
func polygon(_ r:CGRect)->[CGPoint] {[CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)]}
func rect(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat,_ scale:CGFloat)->CGRect {CGRect(x:x*scale,y:y*scale,width:w*scale,height:h*scale)}
var cases=0
for scale:CGFloat in [0.5,1,2] { for reverse in [false,true] { for variant in 0..<17 {
 let body=rect(950.17,434.87,43.28,156.19,scale)
 let alias=rect(1002.96,434.87,13.72,134.75,scale)
 var own=[polygon(body),polygon(alias)]
 if variant==2 {own=[polygon(alias)]}
 if variant==7 {own[1][0].x+=scale}
 if variant==16 {own[1][3]=own[1][0]}
 if variant==10 {own[0]=polygon(rect(990,434.87,20,156.19,scale))}
 var full=rect(1002.96,434.87,21.11,134.75,scale)
 if variant==3 {full=rect(1004,434.87,21.11,134.75,scale)}
 if variant==4 {full=alias}
 if variant==6 {full=rect(1002.96,434,21.11,135.62,scale)}
 let a=PaddleOCRLine(poly:polygon(rect(925,411,variant==11 ? CGFloat.infinity : (variant==1 ? 100:92),202,scale)).map{PaddleOCRPoint(x:Double($0.x),y:Double($0.y))},text:variant==13 ? "■■":"のです",score:0.98,orientationRaw:variant==8 ? "horizontal":"vertical",singleVerticalColumn:variant != 9,auxiliaryInkRects:own.map { p in CGRect(x:p.map(\.x).min()!,y:p.map(\.y).min()!,width:p.map(\.x).max()!-p.map(\.x).min()!,height:p.map(\.y).max()!-p.map(\.y).min()!) },auxiliaryInkPolygons:own)
 var fullPolygon=polygon(full)
 if variant==15 {fullPolygon[3]=fullPolygon[0]}
 let b=PaddleOCRLine(poly:polygon(rect(992,424,variant==12 ? CGFloat.infinity : (variant==5 ? 20:61),155,scale)).map{PaddleOCRPoint(x:Double($0.x),y:Double($0.y))},text:variant==14 ? "■■":"私のおまん",score:0.98,orientationRaw:"vertical",singleVerticalColumn:false,auxiliaryInkRects:[full],auxiliaryInkPolygons:[fullPolygon])
 let input=reverse ? [b,a]:[a,b];let result=NativeOCRAuxiliaryOwnership.deduplicating(input)
 for (x,y) in zip(input,result) {precondition(x.poly==y.poly && x.text==y.text && x.score==y.score && x.orientationRaw==y.orientationRaw && x.singleVerticalColumn==y.singleVerticalColumn)}
 let ownResult=result.first{$0.text==a.text}!
 let expected=own.count-(variant==0 ? 1:0)
 if ownResult.auxiliaryInkPolygons.count != expected {fatalError("variant \(variant) scale \(scale) reverse \(reverse) actual \(ownResult.auxiliaryInkPolygons.count) expected \(expected)")}
 precondition(result.first{$0.text==b.text}!.auxiliaryInkPolygons == b.auxiliaryInkPolygons)
 precondition(ownResult.auxiliaryInkRects.count==expected)
 cases+=1
} } }
print("PASS \(cases) clipped ownership positive/negative/order/scale contracts")

    func foreignAuxiliarySliversYieldOnlyToActualBodyPolygons() {
        func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> [CGPoint] {
            [CGPoint(x: x, y: y), CGPoint(x: x + width, y: y),
             CGPoint(x: x + width, y: y + height), CGPoint(x: x, y: y + height)]
        }
        func body(_ polygon: [CGPoint], _ evidence: [[CGPoint]], text: String = "春の庭") -> PaddleOCRLine {
            .init(poly: polygon.map { .init(x: $0.x, y: $0.y) }, text: text, score: 0.95,
                  orientationRaw: "vertical", singleVerticalColumn: true,
                  auxiliaryInkRects: evidence.map { points in
                      CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                             width: points.map(\.x).max()! - points.map(\.x).min()!,
                             height: points.map(\.y).max()! - points.map(\.y).min()!)
                  }, auxiliaryInkPolygons: evidence)
        }
        // 0374 native 19/20: two actual bodies, with a foreign stroke alias in
        // each padded detector box. Grouping must retain both whole bodies.
        let leftBody = rect(1962.65, 730.46, 43.13, 224.36)
        let rightBody = rect(2024.65, 730.46, 45.84, 344.36)
        let leftAlias = rect(2027.35, 746.12, 2.7, 20.87)
        let rightAlias = rect(1997.70, 733.07, 8.08, 33.92)
        let left = body(rect(1937, 706, 92, 271), [leftBody, leftAlias])
        let right = body(rect(1984, 201, 115, 897), [rightBody, rightAlias])
        for input in [[left, right], [right, left]] {
            let result = NativeOCRAuxiliaryOwnership.deduplicating(input)
            precondition(result.map { $0.auxiliaryInkPolygons.count } == [1, 1])
            precondition(result.map(\.poly) == input.map(\.poly))
            precondition(result.map(\.text) == input.map(\.text))
            precondition(result.allSatisfy { $0.auxiliaryInkRects.count == 1 })
        }
        // No independently rooted own body: small punctuation/ruby/censor
        // evidence must never lose ownership merely because a neighbour covers it.
        let noBody = body(rect(1937, 706, 92, 271), [leftAlias])
        precondition(NativeOCRAuxiliaryOwnership.deduplicating([noBody, right])[0] == noBody)
        let noForeignBody = body(rect(1984, 201, 115, 897), [rightAlias])
        precondition(NativeOCRAuxiliaryOwnership.deduplicating([left, noForeignBody])[0] == left)
        let censor = body(rect(1937, 706, 92, 271), [leftBody, leftAlias], text: "■■")
        precondition(NativeOCRAuxiliaryOwnership.deduplicating([censor, right])[0] == censor)
        let ownAlias = rect(1970, 746, 3, 21)
        let rooted = body(rect(1937, 706, 92, 271), [leftBody, ownAlias])
        precondition(NativeOCRAuxiliaryOwnership.deduplicating([rooted, right])[0] == rooted)
        let partial = body(rect(1937, 706, 92, 271), [leftBody, rect(2023.65, 746, 4, 21)])
        precondition(NativeOCRAuxiliaryOwnership.deduplicating([partial, right])[0] == partial)
        let externalRuby = body(rect(1937, 706, 92, 271), [leftBody, rect(2035, 700, 3, 21)])
        precondition(NativeOCRAuxiliaryOwnership.deduplicating([externalRuby, right])[0] == externalRuby)
        // The diamond's broad bbox covers this sliver, but its filled polygon
        // does not. Polygon containment must reject that apparent ownership.
        let diamond = [CGPoint(x: 2025, y: 730), CGPoint(x: 2070, y: 902),
                       CGPoint(x: 2025, y: 1074), CGPoint(x: 1980, y: 902)]
        let diagonal = body(rect(1980, 730, 100, 344), [diamond])
        let corner = body(rect(1937, 706, 92, 271), [leftBody, rect(2027, 746, 3, 21)])
        precondition(NativeOCRAuxiliaryOwnership.deduplicating([corner, diagonal])[0] == corner)
    }

foreignAuxiliarySliversYieldOnlyToActualBodyPolygons()
print("PASS existing foreign-sliver contracts unchanged")
'''

def main():
    with tempfile.TemporaryDirectory(prefix="aidoku-clipped-ownership-") as directory:
        workspace = Path(directory)
        source = workspace / "main.swift"
        source.write_text(HARNESS)
        binary = workspace / "check"
        ocr = ROOT / "Aidoku/Core/Translation/NativeEngine/OCR"
        sources = [ocr / f"{name}.swift" for name in (
            "BrowserOCRSourceOrientation", "PaddleOCRTypes", "NativeOCRSpatialIndex", "NativeOCRAuxiliaryOwnership", "NativeOCRDetectorSeedEvidence", "NativeOCRSourceROIProbabilityEvidence")]
        subprocess.run(["xcrun", "swiftc", "-O", *map(str, sources), str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)

if __name__ == "__main__":
    main()
