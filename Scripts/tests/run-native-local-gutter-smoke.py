#!/usr/bin/env python3
"""Independent synthetic regression: distant text must not erase local paragraph gutters."""
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
func line(_ text: String, x: CGFloat, y: CGFloat, scale: CGFloat) -> NativeCoreMLOCRLine {
 let box=CGRect(x:x*scale,y:y*scale,width:20*scale,height:140*scale)
 return .init(polygon:[CGPoint(x:box.minX,y:box.minY),CGPoint(x:box.maxX,y:box.minY),CGPoint(x:box.maxX,y:box.maxY),CGPoint(x:box.minX,y:box.maxY)],text:text,score:0.99,orientation:.vertical)
}
func permutations<T>(_ rows: [T]) -> [[T]] {
 if rows.isEmpty { return [[]] }
 return rows.indices.flatMap { i in
  var remainder=rows;let first=remainder.remove(at:i)
  return permutations(remainder).map { [first]+$0 }
 }
}
let a="今日は良い天気",b="なので散歩する",c="明日は仕事です",d="図書館の案内板"
var checked=0
var failures:[String]=[]
for scale:CGFloat in [0.5,1,2,4] {
 for outerGap:CGFloat in [8,9,10,11] {
  let third=142+outerGap
  let base=[line(a,x:100,y:220,scale:scale),line(b,x:122,y:220,scale:scale),line(c,x:third,y:220,scale:scale)]
  let expected:Set<String>=[b+a,c]
  let plain=NativeOCRTextLineMerger.merge(base,imageWidth:Int(600*scale),imageHeight:Int(800*scale))
  precondition(Set(plain.map(\.text))==expected,"fixture must have a witnessed local gutter")
  for remoteY:CGFloat in [20,540] {
   let remote=line(d,x:third-1,y:remoteY,scale:scale)
   for rows in permutations(base+[remote]) {
    let result=NativeOCRTextLineMerger.merge(rows,imageWidth:Int(600*scale),imageHeight:Int(800*scale))
    checked+=1
    if Set(result.map(\.text)) != expected.union([d]) {
     if failures.count < 8 {failures.append("scale=\(scale) gap=\(outerGap) remoteY=\(remoteY): \(result.map(\.text))")}
    }
   }
  }
 }
 // Equal local spacing is one paragraph, even with a distant x-interleaved distractor.
 for gap:CGFloat in [2,8] {
  let base=[line(a,x:100,y:220,scale:scale),line(b,x:120+gap,y:220,scale:scale),line(c,x:140+2*gap,y:220,scale:scale)]
  let remote=line(d,x:139+2*gap,y:540,scale:scale)
  for rows in permutations(base+[remote]) {
   let result=NativeOCRTextLineMerger.merge(rows,imageWidth:Int(600*scale),imageHeight:Int(800*scale))
   precondition(Set(result.map(\.text))==Set([c+b+a,d]),"regular spacing must remain mergeable")
   checked+=1
  }
 }
}
if !failures.isEmpty { fatalError("Remote-row gutter invariance failed: \(failures.joined(separator:"; "))") }
print("PASS: \(checked) synthetic local-gutter cases, permutation/scale/remote-above-below and equal-spacing controls")
'''

with tempfile.TemporaryDirectory(prefix='aidoku-local-gutter-') as directory:
 p=Path(directory);(p/'main.swift').write_text(support+harness)
 sources=[OCR/(n+'.swift') for n in ['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRAuxiliaryOwnership','NativeOCRTextLineMerger','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRSlantedDependentColumns','NativeOCRRegionSeparator']]
 override=os.environ.get('AIDOKU_TEST_MERGER_SOURCE')
 if override:
  sources=[Path(override) if source.name=='NativeOCRTextLineMerger.swift' else source for source in sources]
 subprocess.run(['xcrun','swiftc','-O',*[str(s) for s in sources],str(p/'main.swift'),'-o',str(p/'probe')],check=True)
 subprocess.run([str(p/'probe')],check=True)
