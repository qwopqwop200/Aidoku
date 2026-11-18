#!/usr/bin/env python3
"""Actual chromatic source-slot contract with synthetic RGB contours and service refresh loop.

AIDOKU_TEST_CAPTION_SOURCE_DIR optionally selects the three candidate Swift files. Unused
region metadata fields use String placeholders; actual pixel/contour code is intact.
"""
from pathlib import Path
import subprocess
import os
import tempfile
r=Path(__file__).resolve().parents[2]; d=Path(os.environ.get('AIDOKU_TEST_CAPTION_SOURCE_DIR',str(r/'Aidoku/Core/Translation')));s=(d/'ReaderTranslationService.swift').read_text(); model=s[s.index('struct ReaderTranslationRegion:'):s.index('    /// If translation adds no information,')]+ '}\n';model=model.replace('NativeTranslationReuseIdentity?','String?').replace('[ReaderTranslationSourceOCRAlternative]','[String]')
e=(d/'ReaderTranslationEnclosedBackground.swift').read_text();e=e[:e.index('    static func attachingBalloonInteriors(')]+e[e.index('    private struct Component {'):]
b=(r/'Aidoku/Core/Translation/ReaderTranslationBalloonMerger.swift').read_text(); helper='enum ReaderTranslationBalloonMerger {\n'+b[b.index('    static func matchingOutlinedInk('):b.index('    static func differentOutlinedInk(')]+b[b.index('    private static func matching('):b.index('    private static func different(')]+b[b.index('    static func outlinedInk('):]
c=(d/'ReaderTranslationChromaticBalloon.swift').read_text()
h=r'''
func check(_ value:Bool,_ message:String = "check failed") { if !value { FileHandle.standardError.write(Data((message+"\n").utf8)); exit(1) } }
func makeImage(_ scale:Int)->CGImage {
 let n=256*scale
 var rgba=[UInt8](repeating:255,count:n*n*4)
 for y in 0..<n {for x in 0..<n {
  let xx=x/scale,yy=y/scale
  if (64...192).contains(xx) && (50...206).contains(yy) && (xx<69 || xx>187 || yy<55 || yy>201) {
   let i=(y*n+x)*4; rgba[i]=230;rgba[i+1]=30;rgba[i+2]=60
  }
 }}
 return CGImage(width:n,height:n,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:n*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:CGDataProvider(data:Data(rgba) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
}
var checked=0
for scale in [1,2,4] {for reverse in [false,true] {
 let img=makeImage(scale)
 let stale=ReaderTranslationBalloonInterior(rect:CGRect(x:0.05,y:0.05,width:0.9,height:0.9),center:CGPoint(x:0.5,y:0.5),spans:[0.05,0.95],members:2,contourVerified:true)
 var a=ReaderTranslationRegion(id:"protected",rect:CGRect(x:0.35,y:0.32,width:0.06,height:0.35),source:"青空案内",sourceOrientation:.vertical,sourceSingleVerticalColumn:true)
 var b=ReaderTranslationRegion(id:"ordinary",rect:CGRect(x:0.58,y:0.32,width:0.06,height:0.35),source:"街角散歩",sourceOrientation:.vertical,sourceSingleVerticalColumn:true)
 a.balloonInterior=stale;b.balloonInterior=stale
 let rows=reverse ? [b,a]:[a,b]
 let ordinary=ReaderTranslationChromaticBalloon.applying(rows,image:img)
 let contour=ReaderTranslationChromaticBalloon.interiors(rows,image:img)
 check(contour.allSatisfy{$0 != nil},"fixture must detect real colored contours")
 let protected=ReaderTranslationChromaticBalloon.applying(rows,image:img,preservingSourceSlots:["protected"])
 check(protected.count==2)
 check(protected.first{$0.id=="protected"}!.balloonInterior==nil,"stale contour survived")
 check(protected.first{$0.id=="ordinary"}!.balloonInterior != nil,"ordinary contour lost")
 let selective=ReaderTranslationChromaticBalloon.interiors(rows,image:img,preservingSourceSlots:["protected"])
 for i in rows.indices {check((selective[i]==nil)==(rows[i].id=="protected"))}
 let unknown=ReaderTranslationChromaticBalloon.applying(rows,image:img,preservingSourceSlots:["unknown"])
 check(unknown==ordinary,"unrelated ID changed output")
 checked += 1
}}
print("CHROMATIC_SOURCE_SLOT_PASS cases=\(checked) realContour,staleClear,selectiveIDs,unknownID")
'''
refresh_start=s.index('                for (offset, index) in changed.enumerated() {', s.index('let separateCaptionOwners'))
refresh_end=s.index('\n            }\n        }', refresh_start)
refresh=s[refresh_start:refresh_end]
h=h.replace(' checked += 1', ' let captionSlotIDs:Set<String>=["protected"]\n for onlyProtected in [false,true] {\n var joined=rows\n let changed=rows.indices.filter{!onlyProtected || rows[$0].id=="protected"}\n let refreshed=changed.map{rows[$0]}\n let contours=ReaderTranslationChromaticBalloon.interiors(refreshed,image:img,preservingSourceSlots:captionSlotIDs)\n'+refresh+'\n check(joined.first{$0.id=="protected"}!.balloonInterior==nil,"refresh stale protected interior survived")\n check(joined.first{$0.id=="ordinary"}!.balloonInterior != nil,"refresh ordinary interior lost")\n }\n checked += 1')
with tempfile.TemporaryDirectory(prefix='aidoku-chromatic-slot-contract-') as temporary:
    out=Path(temporary)
    (out/'main.swift').write_text('import Foundation\nimport CoreGraphics\n'+model+e+helper+c+h)
    ocr=r/'Aidoku/Core/Translation/NativeEngine/OCR'
    sources=[ocr/(name+'.swift') for name in ['BrowserOCRSourceOrientation','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence']]
    sources.append(d/'ReaderTranslationWhiteRimBalloon.swift')
    subprocess.run(['swiftc','-O',*[str(path) for path in sources],str(out/'main.swift'),'-o',str(out/'test')],check=True)
    subprocess.run([str(out/'test')],check=True)
