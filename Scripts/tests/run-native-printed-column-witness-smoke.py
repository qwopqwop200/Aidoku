#!/usr/bin/env python3
"""Owned glyph pitch regression for padded vertical detector columns."""
from pathlib import Path
import os,subprocess,tempfile,sys
ROOT=Path(__file__).resolve().parents[2]
OCR=ROOT/'Aidoku/Core/Translation/NativeEngine/OCR'
def span(text,start,end):return text[text.index(start):text.index(end,text.index(start))]
pipeline=(OCR/'NativeCoreMLOCRPipeline.swift').read_text()
balloon=(ROOT/'Aidoku/Core/Translation/ReaderTranslationBalloonMerger.swift').read_text()
support='import Foundation\nimport CoreGraphics\nimport ImageIO\n'+span(pipeline,'struct NativeCoreMLOCRLine:','@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics')
support+='enum NativeOCRScopeGeometry {\n'+span(pipeline,'    static func canonicalQuad(','    static func isLatinWord(')+'}\n'
support+='enum ReaderTranslationBalloonMerger {\n'+span(balloon,'    static func separatesVerticalUtterances(','    // Coloured CG captions')+'}\n'
enclosed=(ROOT/'Aidoku/Core/Translation/ReaderTranslationEnclosedBackground.swift').read_text()
support+=enclosed.replace(span(enclosed,'    static func attachingBalloonInteriors(','    private struct Component {'),'')
harness=r'''
func quad(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> [CGPoint] {
 [CGPoint(x:x,y:y),CGPoint(x:x+w,y:y),CGPoint(x:x+w,y:y+h),CGPoint(x:x,y:y+h)]
}
func row(_ text: String, _ polygon: [CGPoint], _ owned: [[CGPoint]], _ scale: CGFloat) -> NativeCoreMLOCRLine {
 let transform: (CGPoint) -> CGPoint = { CGPoint(x:$0.x*scale,y:$0.y*scale) }
 return .init(polygon:polygon.map(transform),text:text,score:0.99,orientation:.vertical,
 erasurePolygons:owned.map{$0.map(transform)})
}
let leftText="庭で遊びます",middleText="花の香りが心地いいね",rightText="朝の庭を散歩しようね"
var cases=0
for scale:CGFloat in [0.5,1,2] {
 let leftPolygon=[CGPoint(x:1999,y:161),CGPoint(x:2088,y:158),CGPoint(x:2100,y:494),CGPoint(x:2011,y:497)]
 let leftBody=quad(2024.662,184.989,43.919,289.453)
 let satellites=[quad(2000.507,187.165,10.979,45.703),quad(2097.128,443.973,2.196,50.056)]
 let left=row(leftText,leftPolygon,[leftBody]+satellites,scale)
 let middle=row(middleText,[CGPoint(x:2072,y:165),CGPoint(x:2141,y:165),CGPoint(x:2144,y:686),CGPoint(x:2075,y:686)],
 [quad(2092.736,184.989,32.939,485.324)],scale)
 let right=row(rightText,quad(2136,148,69,492),[quad(2156.419,167.578,30.743,457.031)],scale)
 let contrast:(CGRect,CGRect)->Bool = {a,b in max(a.width,b.width)>90*scale && min(a.width,b.width)>65*scale}
 func merged(_ rows:[NativeCoreMLOCRLine], _ callback: ((CGRect,CGRect)->Bool)? = nil,
             separator:Bool=false) -> [PaddleOCRLine] {
  NativeOCRTextLineMerger.merge(rows,imageWidth:Int(2600*scale),imageHeight:Int(1950*scale),
   separationCheck:separator ? {_,_,_ in true}:nil,inkContrast:callback ?? contrast)
 }
 for rows in [[left,middle,right],[right,middle,left],[middle,right,left],[left,right,middle],[right,left,middle],[middle,left,right]] {
  let result=merged(rows)
  precondition(result.count==1 && result[0].text==rightText+middleText+leftText,"three owned equal-pitch columns must survive padded width contrast")
  precondition(result[0].auxiliaryInkPolygons.count==5,"all original owned and satellite components must remain")
  precondition(merged(rows,{_,_ in true}).count>1,"real colour contrast must not be bypassed")
  precondition(merged(rows,separator:true).count==3,"image separation stays authoritative")
  cases+=3
 }
 let acrossBoundary=NativeOCRTextLineMerger.merge([left,middle,right],imageWidth:Int(2600*scale),imageHeight:Int(1950*scale),
   separationCheck:{a,b,_ in max(a.midX,b.midX)>2140*scale},inkContrast:contrast)
 precondition(!acrossBoundary.contains{$0.text.contains(leftText) && $0.text.contains(middleText)},"a witness across a real boundary cannot certify the pair")
 cases+=1
 let quotedRight=row("「朝の庭が綺麗だ」",quad(2136,148,69,492),[quad(2156.419,167.578,30.743,457.031)],scale)
 precondition(merged([left,middle,quotedRight]).count>1,"complete independent quotation cannot be a paragraph witness")
 cases+=1
 precondition(merged([left,middle]).count==2,"two columns cannot supply an independent pitch witness");cases+=1
 let noOwnership=row(leftText,leftPolygon,[],scale)
 precondition(merged([noOwnership,middle,right]).count>1,"missing owned body must abstain");cases+=1
 let competingBody=row(leftText,leftPolygon,[leftBody,quad(2000,185,20,200)],scale)
 precondition(merged([competingBody,middle,right]).count>1,"large secondary component cannot be called detector noise");cases+=1
 let narrowBody=row(leftText,leftPolygon,[quad(2024.662,184.989,51,289.453)]+satellites,scale)
 precondition(merged([narrowBody,middle,right]).count>1,"oversized observed body cannot borrow paragraph geometry");cases+=1
 // A detector tilt cannot shrink a wider, upright owned body into matching type.
 let falseTilt=row("春の庭に花咲く",[CGPoint(x:100,y:0),CGPoint(x:132,y:0),CGPoint(x:140,y:200),CGPoint(x:108,y:200)],
   [quad(108,20,24,168)],scale)
 let neighbor=row("風が穏やかです",quad(135,0,28,200),[quad(140,20,18,168)],scale)
 let witness=row("明日も庭を歩く",quad(164,0,28,200),[quad(169,20,18,168)],scale)
 let tiltContrast:(CGRect,CGRect)->Bool={ a,b in max(a.width,b.width)>35*scale && min(a.width,b.width)>25*scale }
 precondition(merged([falseTilt,neighbor,witness],tiltContrast).count>1,"detector-only drift is not observed glyph width")
 cases+=1
 let shiftedRight=row(rightText,quad(2160,148,69,492),[quad(2180.419,167.578,30.743,457.031)],scale)
 precondition(merged([left,middle,shiftedRight]).count>1,"distant third column cannot certify local type");cases+=1
}
print("PASS: \(cases) owned printed-column witness cases; scale/order, ownership, foreign colour, boundary and unequal type controls")
'''

with tempfile.TemporaryDirectory(prefix='aidoku-printed-column-') as directory:
 p=Path(directory);(p/'main.swift').write_text(support+harness)
 sources=[OCR/(n+'.swift') for n in ['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRAuxiliaryOwnership','NativeOCRTextLineMerger','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRSlantedDependentColumns','NativeOCRRegionSeparator']]
 override=os.environ.get('AIDOKU_TEST_MERGER_SOURCE')
 if override:
  sources=[Path(override) if source.name=='NativeOCRTextLineMerger.swift' else source for source in sources]
 subprocess.run(['xcrun','swiftc','-O',*[str(s) for s in sources],str(p/'main.swift'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
