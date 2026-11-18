"""Production tiny-core sampling: square glyphs, peer ink and original ownership."""
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Scripts'))
from swift_replay_cache import compile_replay

OCR = ROOT/'Aidoku/Core/Translation/NativeEngine/OCR'
text = (OCR/'NativeOCRRFGapRecovery.swift').read_text()
start = text.index('    static func smallCoreContextPolygons(')
method = text[start:text.index('\n    struct RefinedCrop:',start)]
main = r'''
import Foundation
import CoreGraphics
struct NativeCoreMLDetectionBox {
    var polygon:[CGPoint]
    var score:Double
    var detectorSeedEvidence:NativeOCRDetectorSeedEvidence?
}
enum NativeOCRRFPrimaryEnsemble {
''' + method + r'''
}
typealias E=NativeOCRDetectorSeedEvidence
func evidence(_ id:Int,_ rect:CGRect)->E {
    let x=Int(rect.minX),y=Int(rect.minY),w=Int(rect.width),h=Int(rect.height)
    let c=E.Component(seed:y*200+x,pixelCount:w*h,meanProbability:1,
        runs:(y..<(y+h)).map { .init(y:$0,x:x,count:w) })
    let e=E(ownerID:"fixture-\(id)",parentBoxIndex:id,provenance:"db-complete-cc-candidates-v2",
        threshold:0.9,mapOriginX:0,mapOriginY:0,mapFullWidth:200,mapFullHeight:200,
        sourceWidth:200,sourceHeight:200,components:[c],ownershipVersion:2,
        completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    precondition(e.isValid)
    return e
}
func box(_ id:Int,_ bounds:CGRect,_ ink:CGRect)->NativeCoreMLDetectionBox {
    .init(polygon:NativeOCRDirectionGeometry.corners(bounds),score:0.9,detectorSeedEvidence:evidence(id,ink))
}
setenv("AIDOKU_OCR_ORIENTED_PATHS","all",1)
let original=CGRect(x:100,y:100,width:20,height:22)
let glyph=box(0,original,CGRect(x:105,y:105,width:10,height:12))
let blankPeer=box(1,CGRect(x:90,y:20,width:40,height:95),CGRect(x:100,y:20,width:8,height:40))
let crops=NativeOCRRFPrimaryEnsemble.smallCoreContextPolygons(index:0,boxes:[glyph,blankPeer],width:200,height:200)
precondition(crops.count==4,"blank peer sampling margins must not veto square-glyph context")
precondition(glyph.polygon==NativeOCRDirectionGeometry.corners(original),"sampling never changes detector geometry")
let inkPeer=box(1,CGRect(x:96,y:109,width:3,height:4),CGRect(x:97,y:110,width:2,height:2))
precondition(NativeOCRRFPrimaryEnsemble.smallCoreContextPolygons(index:0,boxes:[glyph,inkPeer],width:200,height:200).isEmpty,
    "newly sampled peer glyph ink must veto growth")
let unknownPeer=NativeCoreMLDetectionBox(polygon:blankPeer.polygon,score:0.9,detectorSeedEvidence:nil)
precondition(NativeOCRRFPrimaryEnsemble.smallCoreContextPolygons(index:0,boxes:[glyph,unknownPeer],width:200,height:200).isEmpty,
    "unknown peer ink is not permission to grow")
var weak=glyph;weak.score=0.7
precondition(NativeOCRRFPrimaryEnsemble.smallCoreContextPolygons(index:0,boxes:[weak],width:200,height:200).isEmpty)
let wide=box(0,CGRect(x:100,y:100,width:30,height:31),CGRect(x:105,y:105,width:20,height:20))
precondition(NativeOCRRFPrimaryEnsemble.smallCoreContextPolygons(index:0,boxes:[wide],width:200,height:200).isEmpty)
print("Tiny-core sampling: square support, blank peer margins, owned-ink veto, unknown peers and unchanged original geometry passed")
'''
sources=[OCR/name for name in ['NativeOCRLocalCoordinates.swift','NativeOCRSourceROIProbabilityEvidence.swift','NativeOCRDetectorSeedEvidence.swift']]
cache=ROOT/'build/small-core-context-smoke'
cache.mkdir(parents=True,exist_ok=True)
compile_replay(cache,sources,main,cache/'smoke')
subprocess.run([str(cache/'smoke')],check=True)
