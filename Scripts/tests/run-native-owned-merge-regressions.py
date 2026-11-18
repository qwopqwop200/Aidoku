#!/usr/bin/env python3
"""Run production owned-colour merge regressions in an isolated Swift host binary.

Optional argument: saved corpus directory containing 0552 and 0588. This replays
native OCR with production pixel witnesses and prints current memberships; it
is diagnostic evidence, not an assertion that the known bad cases are fixed.
"""
from pathlib import Path
import sys
import tempfile
r=Path(__file__).resolve().parents[2];p=r/'Scripts/tests/run-ocr-merger-evidence-smoke.py';s=p.read_text();prefix=s[:s.index("harness=r'''")];ns={'__file__':str(p)};exec(prefix,ns);support=ns['support'];b=ns['balloon'];support+='enum PixelWitness {\n'+b[b.index('    static func darkFraction('):b.index('    private static func matching(')]+'}\n'
t=(r/'AidokuTests/Translation/NativeEngine/NativeOCRTextLineMergerTests.swift').read_text();body=t[t.index('    @Test func missingClosingQuote'):t.index('    private func merge(',t.index('    @Test func missingClosingQuote'))].replace('@Test ','').replace('#expect','precondition');helper=t[t.index('    private func line('):t.index('\n}\n\nprivate final')].replace('private func','func')
main=support+body+helper+'\nmissingClosingQuoteKeepsDifferentlyColouredResponseSeparate()\nprint("PASS 0519 scales 0.5,1,2; forward/reverse; exact owned polygons; 5 negative variants")\n'
main+=r'''
if CommandLine.arguments.count > 1 {
let root=URL(fileURLWithPath:CommandLine.arguments[1])
for page in ["0552","0588"] {
 let dir=root.appendingPathComponent(page)
 let files=try FileManager.default.contentsOfDirectory(at:dir,includingPropertiesForKeys:nil)
 let file=files.filter{$0.lastPathComponent.hasSuffix("-native-ocr.json")}.sorted{$0.lastPathComponent<$1.lastPathComponent}.last!
 let value=(try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as! [String:Any])["value"] as! [String:Any]
 let raw=value["lines"] as! [[String:Any]]
 func points(_ o:Any?) -> [CGPoint] { (o as? [[String:Double]] ?? []).map{CGPoint(x:$0["x"]!,y:$0["y"]!)} }
 let lines=raw.map { d in NativeCoreMLOCRLine(polygon:points(d["polygon"]),text:d["text"] as! String,score:d["score"] as? Double ?? 1,orientation:BrowserOCRSourceOrientation(tolerantRawValue:d["orientation"] as? String),orientationIsEstimated:d["orientationIsEstimated"] as? Bool ?? false,erasurePolygons:(d["erasurePolygons"] as? [Any] ?? []).map{points($0)}) }
 let source=CGImageSourceCreateWithURL(dir.appendingPathComponent("input.png") as CFURL,nil)!, image=CGImageSourceCreateImageAtIndex(source,0,nil)!
 let map=ReaderTranslationEnclosedBackground.ComponentMap(image:image),separator=NativeOCRRegionSeparator(image:image)
 for reverse in [false,true] {
 let result=NativeOCRTextLineMerger.merge(reverse ? Array(lines.reversed()):lines,imageWidth:image.width,imageHeight:image.height,separationCheck:{a,b,o in separator?.separates(a,b,orientation:o)==true || map.separates(a,b)},inkContrast:{a,b in
 guard let x=PixelWitness.textInk(in:image,rect:a),let y=PixelWitness.textInk(in:image,rect:b) else{return false};return max(abs(x.0-y.0),abs(x.1-y.1),abs(x.2-y.2))>=100
 },polarityContrast:{a,b in guard let x=PixelWitness.darkFraction(in:image,rect:a),let y=PixelWitness.darkFraction(in:image,rect:b) else{return false};return max(x,y)>=0.3 && min(x,y)<=0.15})
 print(page,"reverse",reverse,"groups",result.count)
 for group in result { print(group.text.replacingOccurrences(of:"\n",with:" | ")) }
 }
}
}
'''
workspace=tempfile.TemporaryDirectory(prefix='aidoku-owned-merge-');p=Path(workspace.name);(p/'main.swift').write_text(main)
sources=[r/'Aidoku/Core/Translation/NativeEngine/OCR'/(n+'.swift') for n in ['BrowserOCRSourceOrientation','PaddleOCRTypes','NativeOCRSpatialIndex','NativeOCRAuxiliaryOwnership','NativeOCRTextLineMerger','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRSlantedDependentColumns','NativeOCRRegionSeparator']]
import subprocess
subprocess.run(['xcrun','swiftc','-O',*map(str,sources),str(p/'main.swift'),'-o',str(p/'replay')],check=True)
subprocess.run([str(p/'replay'),*sys.argv[1:2]],check=True)
