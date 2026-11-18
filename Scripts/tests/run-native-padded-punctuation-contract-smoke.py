#!/usr/bin/env python3
"""Independent synthetic punctuation-extension contract for padded vertical columns."""
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
    static func auditPaddedPunctuation(_ raw:[NativeCoreMLOCRLine], order:[Int], contrast:Bool, boundary:Bool)->Bool {
        let rows=order.map { i in let r=raw[i];return Line(index:i,text:r.text,confidence:r.score,box:boundingBox(r.polygon),polygon:r.polygon,erasurePolygons:r.erasurePolygons,orientationHint:.vertical,orientation:.vertical,singleVerticalColumn:true) }
        let third=rows.first{$0.index==2}!.box
        let firstIndex = order.firstIndex(of:0)! < order.firstIndex(of:1)! ? 0 : 1
        return witnessedPaddedVerticalColumns(rows.first{$0.index==firstIndex}!,rows.first{$0.index==1-firstIndex}!,lines:rows,spatialIndex:NativeOCRSpatialIndex(boxes:rows.map(\.box))CALLBACK_ARGUMENTS)
    }
'''
harness=r'''
func quad(_ x:CGFloat,_ y:CGFloat,_ w:CGFloat,_ h:CGFloat)->[CGPoint] {[CGPoint(x:x,y:y),CGPoint(x:x+w,y:y),CGPoint(x:x+w,y:y+h),CGPoint(x:x,y:y+h)]}
func fixture(_ scale:CGFloat,texts:[String],owned:Bool=true,mismatch:Bool=false,far:Bool=false,quotedThird:Bool=false)->[NativeCoreMLOCRLine] {
 let centers:[CGFloat]=[120,140,far ? 220:164]
 return (0..<3).map { i in
  let width:CGFloat=i==2 ? 20:40, center=centers[i]
  let height:CGFloat=(quotedThird && i==2) ? 180:140
  let text=(quotedThird && i==2) ? "「明日は仕事です」":texts[i]
  func scaled(_ q:[CGPoint])->[CGPoint]{q.map{CGPoint(x:$0.x*scale,y:$0.y*scale)}}
  return .init(polygon:scaled(quad(center-width/2,20,width,height)),text:text,score:0.99,orientation:.vertical,erasurePolygons:owned ? [scaled(quad(center-7,20,14,(mismatch && i==0) ? 70:height))]:[])
 }
}
let ordinary=["今日は良い天気","なので散歩する","明日は仕事です"]
let fullwidth=["今日は晴れ！！","散歩する！？！","明日は仕事です"]
let halfwidth=["今日は?!?:","散歩する！？！","明日は仕事です"]
let onlyMarks=["！？…：！？…","！？…：！？…","！？…：！？…"]
let ideographicMarks=["「」『』！？…","〈〉《》！？…","明日は仕事です"]
let ocrSymbols=["今日は@#$%","散歩する！？！","明日は仕事です"]
let orders=[[0,1,2],[0,2,1],[1,0,2],[1,2,0],[2,0,1],[2,1,0]]
let requireOwnedCoverage = REQUIRE_OWNED_COVERAGE
var cases=0;var failures:[String]=[]
for scale:CGFloat in [0.5,1,2,4] {for order in orders {
 func check(_ name:String,_ rows:[NativeCoreMLOCRLine],_ expected:Bool,contrast:Bool=false,boundary:Bool=false) {
  let actual=NativeOCRTextLineMerger.auditPaddedPunctuation(rows,order:order,contrast:contrast,boundary:boundary)
  cases+=1
  if actual != expected { failures.append("\(name) scale=\(scale) order=\(order): expected \(expected), got \(actual)") }
 }
 check("legacy-CJK-positive",fixture(scale,texts:ordinary),true)
 check("owned-fullwidth-positive",fixture(scale,texts:fullwidth),true)
 check("punctuation-only",fixture(scale,texts:onlyMarks),false)
 check("CJK-punctuation-is-not-letters",fixture(scale,texts:ideographicMarks),false)
 check("OCR-symbols",fixture(scale,texts:ocrSymbols),false)
 check("halfwidth-no-cell-proof",fixture(scale,texts:halfwidth),false)
 let legacyMissing=BaselineNativeOCRTextLineMerger.auditPaddedPunctuation(fixture(scale,texts:ordinary,owned:false),order:order,contrast:false,boundary:false)
 check("missing-owned-proof",fixture(scale,texts:fullwidth,owned:false),requireOwnedCoverage ? false : legacyMissing)
 let legacyMismatch=BaselineNativeOCRTextLineMerger.auditPaddedPunctuation(fixture(scale,texts:ordinary,mismatch:true),order:order,contrast:false,boundary:false)
 check("insufficient-owned-height-coverage",fixture(scale,texts:fullwidth,mismatch:true),requireOwnedCoverage ? false : legacyMismatch)
 check("distant-third-paragraph",fixture(scale,texts:fullwidth,far:true),false)
 check("third-observed-ink-boundary",fixture(scale,texts:fullwidth),false,contrast:true)
 check("third-closed-independent-quotation",fixture(scale,texts:fullwidth,quotedThird:true),false)
 check("third-real-boundary",fixture(scale,texts:fullwidth),false,boundary:true)
}}
if !failures.isEmpty {FileHandle.standardError.write(Data((failures.joined(separator:"\n")+"\n").utf8));exit(1)}
print("PASS: \(cases) independent punctuation-extension helper cases; no image-quality claim")
'''

harness=harness.replace('REQUIRE_OWNED_COVERAGE','false' if '--legacy-coverage-parity' in sys.argv else 'true')
source=Path(os.environ.get('AIDOKU_TEST_MERGER_SOURCE',str(OCR/'NativeOCRTextLineMerger.swift')))
text=source.read_text().replace('enum CandidateNativeOCRTextLineMerger {','enum NativeOCRTextLineMerger {')
marker='    private static func witnessedPaddedVerticalColumns('
def callback_arguments(source_text):
 start=source_text.index(marker);end=source_text.index('    ) -> Bool {',start)
 signature=source_text[start:end]
 callbacks={'inkContrast:':', inkContrast: { _, _ in contrast }','separationCheck:':', separationCheck: { a,b,_ in boundary && (a == third || b == third) }'}
 return ''.join(callbacks[key] for key in sorted((key for key in callbacks if key in signature),key=signature.index))
arguments=callback_arguments(text)
baseline=(OCR/'NativeOCRTextLineMerger.swift').read_text().replace('enum NativeOCRTextLineMerger {','enum BaselineNativeOCRTextLineMerger {')
baseline=baseline.replace(marker,wrapper.replace('CALLBACK_ARGUMENTS',callback_arguments(baseline))+'\n'+marker,1)
wrapper=wrapper.replace('CALLBACK_ARGUMENTS',arguments)
with tempfile.TemporaryDirectory(prefix='aidoku-punctuation-contract-') as directory:
 p=Path(directory);(p/'main.swift').write_text(support+harness)
 (p/'Baseline.swift').write_text(baseline)
 (p/'Merger.swift').write_text(text.replace(marker,wrapper+'\n'+marker,1))
 sources=[OCR/(n+'.swift') for n in ['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRAuxiliaryOwnership','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRSlantedDependentColumns','NativeOCRRegionSeparator']]
 subprocess.run(['xcrun','swiftc','-O',*[str(s) for s in sources],str(p/'Baseline.swift'),str(p/'Merger.swift'),str(p/'main.swift'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
