#!/usr/bin/env python3
"""Optimized production helper + joinBalloonUnits, neutral requests and owner conservation."""
from pathlib import Path
import subprocess
import sys
import tempfile
import time
if len(sys.argv) != 1:
    raise SystemExit("This runner accepts no asset paths; all fixtures are independently authored nonsexual geometry.")
ROOT=Path(__file__).resolve().parents[2]
T=ROOT/'Aidoku/Core/Translation'
region=(T/'ReaderTranslationService.swift').read_text()
region=region[region.index('struct ReaderTranslationRegion:'):region.index('    /// If translation')]+ '}\n'
a=region.index('    var translationReuseIdentity:');b=region.index('    var auxiliaryInkRects:',a)
region=region[:a]+region[b:]
alt=(T/'NativeEngine/OCR/NativeOCRMixedScriptColumnRecovery.swift').read_text()
region=alt[alt.index('struct ReaderTranslationSourceOCRAlternative:'):]+region
rot=(T/'NativeEngine/Overlay/BrowserOverlayRotation.swift').read_text()
a=rot.index('    static func geometry(');i=rot.index('{',a);depth=1;j=i+1
while depth:
    if rot[j]=='{':depth+=1
    if rot[j]=='}':depth-=1
    j+=1
rot='enum BrowserOverlayRotation { struct Geometry { let radians:CGFloat; let rect:CGRect; let panelRect:CGRect }\n'+rot[a:j]+'\n}'
h=r'''
func check(_ condition: @autoclosure () -> Bool, _ message: String = "assertion", file: String = #file, line: Int = #line) {
 if !condition() {print("FAIL \(message) line=\(line)");exit(1)}
}

func paper(_ connected:Bool=true,_ open:Bool=false)->CGImage {
 let w=640,h=800
 var p=[UInt8](repeating:open ? 255:40,count:w*h)
 for y in 0..<h { for x in 0..<w {
  let a=pow(Double(x-410)/115,2)+pow(Double(y-220)/135,2)<1
  let b=pow(Double(x-330)/115,2)+pow(Double(y-500)/125,2)<1
  let neck=connected && (350...380).contains(x) && (300...410).contains(y)
  if a || b || neck {p[y*w+x]=255}
 }}
 return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,
  space:CGColorSpaceCreateDeviceGray(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:CGDataProvider(data:Data(p) as CFData)!,
  decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}
func rows(_ a:String="どうか図書館の受付係に",_ b:String="きちんと連絡してくださいね！")->[ReaderTranslationRegion] {
 [.init(id:"head",rect:CGRect(x:360.0/640,y:155.0/800,width:100.0/640,height:170.0/800),source:a,sourceOrientation:.vertical,sourceSingleVerticalColumn:false),
 .init(id:"tail",rect:CGRect(x:290.0/640,y:405.0/800,width:105.0/640,height:180.0/800),source:b,sourceOrientation:.vertical,sourceSingleVerticalColumn:false)]
}
func apply(_ input:[ReaderTranslationRegion],_ image:CGImage,_ integration:Bool)->[ReaderTranslationRegion] {
 let map=ReaderTranslationEnclosedBackground.ComponentMap(image:image)
 if integration {return ReaderTranslationBalloonMerger.joinBalloonUnits(input,image:image,enclosure:map,separates:{_,_,_ in false})}
 return ReaderTranslationLobedRequestMerger.apply(input,image:image,enclosure:map)
}
var cases=0
for integration in [false,true] {for reverse in [false,true] {
 let input=reverse ? Array(rows().reversed()):rows()
 let output=apply(input,paper(),integration)
 check(output.count==1,"neutral connected request must join, integration=\(integration)")
 check(output[0].source==rows().map(\.source).joined() && output[0].id==input[0].id)
 check(output[0].unitMemberRects==rows().map(\.rect) && output[0].balloonInterior==nil)
 check(apply(output,paper(),integration)==output,"idempotence")
 cases += 1
 for im in [paper(false),paper(true,true)] {check(apply(input,im,integration)==input,"separate balloon or open page");cases += 1}
 for negative in [rows("せめて係員たちに！"),rows("今日は係員たちに"),rows("せめて係員たちに」"),
  rows("せめて係員たちに","「ちゃんと連絡してください！"),rows("せめて係員たちに","明日は晴れるでしょう！"),
  rows("青い本を見つけた！","次は地図を探そう！")] {
  let input=reverse ? Array(negative.reversed()):negative
  check(apply(input,paper(),integration)==input,"independent utterance survives")
  cases += 1
 }
 let blocker=ReaderTranslationRegion(id:"other",rect:CGRect(x:365.0/640,y:350.0/800,width:10.0/640,height:10.0/800),source:"別",sourceOrientation:.vertical)
 check(apply(input+[blocker],paper(),integration)==input+[blocker]);cases += 1
}}

// Independently designed library-note ownership fixture. No corpus image, text,
// coordinates, detector evidence, or saved diagnostics are loaded by this test.
func ownedRows() -> [ReaderTranslationRegion] {
 var result=rows()
 for i in 0..<7 {
  let member=i<4 ? 0:1, offset=i<4 ? i:i-4
  let base=result[member].rect
  let ink=CGRect(x:base.minX+CGFloat(offset*18+7)/640,y:base.minY+12.0/800,width:8.0/640,height:100.0/800)
  let x=Int((ink.minX*640).rounded()),y=Int((ink.minY*800).rounded())
  let owner=NativeOCRDetectorSeedEvidence(ownerID:"neutral-library-owner-\(i)",parentBoxIndex:i,
   provenance:"db-4connected-original-cells-v1",threshold:0.9,mapOriginX:0,mapOriginY:0,
   mapFullWidth:640,mapFullHeight:800,sourceWidth:640,sourceHeight:800,
   components:[.init(seed:y*640+x,pixelCount:3,meanProbability:0.99,runs:[.init(y:y,x:x,count:3)])])
  check(owner.isValid,"synthetic evidence must satisfy the production contract")
  result[member].detectorSeedEvidence=(result[member].detectorSeedEvidence ?? [])+[owner]
  result[member].auxiliaryInkRects.append(ink)
  result[member].auxiliaryInkPolygons.append([CGPoint(x:ink.minX,y:ink.minY),CGPoint(x:ink.maxX,y:ink.minY),
   CGPoint(x:ink.maxX,y:ink.maxY),CGPoint(x:ink.minX,y:ink.maxY)])
 }
 return result
}
let owned=ownedRows()
for integration in [false,true] {for reverse in [false,true] {
 let input=reverse ? Array(owned.reversed()):owned,output=apply(input,paper(),integration)
 check(output.count==1,"independent neutral ownership fixture must join")
 let joined=output[0],evidence=joined.detectorSeedEvidence ?? []
 check(joined.unitMemberRects==owned.map(\.rect) && joined.unitMemberRects.count==2)
 check(joined.source==owned.map(\.source).joined())
 check(evidence==NativeOCRDetectorSeedEvidence.preservingUnion(owned.map(\.detectorSeedEvidence)))
 check(evidence.count==7 && Set(evidence.map(\.ownerID)).count==7)
 check(joined.auxiliaryInkRects==owned.flatMap(\.auxiliaryInkRects) && joined.auxiliaryInkRects.count==7)
 check(joined.auxiliaryInkPolygons==owned.flatMap(\.auxiliaryInkPolygons) && joined.auxiliaryInkPolygons.count==7)
 check(apply(output,paper(),integration)==output,"owned unit must be idempotent")
 cases += 1
}}
let vetoPaper=paper(),vetoMap=ReaderTranslationEnclosedBackground.ComponentMap(image:vetoPaper)
check(ReaderTranslationLobedRequestMerger.apply(owned,image:vetoPaper,enclosure:vetoMap,separates:{_,_,_ in true})==owned,
 "explicit production ownership separation must veto")
cases += 1
print("LOBED_REQUEST_PASS cases=\(cases) helper+production-hook neutral+independent-utterance+separate-paper+third-owner+idempotence")
'''
with tempfile.TemporaryDirectory(prefix='aidoku-lobed-request-') as temp:
    temp=Path(temp);main=temp/'main.swift';binary=temp/'check'
    main.write_text('import Foundation\nimport CoreGraphics\n'+(T/'NativeEngine/OCR/BrowserOCRSourceOrientation.swift').read_text()+region+rot+h)
    sources=[T/p for p in ['ReaderTranslationLobedRequestMerger.swift','ReaderTranslationBalloonMerger.swift','ReaderTranslationEnclosedBackground.swift','ReaderTranslationStaggeredQuoteMerger.swift','NativeEngine/Overlay/BrowserOverlayTypography.swift','NativeEngine/OCR/NativeOCRDetectorSeedEvidence.swift','NativeEngine/OCR/NativeOCRSourceROIProbabilityEvidence.swift']]
    start=time.perf_counter()
    subprocess.run(['xcrun','swiftc','-O',*[str(p) for p in sources],str(main),'-o',str(binary)],check=True)
    print(f'Build seconds: {time.perf_counter()-start:.3f}',flush=True)
    start=time.perf_counter();subprocess.run([str(binary)],check=True)
    print(f'Test seconds: {time.perf_counter()-start:.3f}',flush=True)
