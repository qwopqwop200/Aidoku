#!/usr/bin/env python3
"""Centered small kana attachment contract; optional AIDOKU_TEST_MERGER_SOURCE candidate."""
from pathlib import Path
import os, subprocess, tempfile
r=Path(__file__).resolve().parents[2]
p=r/'Scripts/tests/run-ocr-merger-evidence-smoke.py'
s=p.read_text(); ns={'__file__':str(p)}
exec(s[:s.index("harness=r'''")],ns)
main=ns['support']+r'''
    func line(
        _ text: String,
        _ x: CGFloat,
        _ y: CGFloat,
        _ width: CGFloat,
        _ height: CGFloat,
        score: Double = 0.9,
        orientation: BrowserOCRSourceOrientation = .unknown,
        orientationIsEstimated: Bool = false,
        sourceTileBounds: CGRect? = nil
    ) -> NativeCoreMLOCRLine {
        NativeCoreMLOCRLine(
            polygon: [
                CGPoint(x: x, y: y),
                CGPoint(x: x + width, y: y),
                CGPoint(x: x + width, y: y + height),
                CGPoint(x: x, y: y + height),
            ],
            text: text,
            score: score,
            orientation: orientation,
            orientationIsEstimated: orientationIsEstimated,
            sourceTileBounds: sourceTileBounds
        )
    }
var checked=0
for scale:CGFloat in [0.5,1,2,3] {
 for reverse in [false,true] {
  for variant in ["positive","missingOwned","nonParticle","rubyAbove","wideGap","tooSmall","latinParent","narrowParent","realBoundary","oppositePolarity"] {
   func row(_ t:String,_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat)->NativeCoreMLOCRLine { line(t,x*scale,y*scale,w*scale,h*scale,orientation:.horizontal) }
   let parent=row(variant == "latinParent" ? "AB":"青空",112,143,variant == "narrowParent" ? 150:417,229)
   var child=row(variant == "nonParticle" ? "星":"の", variant == "wideGap" ? 600:525, variant == "rubyAbove" ? 30:190,128,variant == "tooSmall" ? 100:137)
   if variant != "missingOwned" { let x=child.polygon[0].x, y=child.polygon[0].y; child=NativeCoreMLOCRLine(polygon:child.polygon,text:child.text,score:0.9,orientation:.horizontal,erasurePolygons:[[CGPoint(x:x+27*scale,y:y+27*scale),CGPoint(x:x+102*scale,y:y+27*scale),CGPoint(x:x+102*scale,y:y+111*scale),CGPoint(x:x+27*scale,y:y+111*scale)]]) }
   let rows=reverse ? [child,parent]:[parent,child]
   let result=NativeOCRTextLineMerger.merge(rows,imageWidth:Int(1000*scale),imageHeight:Int(1432*scale),separationCheck:variant == "realBoundary" ? {_,_,_ in true}:nil,polarityContrast:variant == "oppositePolarity" ? {_,_ in true}:nil)
   let expected=variant == "positive" ? 1:2
   if result.count != expected { print("FAIL",variant,scale,reverse,result.map{$0.text}) }
   precondition(result.count == expected)
   checked += 1
  }
 }
}
print("PASS title kana",checked,"scale/order/negative controls")

for order in [[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]] {
 let parent=line("青空",112,143,417,229,orientation:.horizontal)
 let particle=NativeCoreMLOCRLine(polygon:line("の",525,190,128,137,orientation:.horizontal).polygon,text:"の",score:0.9,orientation:.horizontal,erasurePolygons:[[CGPoint(x:552,y:217),CGPoint(x:627,y:217),CGPoint(x:627,y:301),CGPoint(x:552,y:301)]])
 let bottom=line("物語",109,329,414,223,orientation:.horizontal)
 let rows=[parent,particle,bottom]
 let result=NativeOCRTextLineMerger.merge(order.map{rows[$0]},imageWidth:1000,imageHeight:1432)
 precondition(result.count == 1 && result[0].text == "青空の物語")
 precondition(result[0].auxiliaryInkPolygons == particle.erasurePolygons)
}
print("PASS two-row title, six permutations, exact particle ownership")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-kana-attachment-') as tmp:
 p=Path(tmp); (p/'main.swift').write_text(main)
 o=r/'Aidoku/Core/Translation/NativeEngine/OCR'
 names=['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRAuxiliaryOwnership','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRSlantedDependentColumns','NativeOCRRegionSeparator']
 source=Path(os.environ.get('AIDOKU_TEST_MERGER_SOURCE',str(o/'NativeOCRTextLineMerger.swift')))
 subprocess.run(['xcrun','swiftc','-O',*[str(o/(n+'.swift')) for n in names],str(source),str(p/'main.swift'),'-o',str(p/'replay')],check=True)
 subprocess.run([str(p/'replay')],check=True)
