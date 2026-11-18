"""Current production row separation: observed advance versus stable layout core."""
from pathlib import Path
import subprocess,sys,time
root=Path(__file__).resolve().parents[2]
base=root/'Scripts/tests/run-paragraph-fragment-pipeline-smoke.py'
ns={'__file__':str(base)}
exec(compile(base.read_text().split('tests =',1)[0],str(base),'exec'),ns)
sys.path.insert(0,str(root/'Scripts'))
from swift_replay_cache import compile_replay,write_if_changed
translation=root/'Aidoku/Core/Translation';ocr=translation/'NativeEngine/OCR'
wrapper=r'''
func precondition(_ condition:@autoclosure ()->Bool,_ message:@autoclosure ()->String = "",line:UInt = #line) {
    if !condition() { fputs("FAILED line \(line): \(message())\n",stderr);exit(1) }
}
extension NativeParagraphFragmentGrouping {
    static func recoveredAdvanceChecks()->Int {
        var checks=0
        for scale:CGFloat in [0.5,1,2] { for degree in stride(from:0.0,to:360,by:15) {
            let angle=CGFloat(degree)*CGFloat.pi/180
            let transform=CGAffineTransform(scaleX:scale,y:scale).rotated(by:angle)
            func quad(_ r:CGRect)->[CGPoint] {
                [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),
                 CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)].map { $0.applying(transform) }
            }
            func inventory(_ y:CGFloat,_ width:CGFloat)->(NativeOCRAcceptedSource.PacketTable,[PacketObservation]) {
                let first=NativeCoreMLOCRLine(polygon:quad(CGRect(x:100,y:100,width:128,height:64)),
                    text:"天地",score:0.99,orientation:.horizontal)
                var next=NativeCoreMLOCRLine(polygon:quad(CGRect(x:36,y:y,width:width,height:64)),
                    text:"春夏秋冬",score:0.99,orientation:.horizontal)
                next.acceptedSource = .init(layoutPolygon:quad(CGRect(x:100,y:y,width:168,height:64)))
                let bound=NativeOCRAcceptedSource.bindingPrimary([first,next],width:1000,height:1000)
                let table=bound[0].acceptedSource.membership!.table
                return (table,projectedPacketInventory([0,1],table:table)!)
            }
            let (table,rows)=inventory(260,256)
            precondition(independentParagraphRows([rows[0]],[rows[1]],table:table),
                "a recovered glyph cannot revoke a measured independent row boundary")
            let (sameTable,same)=inventory(110,256)
            precondition(!independentParagraphRows([same[0]],[same[1]],table:sameTable),
                "recognition growth does not split overlapping baselines")
            let (narrowTable,narrow)=inventory(260,144)
            precondition(!independentParagraphRows([narrow[0]],[narrow[1]],table:narrowTable),
                "narrow variable advance does not certify a full-em row")
            func sampledRows(_ rowWidth:CGFloat,_ y:CGFloat,_ owned:Bool = true)->(NativeOCRAcceptedSource.PacketTable,[PacketObservation]) {
                func located(_ r:CGRect)->[CGPoint] {
                    quad(r).map {CGPoint(x:$0.x+1000,y:$0.y+1000)}
                }
                func evidence(_ q:[CGPoint],_ owner:Int)->[NativeOCRDetectorSeedEvidence]? {
                    guard owned else {return nil}
                    let center=q.reduce(CGPoint.zero) {CGPoint(x:$0.x+$1.x/4,y:$0.y+$1.y/4)}
                    let map=Int(2000/scale),x=Int(center.x/scale),y=Int(center.y/scale)
                    let runs=(y-1...y+1).map {NativeOCRDetectorSeedEvidence.Run(y:$0,x:x-1,count:3)}
                    return [.init(ownerID:"sampled-row-\(owner)",parentBoxIndex:owner,
                        provenance:"db-complete-cc-candidates-v2",threshold:0.9,mapOriginX:0,mapOriginY:0,
                        mapFullWidth:map,mapFullHeight:map,sourceWidth:2000,sourceHeight:2000,
                        components:[.init(seed:(y-1)*map+x-1,pixelCount:9,meanProbability:0.99,runs:runs)],
                        ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])]
                }
                let a=located(.init(x:100,y:100,width:48,height:50)),b=located(.init(x:100,y:y,width:rowWidth,height:33))
                let first=NativeCoreMLOCRLine(polygon:a,text:"ん",score:0.99,orientation:.horizontal,detectorSeedEvidence:evidence(a,0))
                var second=NativeCoreMLOCRLine(polygon:b,text:"べくん",score:0.99,orientation:.horizontal,detectorSeedEvidence:evidence(b,1))
                // Frozen layout halo is taller than the current accepted crop.
                // Its old normal thickness cannot be paired with new advance.
                second.acceptedSource = .init(layoutPolygon:located(.init(x:100,y:y,width:rowWidth,height:41)))
                let bound=NativeOCRAcceptedSource.bindingPrimary([first,second],width:2000,height:2000)
                let table=bound[0].acceptedSource.membership!.table
                return (table,projectedPacketInventory([0,1],table:table)!)
            }
            let (sampledTable,sampled)=sampledRows(73,180)
            precondition(independentParagraphRows([sampled[0]],[sampled[1]],table:sampledTable),
                "one detector-cell advance uncertainty cannot fuse independently sized rows")
            let (thinTable,thin)=sampledRows(54,180)
            precondition(!independentParagraphRows([thin[0]],[thin[1]],table:thinTable),
                "detector-cell uncertainty does not certify a genuinely narrow variable-advance row")
            let (overlapTable,overlap)=sampledRows(73,120)
            precondition(!independentParagraphRows([overlap[0]],[overlap[1]],table:overlapTable),
                "uncertainty cannot split overlapping baselines")
            let (unownedTable,unowned)=sampledRows(73,180,false)
            precondition(!independentParagraphRows([unowned[0]],[unowned[1]],table:unownedTable),
                "absent detector evidence cannot invent a font-advance uncertainty allowance")
            checks += 7
        } }
        return checks
    }
}
'''
workspace=root/'build/paragraph-recovered-advance-smoke';snapshot=workspace/'production-snapshot'
snapshot.mkdir(parents=True,exist_ok=True)
frozen=[]
for path in [ocr/(n+'.swift') for n in ['BrowserOCRSourceOrientation','NativeOCRDetectorSeedEvidence','NativeOCRSourceROIProbabilityEvidence','NativeOCRAcceptedSource']]+[translation/'NativeParagraphFragmentGrouping.swift',translation/'NativeParagraphFragmentGrouping+Pipeline.swift']:
    target=snapshot/path.name
    content=path.read_text()+(wrapper if path.name.endswith('+Pipeline.swift') else '')
    write_if_changed(target,content.encode());frozen.append(target)
main=ns['support']+'\nprint("PASS \\(NativeParagraphFragmentGrouping.recoveredAdvanceChecks()) recovered-advance checks / 24 angles / 3 scales")\n'
started=time.monotonic();binary=workspace/'smoke'
compile_replay(workspace,frozen,main,binary)
print(f'Host compile seconds: {time.monotonic()-started:.2f}',flush=True)
subprocess.run([str(binary)],check=True)
