"""Actual production reconciliation with complete reread record partitions across rotations."""
from pathlib import Path
import sys,subprocess,time
root=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(root/'Scripts'))
from swift_replay_cache import compile_replay
carrier=Path(__file__).with_name('run-paragraph-fragment-pipeline-smoke.py')
ns={'__file__':str(carrier)};exec(carrier.read_text().split('tests =')[0],ns)
support=ns['support']
main=support+r'''
var checks=0
for degrees in stride(from:0, to:360, by:15) {
 for scale:CGFloat in [0.5,1,2] { for fault in 0...7 {
    typealias Evidence=NativeOCRDetectorSeedEvidence
    let size=Int(1000*scale)
    func evidence(_ index:Int)->Evidence {
        let x=460,y=index==0 ? 330:470
        let component=Evidence.Component(seed:y*1000+x,pixelCount:12,meanProbability:0.95,
            runs:[.init(y:y,x:x,count:12)])
        return .init(ownerID:"owner-\(index)",parentBoxIndex:index,provenance:"db-complete-cc-candidates-v2",threshold:0.9,
            mapOriginX:0,mapOriginY:0,mapFullWidth:1000,mapFullHeight:1000,sourceWidth:size,sourceHeight:size,
            components:[component],ownershipVersion:2,completeCCScan:true,ambiguousComponents:[],candidateComponents:[])
    }
    let boxes=[CGRect(x:450,y:fault==4 ? 340:300,width:40,height:180),
               CGRect(x:450,y:fault==3 ? 300:450,width:40,height:90),
               CGRect(x:450,y:300,width:40,height:300)]
    let words=["先頭",fault==6 ? "終声":fault==7 ? "終…":"終端",fault==7 ? "全文…":"全文端"]
    let angle=CGFloat(degrees) * .pi / 180
    func point(_ p:CGPoint)->CGPoint {
        .init(x:(500+(p.x-500)*cos(angle)-(p.y-500)*sin(angle))*scale,
              y:(500+(p.x-500)*sin(angle)+(p.y-500)*cos(angle))*scale)
    }
    let lines=boxes.enumerated().map { i,b -> NativeCoreMLOCRLine in
        let q=[CGPoint(x:b.minX,y:b.minY),.init(x:b.maxX,y:b.minY),.init(x:b.maxX,y:b.maxY),.init(x:b.minX,y:b.maxY)].map(point)
        return .init(polygon:q,text:words[i],score:0.95,orientation:.vertical,
            detectorSeedEvidence:i==2 ? (fault==1 ? [evidence(0)]:[evidence(0),evidence(1)]):[evidence(fault==2 && i==1 ? 9:i)])
    }
    let bound=NativeOCRAcceptedSource.bindingPrimary(lines,width:size,height:size)
    let table=bound[0].acceptedSource.membership!.table
    let points=lines.flatMap(\.polygon)
    let bounds=points.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
    var region=ReaderTranslationRegion(id:"joined",rect:bounds.applying(.init(scaleX:1/CGFloat(size),y:1/CGFloat(size))),
        source:words[2]+words[0]+words[1]+(fault==5 ? "未":""))
    region.sourceImageAspectRatio=1;region.sourceOrientation = .vertical
    region.acceptedSource = .init(.init(table:table,body:[0,1,2],readings:[],unknownDedup:[],hasUntrackedInputs:false))
    let result=NativeParagraphFragmentGrouping.reconcilingObservations([region],scopes:[])
    precondition(result.count==1,"source partition changed")
    let m=result[0].acceptedSource.membership!
    if fault==0 {
        precondition(m.body == Set([0,2]) && m.readings == Set([1]),"exact suffix alias failed \(degrees)")
        precondition(result[0].source == "全文端先頭","original literal slices changed")
    } else {
        precondition(m.body == Set([0,1,2]) && m.readings.isEmpty,"invalid proof admitted \(fault)")
        precondition(result[0].source == region.source,"unproved source changed")
    }
    precondition(m.table === table,"immutable table replaced")
    checks+=1
 } }
}
print("Internal continuation reading: \(checks) checks passed across24angles and3scales")
'''
translation=root/'Aidoku/Core/Translation';ocr=translation/'NativeEngine/OCR'
sources=[ocr/'BrowserOCRSourceOrientation.swift',ocr/'NativeOCRDetectorSeedEvidence.swift',ocr/'NativeOCRSourceROIProbabilityEvidence.swift',ocr/'NativeOCRAcceptedSource.swift',translation/'NativeParagraphFragmentGrouping.swift',translation/'NativeParagraphFragmentGrouping+Pipeline.swift']
cache=root/'build/internal-continuation-reading-smoke';cache.mkdir(exist_ok=True)
t=time.monotonic();compile_replay(cache,sources,main,cache/'smoke');print('Build seconds:',time.monotonic()-t,flush=True)
subprocess.run([str(cache/'smoke')],check=True)
