#!/usr/bin/env python3
"""Actual pure merger regression; optional saved-corpus image-boundary replay.
Optional args: RUN_DIRECTORY REPORT_JSON BASELINE_SWIFT
"""
from pathlib import Path
import subprocess,tempfile,sys
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
func line(_ text:String,_ x:CGFloat)->NativeCoreMLOCRLine {
 .init(polygon:[CGPoint(x:x,y:20),CGPoint(x:x+100,y:20),CGPoint(x:x+100,y:50),CGPoint(x:x,y:50)],
 text:text,score:0.98,orientation:.horizontal)
}
let a=line("HELLO",20),b=line("WORLD",122)
let admitted=NativeOCRTextLineMerger.merge([a,b],imageWidth:300,imageHeight:100)
precondition(admitted.count==1,"control fragments must be joinable")
for rows in [[a,b],[b,a]] {
 var inspected=0
 let blocked=NativeOCRTextLineMerger.merge(rows,imageWidth:300,imageHeight:100,separationCheck:{_,_,direction in
  precondition(direction == .horizontal);inspected+=1;return true
 })
 precondition(blocked.count==2,"image separator must veto a non-overlapping fragment edge")
 precondition(inspected>0,"separator must actually inspect the join")
}
print("PASS: native horizontal fragments join without boundary; image ownership veto survives both input orders")
'''
corpus=r'''
let run=URL(fileURLWithPath:CommandLine.arguments[1]),output=URL(fileURLWithPath:CommandLine.arguments[2])
let dirs=try FileManager.default.contentsOfDirectory(at:run,includingPropertiesForKeys:nil).sorted{$0.path<$1.path}
var rows:[[String:Any]]=[]
for dir in dirs where Int(dir.lastPathComponent) != nil {
 let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
 guard let file=files.first(where:{$0.lastPathComponent.hasSuffix("-native-ocr.json")}),
  let object=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any],
  let value=object["value"] as? [String:Any],let lines=value["lines"] as? [[String:Any]],
  let source=CGImageSourceCreateWithURL(dir.appendingPathComponent("input.png") as CFURL,nil),
  let image=CGImageSourceCreateImageAtIndex(source,0,nil) else {continue}
 let native=lines.compactMap { line -> NativeCoreMLOCRLine? in
  guard let points=line["polygon"] as? [[String:Double]],let text=line["text"] as? String else{return nil}
  return .init(polygon:points.map{CGPoint(x:$0["x"]!,y:$0["y"]!)},text:text,score:line["score"] as? Double ?? 1,
   orientation:BrowserOCRSourceOrientation(tolerantRawValue:line["orientation"] as? String),
   orientationIsEstimated:line["orientationIsEstimated"] as? Bool ?? false)
 }
 let map=ReaderTranslationEnclosedBackground.ComponentMap(image:image),separator=NativeOCRRegionSeparator(image:image)
 let check:(CGRect,CGRect,BrowserOCRSourceOrientation)->Bool={a,b,o in
  separator?.separates(a,b,orientation:o)==true || map.separates(a,b)
 }
 let before=BaselineNativeOCRTextLineMerger.merge(native,imageWidth:image.width,imageHeight:image.height,separationCheck:check)
 let after=NativeOCRTextLineMerger.merge(native,imageWidth:image.width,imageHeight:image.height,separationCheck:check)
 rows.append(["page":dir.lastPathComponent,"nativeLines":native.count,"beforeGroups":before.count,"afterGroups":after.count,
  "changed":before != after])
}
try JSONSerialization.data(withJSONObject:rows,options:[.prettyPrinted,.sortedKeys]).write(to:output)
print("Corpus merge replay: \(rows.count) pages; \(rows.filter{$0["changed"] as? Bool == true}.count) changed by image separation")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-merge-evidence-') as d:
 p=Path(d);(p/'main.swift').write_text(support+harness+(corpus if len(sys.argv)>1 else ''))
 sources=[OCR/(n+'.swift') for n in ['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRTextLineMerger','NativeOCRRegionSeparator']]
 if len(sys.argv)>1:
  baseline=Path(sys.argv[3]) if len(sys.argv)>3 else ROOT/'build/output-hard-evidence-baseline/NativeOCRTextLineMerger.swift'
  (p/'baseline.swift').write_text(baseline.read_text().replace('enum NativeOCRTextLineMerger {','enum BaselineNativeOCRTextLineMerger {'))
  sources.append(p/'baseline.swift')
 subprocess.run(['xcrun','swiftc','-O',*[str(s) for s in sources],str(p/'main.swift'),'-o',str(p/'replay')],check=True)
 subprocess.run([str(p/'replay'),*sys.argv[1:3]],check=True)
