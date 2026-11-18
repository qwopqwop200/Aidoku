#!/usr/bin/env python3
"""Direction-aware ink sampling negatives plus optional actual 0028/0062 pixels.
Usage: run-vertical-ink-merger-smoke.py [cycle57_RUN_DIRECTORY]
Uses current production Swift in an isolated optimized host executable.
"""
from pathlib import Path
import subprocess,tempfile,sys,time
ROOT=Path(__file__).resolve().parents[2]
OCR=ROOT/'Aidoku/Core/Translation/NativeEngine/OCR'
def span(text,start,end):return text[text.index(start):text.index(end,text.index(start))]
pipeline=(OCR/'NativeCoreMLOCRPipeline.swift').read_text()
balloon=(ROOT/'Aidoku/Core/Translation/ReaderTranslationBalloonMerger.swift').read_text()
support='import Foundation\nimport CoreGraphics\nimport ImageIO\n'+span(pipeline,'struct NativeCoreMLOCRLine:','@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics')
support+='enum NativeOCRScopeGeometry {\n'+span(pipeline,'    static func canonicalQuad(','    static func isLatinWord(')+'}\n'
support+='enum ReaderTranslationBalloonMerger {\n'+span(balloon,'    static func separatesVerticalUtterances(','    // Coloured CG captions')+balloon[balloon.index('    static func darkFraction('):balloon.rfind('}')]+'}\n'
enclosed=(ROOT/'Aidoku/Core/Translation/ReaderTranslationEnclosedBackground.swift').read_text()
support+=enclosed.replace(span(enclosed,'    static func attachingBalloonInteriors(','    private struct Component {'),'')
harness=r'''

func fixture(_ color:CGColor, vertical:Bool, length:Int)->CGImage {
 let w=vertical ? 32:length,h=vertical ? length:32
 let c=CGContext(data:nil,width:w,height:h,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
 c.setFillColor(CGColor(gray:1,alpha:1));c.fill(CGRect(x:0,y:0,width:w,height:h));c.setFillColor(color)
 for p in stride(from:8,to:length-8,by:16) {
  c.fill(vertical ? CGRect(x:12,y:p,width:3,height:10):CGRect(x:p,y:12,width:10,height:3))
 }
 return c.makeImage()!
}
func sample(_ color:CGColor,vertical:Bool,length:Int)->(Double,Double,Double) {
 let im=fixture(color,vertical:vertical,length:length)
 return ReaderTranslationBalloonMerger.textInk(in:im,rect:CGRect(x:0,y:0,width:im.width,height:im.height))!
}
func contrast(_ a:(Double,Double,Double),_ b:(Double,Double,Double))->Bool {
 max(abs(a.0-b.0),abs(a.1-b.1),abs(a.2-b.2))>=100
}
for vertical in [false,true] {
 let black=CGColor(gray:0,alpha:1),blue=CGColor(red:0,green:0,blue:1,alpha:1),red=CGColor(red:1,green:0,blue:0,alpha:1)
 precondition(!contrast(sample(black,vertical:vertical,length:123),sample(black,vertical:vertical,length:304)))
 precondition(contrast(sample(blue,vertical:vertical,length:304),sample(red,vertical:vertical,length:123)),"Independent ink colours must still veto")
}
print("PASS: horizontal/vertical same-black lengths and independent red/blue ink boundaries")
if CommandLine.arguments.count > 1 {
let replayBase=CommandLine.arguments[1]
for page in ["0001", "0002"] {
 let dir=URL(fileURLWithPath:replayBase).appendingPathComponent(page)
 let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
 let file=files.first{$0.lastPathComponent.hasSuffix("-native-ocr.json")}!
 let obj=try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any]
 let value=obj["value"] as! [String:Any]
 let raw=value["lines"] as! [[String:Any]]
 func points(_ raw:Any?) -> [CGPoint] { (raw as? [[String:Double]] ?? []).map{CGPoint(x:$0["x"]!,y:$0["y"]!)} }
 let rows=try raw.map { r -> NativeCoreMLOCRLine in
  let evidence: [NativeOCRDetectorSeedEvidence]? = try r["detectorSeedEvidence"].map { value in
 return try JSONDecoder().decode([NativeOCRDetectorSeedEvidence].self,from:JSONSerialization.data(withJSONObject:value)) }
  return .init(polygon:points(r["polygon"]),text:r["text"] as! String,score:0.98,
   orientation:BrowserOCRSourceOrientation(tolerantRawValue:r["orientation"] as? String),orientationIsEstimated:r["orientationIsEstimated"] as? Bool ?? false,
   erasurePolygons:(r["erasurePolygons"] as? [Any] ?? []).map(points),detectorSeedEvidence:evidence)
 }
 let src=CGImageSourceCreateWithURL(dir.appendingPathComponent("input.png") as CFURL,nil)!
 let im=CGImageSourceCreateImageAtIndex(src,0,nil)!, enc=ReaderTranslationEnclosedBackground.ComponentMap(image:CGImageSourceCreateImageAtIndex(src,0,nil)!)
 let sep=NativeOCRRegionSeparator(image:im)
 func mergeMode(_ mode:Int)->[PaddleOCRLine] {
 NativeOCRTextLineMerger.merge(rows,imageWidth:im.width,imageHeight:im.height,separationCheck: mode==1 || mode==3 ? {a,b,o in
 let x=ReaderTranslationBalloonMerger.outlinedInk(in:im,rect:a), y=ReaderTranslationBalloonMerger.outlinedInk(in:im,rect:b)
 var outlined=false
 if o == .vertical, let x,let y {
  outlined=max(abs(x.0-y.0),abs(x.1-y.1),abs(x.2-y.2))>=70 || max(a.minX,b.minX)-min(a.maxX,b.maxX)>=min(a.width,b.width)*0.3
 }
 let v=outlined || sep?.separates(a,b,orientation:o)==true || enc.separates(a,b)
 if v { print("sep-veto",page,a,b) };return v
 } : nil,inkContrast: mode==2 || mode==3 ? {a,b in
 guard let x=ReaderTranslationBalloonMerger.textInk(in:im,rect:a),let y=ReaderTranslationBalloonMerger.textInk(in:im,rect:b) else{return false}
 let v=max(abs(x.0-y.0),abs(x.1-y.1),abs(x.2-y.2))>=100
 if v {print("ink-veto",page,a,b,x,y)};return v
 } : nil, polarityContrast: mode==3 ? {a,b in
 guard let x=ReaderTranslationBalloonMerger.darkFraction(in:im,rect:a),let y=ReaderTranslationBalloonMerger.darkFraction(in:im,rect:b) else{return false}
 return max(x,y)>=0.3 && min(x,y)<=0.15
 } : nil)
 }
 let expected=page == "0001" ? "どんなに透明で綺麗な水もほんの一滴不純な何かが混ざるだけで全てが台無しになってしまう" : "逃げるときも…手…ひっぱってね…"
 for m in 0...3 {
  let merged=mergeMode(m)
  precondition(merged.filter{$0.text.replacingOccurrences(of:"\n",with:"")==expected}.count==1,"Actual pixel callbacks must retain the complete sentence")
  print("PASS actual",page,"callback mode",m,merged.map(\.text))
 }
}
}
'''
with tempfile.TemporaryDirectory(prefix='aidoku-merge-evidence-') as d:
 p=Path(d);(p/'main.swift').write_text(support+harness)
 sources=[OCR/(n+'.swift') for n in ['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRAuxiliaryOwnership','NativeOCRTextLineMerger','NativeOCRSlantedDependentColumns','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRRegionSeparator']]
 started=time.monotonic()
 subprocess.run(['xcrun','swiftc','-O',*[str(s) for s in sources],str(p/'main.swift'),'-o',str(p/'replay')],check=True)
 print(f"Host compile seconds: {time.monotonic()-started:.3f}",flush=True)
 started=time.monotonic()
 subprocess.run([str(p/'replay'),*sys.argv[1:2]],check=True)
 print(f"Host execution seconds: {time.monotonic()-started:.3f}")
