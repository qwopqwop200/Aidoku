#!/usr/bin/env python3
"""Measured detector evidence forwarding through real native line/paragraph merging."""
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
func owner(_ id: String, _ x: Int) -> NativeOCRDetectorSeedEvidence {
 .init(ownerID:id,parentBoxIndex:x,provenance:"db-4connected-original-cells-v1",threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:400,mapFullHeight:500,sourceWidth:400,sourceHeight:500,components:[.init(seed:20*400+x,pixelCount:2,meanProbability:0.95,runs:[.init(y:20,x:x,count:2)])])
}
func line(_ text: String, _ x: CGFloat, _ evidence:[NativeOCRDetectorSeedEvidence]?) -> NativeCoreMLOCRLine {
 let p=[CGPoint(x:x,y:20),CGPoint(x:x+20,y:20),CGPoint(x:x+20,y:140),CGPoint(x:x,y:140)]
 return .init(polygon:p,text:text,score:0.99,orientation:.vertical,detectorSeedEvidence:evidence)
}
let a=owner("a",100),b=owner("b",124)
for reverse in [false,true] {
 let rows=[line("図書館へ行こう",100,[a]),line("今日は晴天です",124,[b])]
 let output=NativeOCRTextLineMerger.merge(reverse ? rows.reversed():rows,imageWidth:400,imageHeight:500)
 precondition(output.count==1 && output[0].detectorSeedEvidence == [a,b])
 let missing=[rows[0],line("今日は晴天です",124,nil)]
 let absent=NativeOCRTextLineMerger.merge(reverse ? missing.reversed():missing,imageWidth:400,imageHeight:500)
 precondition(absent.count==1 && absent[0].detectorSeedEvidence == nil)
 let split=NativeOCRTextLineMerger.merge(rows,imageWidth:400,imageHeight:500,separationCheck:{_,_,_ in true})
 precondition(Set(split.compactMap{$0.detectorSeedEvidence?.first?.ownerID}) == Set(["a","b"]))
}
print("PASS 6 actual merger owner propagation contracts")
'''

with tempfile.TemporaryDirectory(prefix='aidoku-neutral-topology-') as directory:
 p=Path(directory);(p/'main.swift').write_text(support+harness)
 sources=[OCR/(n+'.swift') for n in ['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRAuxiliaryOwnership','NativeOCRDetectorSeedEvidence','NativeOCRTextLineMerger','NativeOCRSourceROIProbabilityEvidence','NativeOCRSlantedDependentColumns','NativeOCRRegionSeparator']]
 override=os.environ.get('AIDOKU_TEST_MERGER_SOURCE')
 if override:
  sources=[Path(override) if source.name=='NativeOCRTextLineMerger.swift' else source for source in sources]
 extra=os.environ.get('AIDOKU_TEST_SEED_UNION_SOURCE')
 if extra: sources.append(Path(extra))
 subprocess.run(['xcrun','swiftc','-O',*[str(s) for s in sources],str(p/'main.swift'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
