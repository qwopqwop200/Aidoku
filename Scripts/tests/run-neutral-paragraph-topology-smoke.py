#!/usr/bin/env python3
"""Content-independent regression: paragraph topology and explicit boundary ownership."""
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
func line(_ text:String,_ x:CGFloat,_ y:CGFloat,_ scale:CGFloat)->NativeCoreMLOCRLine {
 let b=CGRect(x:x*scale,y:y*scale,width:20*scale,height:120*scale)
 return .init(polygon:[CGPoint(x:b.minX,y:b.minY),CGPoint(x:b.maxX,y:b.minY),CGPoint(x:b.maxX,y:b.maxY),CGPoint(x:b.minX,y:b.maxY)],text:text,score:0.99,orientation:.vertical)
}
var checked=0
for scale:CGFloat in [0.5,1,2] { for reversed in [false,true] {
 let a=line("図書館へ行こう",100,20,scale),b=line("今日は晴天です",124,20,scale)
 let c=line("明日は公園です",100,160,scale),d=line("皆で散歩しよう",124,160,scale)
 for bounded in [false,true] {
  let input=reversed ? [d,c,b,a]:[a,b,c,d]
  let result=NativeOCRTextLineMerger.merge(input,imageWidth:Int(400*scale),imageHeight:Int(500*scale),separationCheck:{x,y,_ in bounded && abs(x.midY-y.midY)>80*scale})
  precondition(Set(result.map(\.text))==Set([b.text+a.text,d.text+c.text]),"independent top-aligned paragraphs")
  checked += 1
 }
 let continuous=reversed ? [b,a]:[a,b]
 let result=NativeOCRTextLineMerger.merge(continuous,imageWidth:Int(400*scale),imageHeight:Int(500*scale),separationCheck:{_,_,_ in false})
 precondition(result.count==1 && result[0].text==b.text+a.text,"ordinary same-paper columns")
 checked += 1
 let separated=NativeOCRTextLineMerger.merge(continuous,imageWidth:Int(400*scale),imageHeight:Int(500*scale),separationCheck:{_,_,_ in true})
 precondition(Set(separated.map(\.text))==Set([a.text,b.text]),"positive owned boundary must veto")
 checked += 1
} }
print("PASS \(checked) neutral paragraph topology scale/order/boundary contracts")
'''

with tempfile.TemporaryDirectory(prefix='aidoku-neutral-topology-') as directory:
 p=Path(directory);(p/'main.swift').write_text(support+harness)
 sources=[OCR/(n+'.swift') for n in ['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRAuxiliaryOwnership','NativeOCRTextLineMerger','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRSlantedDependentColumns','NativeOCRRegionSeparator']]
 override=os.environ.get('AIDOKU_TEST_MERGER_SOURCE')
 if override:
  sources=[Path(override) if source.name=='NativeOCRTextLineMerger.swift' else source for source in sources]
 subprocess.run(['xcrun','swiftc','-O',*[str(s) for s in sources],str(p/'main.swift'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
