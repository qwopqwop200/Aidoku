#!/usr/bin/env python3
"""Independent synthetic helper contract: owned type-pitch evidence must reject false shear and foreign witnesses."""
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
wrapper=r'''
    static func auditPrintedPitch(_ raw: [NativeCoreMLOCRLine], reversePair: Bool, contrast: Bool, boundary: Bool) -> Bool {
        let rows=raw.enumerated().map { i, r in Line(index:i,text:r.text,confidence:r.score,box:boundingBox(r.polygon),polygon:r.polygon,erasurePolygons:r.erasurePolygons,orientationHint:.vertical,orientation:.vertical,singleVerticalColumn:true) }
        let third = rows.count > 2 ? rows[2].box : CGRect.null
        return witnessedSamePrintedVerticalTypeSize(rows[reversePair ? 1:0],rows[reversePair ? 0:1],lines:rows,spatialIndex:NativeOCRSpatialIndex(boxes:rows.map(\.box)),inkContrast:{_,_ in contrast},separationCheck:{a,b,_ in boundary && (a == third || b == third)})
    }
'''
harness=r'''
func rect(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat)->[CGPoint] {[CGPoint(x:x,y:y),CGPoint(x:x+w,y:y),CGPoint(x:x+w,y:y+h),CGPoint(x:x,y:y+h)]}
let words=["今日は良い天気","なので散歩する","明日は仕事です"]
func fixture(_ scale:CGFloat, firstWidth:CGFloat=20, missingOwned:Bool=false, satellite:Bool=false, quote:Bool=false, tall:Bool=false)->[NativeCoreMLOCRLine] {
 let firstDetector = firstWidth == 24 ? [CGPoint(x:100,y:0),CGPoint(x:132,y:0),CGPoint(x:140,y:200),CGPoint(x:108,y:200)] : rect(100,0,40,200)
 let detectors:[[CGPoint]]=[firstDetector,rect(135,0,28,200),rect(164,0,28,200)]
 return (0..<3).map { i in
  let center:CGFloat=[120,149,178][i],width=i==0 ? firstWidth:18
  var owned=[rect(center-width/2,20,width,(i==2 && tall) ? 178:168)]
  if missingOwned && i==2 {owned=[]}
  if satellite && i==2 {owned.append(rect(center+40,20,10,80))}
  func scaled(_ p:[CGPoint])->[CGPoint]{p.map{CGPoint(x:$0.x*scale,y:$0.y*scale)}}
  return .init(polygon:scaled(detectors[i]),text:(quote && i==2) ? "「明日は仕事です」":words[i],score:0.99,orientation:.vertical,erasurePolygons:owned.map(scaled))
 }
}
var cases=0
var failures:[String]=[]
for scale:CGFloat in [0.5,1,2,4] {for reversed in [false,true] {
 func check(_ name:String,_ raw:[NativeCoreMLOCRLine],_ expected:Bool,contrast:Bool=false,boundary:Bool=false) {
  let result=NativeOCRTextLineMerger.auditPrintedPitch(raw,reversePair:reversed,contrast:contrast,boundary:boundary)
  if result != expected {failures.append("\(name) scale=\(scale) reverse=\(reversed): expected \(expected), got \(result)")}
  cases+=1
 }
 check("owned-pitch-positive",fixture(scale),true)
 check("detector-only-shear-does-not-shrink-owned-width",fixture(scale,firstWidth:24),false)
 check("third-across-real-boundary",fixture(scale),false,boundary:true)
 check("observed-ink-contrast",fixture(scale),false,contrast:true)
 check("missing-third-ownership",fixture(scale,missingOwned:true),false)
 check("foreign-satellite-dominance",fixture(scale,satellite:true),false)
 check("independently-closed-third-quotation",fixture(scale,quote:true),false)
 check("no-third-witness",Array(fixture(scale).prefix(2)),false)
}
}
if !failures.isEmpty {
 FileHandle.standardError.write(Data((failures.joined(separator:"\n")+"\n").utf8))
 exit(1)
}
print("PASS: \(cases) independent printed-pitch helper cases; this is not an image-quality or full-merger pass")
'''

override=os.environ.get('AIDOKU_TEST_MERGER_SOURCE')
source=Path(override) if override else OCR/'NativeOCRTextLineMerger.swift'
text=source.read_text()
helper='witnessedVerticalGlyphAdvance' if '    private static func witnessedVerticalGlyphAdvance(' in text else 'witnessedSamePrintedVerticalTypeSize'
wrapper=wrapper.replace('witnessedSamePrintedVerticalTypeSize',helper)
marker='    private static func '+helper+'('
if marker not in text:
 raise SystemExit('Candidate helper absent; provide AIDOKU_TEST_MERGER_SOURCE. No test was executed.')
with tempfile.TemporaryDirectory(prefix='aidoku-printed-pitch-contract-') as directory:
 p=Path(directory)
 (p/'main.swift').write_text(support+harness)
 (p/'Merger.swift').write_text(text.replace(marker,wrapper+'\n'+marker,1))
 sources=[OCR/(n+'.swift') for n in ['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRAuxiliaryOwnership','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRSlantedDependentColumns','NativeOCRRegionSeparator']]
 subprocess.run(['xcrun','swiftc','-O',*[str(s) for s in sources],str(p/'Merger.swift'),str(p/'main.swift'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
