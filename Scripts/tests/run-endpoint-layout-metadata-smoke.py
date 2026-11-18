"""Focused production snapshot contract for layout affinity versus source extent."""
from pathlib import Path
import subprocess,time,json
root=Path(__file__).resolve().parents[2];ocr=root/'Aidoku/Core/Translation/NativeEngine/OCR'
out=root/'build/endpoint-layout-metadata-smoke';out.mkdir(parents=True,exist_ok=True)
s=(ocr/'NativeCoreMLOCRPipeline.swift').read_text();a=s.index('@available(iOS 18.0, *)\nstruct NativeCoreMLOCRLine:');b=s.index('@available(iOS 18.0, *)\nstruct NativeCoreMLOCRPipelineDiagnostics',a)
checks=r'''
let extent=[CGPoint(x:10,y:10),CGPoint(x:30,y:10),CGPoint(x:30,y:210),CGPoint(x:10,y:210)]
let layout=[CGPoint(x:10,y:10),CGPoint(x:30,y:10),CGPoint(x:30,y:160),CGPoint(x:10,y:160)]
let source=NativeCoreMLOCRLine(polygon:extent,text:"source",score:0.9,orientation:.vertical,
    acceptedSource:.init(layoutPolygon:layout))
let bound=NativeOCRAcceptedSource.bindingPrimary([source,source],width:300,height:300)
precondition(bound==[source,source],"metadata cannot mutate legacy source values")
let table=bound[0].acceptedSource.membership!.table
precondition(table.packets[0].polygon==extent,"actual source extent remains immutable")
precondition(table.packets[0].layoutPolygon==layout,"independent layout affinity survives snapshot binding")
precondition(table.packets[0].groupingPolygon==layout,"all relation consumers share the frozen layout geometry")
precondition(bound[0].acceptedSource.membership!.body == [0] && bound[1].acceptedSource.membership!.body == [1],
    "equal source values retain independent ownership")
let combined=NativeOCRSourceMetadata.union(bound.map(\.acceptedSource))
precondition(combined.membership!.table.packets.allSatisfy { $0.layoutPolygon==layout },
    "member union retains per-source layout snapshots")
let legacy=NativeCoreMLOCRLine(polygon:extent,text:"legacy",score:0.9,orientation:.vertical)
precondition(NativeOCRAcceptedSource.bindingPrimary([legacy],width:300,height:300)[0].acceptedSource.membership!.table.packets[0].layoutPolygon==nil,
    "legacy observations do not invent layout witnesses")
precondition(NativeOCRAcceptedSource.bindingPrimary([legacy],width:300,height:300)[0].acceptedSource.membership!.table.packets[0].groupingPolygon==extent,
    "legacy relation geometry is exactly the observed geometry")
let cycled=Array(extent[1...])+[extent[0]]
let turned=NativeCoreMLOCRLine(polygon:cycled,text:"source",score:0.9,orientation:.horizontal,
    acceptedSource:.init(layoutPolygon:layout))
let turnedPacket=NativeOCRAcceptedSource.bindingPrimary([turned],width:300,height:300)[0].acceptedSource.membership!.table.packets[0]
precondition(turnedPacket.layoutPolygon==Array(layout[1...])+[layout[0]],
    "layout snapshot follows the actual reading edge without changing geometry")
print("Endpoint layout metadata checks passed: 9")
'''
main=out/'main.swift';main.write_text('import Foundation\nimport CoreGraphics\n'+s[a:b]+checks)
files=[ocr/(n+'.swift') for n in ['BrowserOCRSourceOrientation','NativeOCRSourceROIProbabilityEvidence','NativeOCRDetectorSeedEvidence','NativeOCRAcceptedSource']]
t=time.monotonic();subprocess.run(['swiftc','-O','-module-cache-path',str(out/'module-cache'),*map(str,files),str(main),'-o',str(out/'checks')],check=True);build=time.monotonic()-t
t=time.monotonic();subprocess.run([str(out/'checks')],check=True);test=time.monotonic()-t
(out/'result.json').write_text(json.dumps(dict(checks=9,buildSeconds=build,testSeconds=test,scope='Actual production line and accepted-source storage on host; no SDK/device/full-app claim'),indent=2))
